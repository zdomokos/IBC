// This file is part of IBC.
// Copyright (C) 2004 Steven M. Kearns (skearns23@yahoo.com )
// Copyright (C) 2004 - 2018 Richard L King (rlking@aultan.com)
// For conditions of distribution and use, see copyright notice in COPYING.txt

// IBC is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// IBC is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with IBC.  If not, see <http://www.gnu.org/licenses/>.

package ibcalpha.ibc;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * Raises a Critical alert on a Loraq hub ({@code POST <LoraqHubUrl>/api/alerts}) while TWS or
 * Gateway is waiting for an interactive login, which on a live account means somebody has to
 * approve the second factor authentication, and clears it when the login completes.
 * <p>
 * A warm auto-restart logs in without the login dialog, so it raises nothing. Once this Java VM
 * has logged in, later login states (eg a re-login) raise nothing either, because nothing would
 * clear the alert again. While the alert is open it's restated every minute, so the hub doesn't
 * treat it as coming from a source that has gone quiet. The alert's id is fixed, so the alert
 * raised by the next Java VM (after a 2FA timeout or a crash) continues the same one; the
 * sequence number is the wall clock, so it keeps increasing across Java VMs.
 * <p>
 * Settings: LoraqHubUrl (empty = off), LoraqHubKey (X-Ztg-Alert-Key header), LoraqHubSourceId
 * (default ibc/&lt;trading mode&gt;).
 * <p>
 * All the work, including the HTTP requests, runs on one daemon thread, in order.
 */
final class HubAlerter {

    private static final int LEVEL_CRITICAL = 4;
    private static final int KIND_RAISE = 0;
    private static final int KIND_UPDATE = 1;
    private static final int KIND_CLEAR = 2;

    private static final int HEARTBEAT_SECONDS = 60;
    private static final int CLEAR_RETRY_SECONDS = 30;
    private static final int CLEAR_MAX_ATTEMPTS = 20;
    private static final int TIMEOUT_MILLIS = 10_000;

