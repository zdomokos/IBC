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

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.Executors;

/**
 * An HTTP/JSON alternative to the command server. It runs the same commands
 * (through CommandDispatcher.dispatch) and adds a status endpoint, an OpenAPI
 * description (/openapi.yaml) and a Swagger UI page (/docs).
 *
 * Settings: RestPort (0 = off), RestBindAddress (default 127.0.0.1), RestToken
 * (a bearer token; required unless RestBindAddress is a loopback address) and
 * ControlFrom (shared with the command server).
 */
final class RestServer {

    private static final String API = "/api/v1/";
    private static final int MIN_TOKEN_LENGTH = 32;
    private static final int THREADS = 4;
    private static final int MAX_REQUEST_BODY = 64 * 1024;

    // endpoint name -> command
    private static final Map<String, String> COMMANDS = Map.of(
            "stop", "STOP",
            "restart", "RESTART",
            "pause", "PAUSE",
            "enableapi", "ENABLEAPI",
            "reconnectdata", "RECONNECTDATA",
            "reconnectaccount", "RECONNECTACCOUNT");

    private final InetAddress mBindAddress;
    private final byte[] mToken;                 // null if no token is required
    private final List<InetAddress> mAllowedClients;

    private RestServer(InetAddress bindAddress, String token, List<InetAddress> allowedClients) {
        mBindAddress = bindAddress;
        mToken = token.isEmpty() ? null : token.getBytes(StandardCharsets.UTF_8);
        mAllowedClients = allowedClients;
    }

    static void start() {
        final int port = Settings.settings().getInt("RestPort", 0);
        if (port == 0) {
            Utils.logToConsole("RestServer is not started because RestPort is not configured");
            return;
        }

        final String bind = Settings.settings().getString("RestBindAddress", "127.0.0.1");
        final InetAddress bindAddress;
        try {
            bindAddress = InetAddress.getByName(bind);
        } catch (UnknownHostException e) {
            Utils.logError("RestServer is not started: RestBindAddress " + bind + " is not a valid address");
            return;
        }

        final String token = Settings.settings().getString("RestToken", "");
        if (token.isEmpty() && !bindAddress.isLoopbackAddress()) {
            Utils.logError("RestServer is not started: RestToken must be set when RestBindAddress is not a loopback address");
            return;
        }
        if (!token.isEmpty() && token.length() < MIN_TOKEN_LENGTH) {
            Utils.logError("RestServer is not started: RestToken must be at least " + MIN_TOKEN_LENGTH + " characters");
            return;
        }

        RestServer restServer = new RestServer(bindAddress, token, resolveAllowedClients());
        restServer.listen(port);
    }

    private void listen(int port) {
        final String address = urlHost(mBindAddress) + ":" + port;
        try {
            // limits the time a client may take to send its request (seconds)
            if (System.getProperty("sun.net.httpserver.maxReqTime") == null) {
                System.setProperty("sun.net.httpserver.maxReqTime", "10");
            }

            HttpServer server = HttpServer.create(new InetSocketAddress(mBindAddress, port), 0);
            server.createContext("/", this::handle);
            server.setExecutor(Executors.newFixedThreadPool(THREADS, r -> {
                Thread t = new Thread(r, "RestServer");
                t.setDaemon(true);
                return t;
            }));
            server.start();
        } catch (IOException e) {
            Utils.logException(e);
            Utils.logError("RestServer failed to listen on " + address);
            return;
        }

        Utils.logToConsole("RestServer listening on http://" + address +
                           (mToken == null ? " (no RestToken: requests need no authorization)" : ""));
        Utils.logToConsole("RestServer API documentation: http://" + address + "/docs");
        if (!mBindAddress.isLoopbackAddress()) {
            Utils.logToConsole("RestServer warning: traffic is not encrypted, so the RestToken can be read by anyone on the network path");
        }
    }

    private static List<InetAddress> resolveAllowedClients() {
        // resolved once, here, so that requests never wait for DNS
        List<InetAddress> allowed = new ArrayList<>();
        for (String entry : Settings.settings().getString("ControlFrom", "").split(",")) {
            entry = entry.trim();
            if (entry.isEmpty()) continue;
            try {
                allowed.addAll(Arrays.asList(InetAddress.getAllByName(entry)));
            } catch (UnknownHostException e) {
                Utils.logToConsole("RestServer: ignoring ControlFrom entry " + entry + ": unknown host");
            }
        }
        return allowed;
    }

    private void handle(HttpExchange exchange) {
        try {
            discardRequestBody(exchange);

            final String path = exchange.getRequestURI().getPath();
            final InetAddress client = exchange.getRemoteAddress().getAddress();

            if (!isPermittedClient(client)) {
                Utils.logToConsole("RestServer denied access to: " + client.getHostAddress());
                sendError(exchange, 403, "client address not permitted (see ControlFrom)");
                return;
            }

            if (path.equals("/")) {
                exchange.getResponseHeaders().set("Location", "/docs");
                send(exchange, 302, "text/plain; charset=utf-8", new byte[0]);
            } else if (path.equals("/docs")) {
                if (requireMethod(exchange, "GET")) sendResource(exchange, "rest-docs.html", "text/html; charset=utf-8");
            } else if (path.equals("/openapi.yaml")) {
                if (requireMethod(exchange, "GET")) sendResource(exchange, "openapi.yaml", "application/yaml; charset=utf-8");
            } else if (path.startsWith(API)) {
                handleApi(exchange, path.substring(API.length()), client);
            } else {
                sendError(exchange, 404, "not found");
            }
        } catch (RuntimeException e) {
            Utils.logException(e);
            sendError(exchange, 500, "IBC error: " + e);
        } finally {
            exchange.close();
        }
    }

    private void handleApi(HttpExchange exchange, String name, InetAddress client) {
        if (isCrossSite(exchange)) {
            Utils.logToConsole("RestServer refused a cross-site request from: " + client.getHostAddress());
            sendError(exchange, 403, "cross-site requests are not allowed");
            return;
        }
        if (!isAuthorised(exchange)) {
            Utils.logToConsole("RestServer refused an unauthorised request from: " + client.getHostAddress());
            exchange.getResponseHeaders().set("WWW-Authenticate", "Bearer");
            sendError(exchange, 401, "missing or wrong bearer token");
            return;
        }

        if (name.equals("status")) {
            if (requireMethod(exchange, "GET")) sendStatus(exchange);
            return;
        }

        final String command = COMMANDS.get(name);
        if (command == null) {
            sendError(exchange, 404, "no such endpoint");
            return;
        }
        if (!requireMethod(exchange, "POST")) return;

        Utils.logToConsole("RestServer received command: " + command + " from: " + client.getHostAddress());
        if (!SessionManager.isSessionStarted()) {
            sendError(exchange, 503, "TWS/Gateway is still starting; try again shortly");
            return;
        }

        // runs on this thread, like the command server; the channel sends the response
        // when the command closes it (or below, if it doesn't)
        HttpCommandChannel channel = new HttpCommandChannel(exchange, command);
        try {
            CommandDispatcher.dispatch(command, channel);
        } catch (RuntimeException e) {
            Utils.logException(e);
            channel.writeNack("IBC error: " + e);
        } finally {
            channel.close();
        }
    }

    private void sendStatus(HttpExchange exchange) {
        final boolean started = SessionManager.isSessionStarted();
        final LoginManager.LoginState loginState = LoginManager.loginManager().getLoginState();
        final String json = "{\"ibcVersion\": " + Json.quote(IbcVersionInfo.IBC_VERSION) +
                            ", \"application\": " + Json.quote(SessionManager.isGateway() ? "Gateway" : "TWS") +
                            ", \"fix\": " + (started ? String.valueOf(SessionManager.isFIX()) : "null") +
                            ", \"sessionStarted\": " + started +
                            ", \"loginState\": " + Json.quote(loginState == null ? null : loginState.name()) +
                            ", \"ready\": " + SessionManager.isReady() +
                            ", \"shuttingDown\": " + StopTask.shutdownInProgress() +
                            "}";
        sendJson(exchange, 200, json);
    }