    private static final ScheduledExecutorService EXECUTOR = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "IBC-HubAlerter");
        t.setDaemon(true);
        return t;
    });

    // the fields below are only used on the EXECUTOR thread
    private static boolean initialised;
    private static URI endpoint;
    private static String key;
    private static String sourceId;
    private static String alertId;
    private static String tradingMode;

    private static boolean everLoggedIn;
    private static boolean open;
    private static Instant raisedAt;
    private static String description;
    private static long lastSeq;
    private static boolean lastPostFailed;
    private static ScheduledFuture<?> heartbeat;
    private static ScheduledFuture<?> clearRetry;

    private HubAlerter() {}

    static void loginStateChanged(final LoginManager.LoginState state) {
        try {
            EXECUTOR.execute(() -> onLoginState(state));
        } catch (Throwable e) {
            Utils.logError("HubAlerter: " + e);
        }
    }

    private static boolean enabled() {
        if (!initialised) {
            initialised = true;
            String url = Settings.settings().getString("LoraqHubUrl", "").trim();
            if (url.isEmpty()) return false;
            while (url.endsWith("/")) url = url.substring(0, url.length() - 1);
            try {
                endpoint = new URI(url + "/api/alerts");
            } catch (Exception e) {
                Utils.logError("HubAlerter: LoraqHubUrl '" + url + "' is not a valid URL, so no alerts will be sent");
                return false;
            }
            key = Settings.settings().getString("LoraqHubKey", "").trim();
            tradingMode = TradingModeManager.tradingModeManager().getTradingMode();
            sourceId = Settings.settings().getString("LoraqHubSourceId", "").trim();
            if (sourceId.isEmpty()) sourceId = "ibc/" + tradingMode;
            alertId = sourceId + "/Login";
            Utils.logToConsole("HubAlerter: login alerts go to " + endpoint + " as " + alertId);
        }
        return endpoint != null;
    }

    private static void onLoginState(LoginManager.LoginState state) {
        try {
            if (!enabled()) return;
            switch (state) {
                case LOGGED_IN:
                    everLoggedIn = true;
                    clear();
                    break;
                case AWAITING_CREDENTIALS:
                case LOGGING_IN:
                    raise("IBC is logging in to " + app() + ": approve the IBKR Mobile notification when it arrives.");
                    break;
                case TWO_FA_IN_PROGRESS:
                    raise("Waiting for second factor authentication: approve the IBKR Mobile notification.");
                    break;
                case LOGIN_FAILED:
                    raise("The login failed: see the IBC log.");
                    break;
                default:
                    break;
            }
        } catch (Throwable e) {
            Utils.logError("HubAlerter: " + e);
        }
    }

    private static void raise(String text) {
        if (everLoggedIn) return;
        description = text;
        if (open) {
            post(KIND_UPDATE);
            return;
        }
        open = true;
        raisedAt = Instant.now().truncatedTo(ChronoUnit.MILLIS);
        cancel(clearRetry);
        clearRetry = null;
        Utils.logToConsole("HubAlerter: raising the login alert");
        post(KIND_RAISE);
        heartbeat = EXECUTOR.scheduleWithFixedDelay(() -> {
            try {
                if (open) post(KIND_UPDATE);
            } catch (Throwable e) {
                Utils.logError("HubAlerter: " + e);
            }
        }, HEARTBEAT_SECONDS, HEARTBEAT_SECONDS, TimeUnit.SECONDS);
    }

    // Sent even if this Java VM didn't raise the alert, in case an earlier one did: clearing an
    // alert that isn't open does nothing
    private static void clear() {
        open = false;
        cancel(heartbeat);
        heartbeat = null;
        if (clearRetry != null) return;
        Utils.logToConsole("HubAlerter: clearing the login alert");
        if (post(KIND_CLEAR)) return;
        final int[] attempts = {1};
        clearRetry = EXECUTOR.scheduleWithFixedDelay(() -> {
            try {
                if (open || post(KIND_CLEAR) || ++attempts[0] >= CLEAR_MAX_ATTEMPTS) {
                    if (!open && attempts[0] >= CLEAR_MAX_ATTEMPTS) Utils.logError("HubAlerter: giving up clearing the login alert");
                    cancel(clearRetry);
                    clearRetry = null;
                }
            } catch (Throwable e) {
                Utils.logError("HubAlerter: " + e);
            }
        }, CLEAR_RETRY_SECONDS, CLEAR_RETRY_SECONDS, TimeUnit.SECONDS);
    }

    private static void cancel(ScheduledFuture<?> future) {
        if (future != null) future.cancel(false);
    }

    private static String app() {
        return (SessionManager.isGateway() ? "Gateway" : "TWS") + " (" + tradingMode + ")";
    }

    private static String host() {
        String h = System.getenv("COMPUTERNAME");
        if (h == null || h.isEmpty()) h = System.getenv("HOSTNAME");
        return (h == null || h.isEmpty()) ? "unknown" : h;
    }

    private static boolean post(int kind) {
        final Instant now = Instant.now().truncatedTo(ChronoUnit.MILLIS);
        lastSeq = Math.max(lastSeq + 1, now.toEpochMilli());
        final String setAt = (raisedAt != null ? raisedAt : now).toString();
        final boolean clearing = kind == KIND_CLEAR;

        final String body = "[{" +
                "\"kind\":" + kind +
                ",\"alertId\":" + Json.quote(alertId) +
                ",\"sourceId\":" + Json.quote(sourceId) +
                ",\"seq\":" + lastSeq +
                ",\"at\":" + Json.quote(now.toString()) +
                ",\"clearedAt\":" + (clearing ? Json.quote(now.toString()) : "null") +
                ",\"clearReason\":" + (clearing ? Json.quote("Rule") : "null") +
                ",\"price\":null" +
                ",\"alert\":{" +
                    "\"alertId\":" + Json.quote(alertId) +
                    ",\"system\":\"IBC\"" +
                    ",\"source\":" + Json.quote(host()) +
                    ",\"subsystem\":" + Json.quote(SessionManager.isGateway() ? "Gateway" : "TWS") +
                    ",\"component\":" + Json.quote(tradingMode) +
                    ",\"level\":" + LEVEL_CRITICAL +
                    ",\"title\":" + Json.quote("IB " + tradingMode + " is not logged in") +
                    ",\"description\":" + Json.quote(clearing ? app() + " has logged in." : description) +
                    ",\"alertSetAt\":" + Json.quote(setAt) +
                    ",\"tags\":[\"ibc\",\"login\"]" +
                "}}]";

        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) endpoint.toURL().openConnection();
            conn.setConnectTimeout(TIMEOUT_MILLIS);
            conn.setReadTimeout(TIMEOUT_MILLIS);
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json");
            if (!key.isEmpty()) conn.setRequestProperty("X-Ztg-Alert-Key", key);
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            conn.setFixedLengthStreamingMode(bytes.length);
            try (OutputStream os = conn.getOutputStream()) {
                os.write(bytes);
            }
            int status = conn.getResponseCode();
            String reply = readReply(conn, status);
            if (status / 100 != 2) {
                failed("hub replied " + status + (reply.isEmpty() ? "" : ": " + reply));
                return false;
            }
            if (lastPostFailed || kind != KIND_UPDATE) {
                Utils.logToConsole("HubAlerter: hub replied " + status + (reply.isEmpty() ? "" : ": " + reply));
            }
            lastPostFailed = false;
            return true;
        } catch (Exception e) {
            failed(e.toString());
            return false;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    // only the first of a run of failures is logged, so a hub that's down doesn't fill the log
    private static void failed(String reason) {
        if (!lastPostFailed) Utils.logError("HubAlerter: can't send the login alert to " + endpoint + ": " + reason);
        lastPostFailed = true;
    }

    private static String readReply(HttpURLConnection conn, int status) {
        try (InputStream is = status / 100 == 2 ? conn.getInputStream() : conn.getErrorStream()) {
            if (is == null) return "";
            String s = new String(is.readAllBytes(), StandardCharsets.UTF_8).trim();
            return s.length() > 300 ? s.substring(0, 300) : s;
        } catch (Exception e) {
            return "";
        }
    }

}