    private boolean isPermittedClient(InetAddress client) {
        return client.isLoopbackAddress() ||
               client.equals(mBindAddress) ||
               mAllowedClients.contains(client);
    }

    /*
     * A browser adds an Origin header to cross-origin requests (and to same-origin
     * POSTs). Refusing any Origin other than this server's own stops a web page
     * from driving IBC through the user's browser. Without a token, the Host must
     * also be a loopback name, so that a DNS-rebound page (whose Origin then
     * matches its Host) is refused too.
     */
    private boolean isCrossSite(HttpExchange exchange) {
        final String host = exchange.getRequestHeaders().getFirst("Host");
        final String origin = exchange.getRequestHeaders().getFirst("Origin");
        if (origin != null && (host == null || !origin.equalsIgnoreCase("http://" + host))) return true;
        return mToken == null && !isLoopbackHost(host);
    }

    private static boolean isLoopbackHost(String host) {
        if (host == null) return false;
        String h = host.trim().toLowerCase(Locale.ROOT);
        if (h.startsWith("[")) {
            final int end = h.indexOf(']');
            if (end < 0) return false;
            h = h.substring(1, end);
        } else {
            final int colon = h.lastIndexOf(':');
            if (colon >= 0) h = h.substring(0, colon);
        }
        return h.equals("localhost") || h.equals("::1") || h.matches("127\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}");
    }

    private boolean isAuthorised(HttpExchange exchange) {
        if (mToken == null) return true;
        final String auth = exchange.getRequestHeaders().getFirst("Authorization");
        if (auth == null || !auth.regionMatches(true, 0, "Bearer ", 0, 7)) return false;
        final byte[] supplied = auth.substring(7).trim().getBytes(StandardCharsets.UTF_8);
        return MessageDigest.isEqual(supplied, mToken);
    }

    private static boolean requireMethod(HttpExchange exchange, String method) {
        if (exchange.getRequestMethod().equals(method)) return true;
        exchange.getResponseHeaders().set("Allow", method);
        sendError(exchange, 405, "use " + method);
        return false;
    }

    private static void sendResource(HttpExchange exchange, String name, String contentType) {
        try (InputStream in = RestServer.class.getResourceAsStream(name)) {
            if (in == null) {
                sendError(exchange, 404, name + " is missing from IBC.jar");
                return;
            }
            final String text = new String(in.readAllBytes(), StandardCharsets.UTF_8)
                    .replace("@IBC_VERSION@", IbcVersionInfo.IBC_VERSION);
            send(exchange, 200, contentType, text.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            Utils.logException(e);
            sendError(exchange, 500, "can't read " + name);
        }
    }

    private static void sendError(HttpExchange exchange, int status, String message) {
        sendJson(exchange, status, "{\"ok\": false, \"error\": " + Json.quote(message) + "}");
    }

    static void sendJson(HttpExchange exchange, int status, String json) {
        send(exchange, status, "application/json; charset=utf-8", json.getBytes(StandardCharsets.UTF_8));
    }

    private static void send(HttpExchange exchange, int status, String contentType, byte[] body) {
        try {
            exchange.getResponseHeaders().set("Content-Type", contentType);
            exchange.getResponseHeaders().set("Cache-Control", "no-store");
            exchange.getResponseHeaders().set("X-Content-Type-Options", "nosniff");
            exchange.sendResponseHeaders(status, body.length == 0 ? -1 : body.length);
            if (body.length > 0) {
                try (OutputStream out = exchange.getResponseBody()) {
                    out.write(body);
                }
            }
        } catch (IOException e) {
            // the client has gone, or a response has already been sent
            Utils.logException(e);
        }
    }

    private static void discardRequestBody(HttpExchange exchange) {
        try (InputStream in = exchange.getRequestBody()) {
            in.readNBytes(MAX_REQUEST_BODY);
        } catch (IOException e) {
            // ignore: the body isn't used
        }
    }

    private static String urlHost(InetAddress address) {
        final String host = address.getHostAddress();
        return host.contains(":") ? "[" + host + "]" : host;
    }

}
