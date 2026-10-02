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
import java.util.ArrayList;
import java.util.List;

/**
 * A CommandChannel for the REST server. It collects what the command writes and,
 * when the command calls close() (or the request handler does, if the command
 * didn't), sends it as a single JSON response:
 *
 *   {"ok": true, "command": "RESTART", "messages": ["RESTART in progress", ...]}
 *   {"ok": false, "command": "RESTART", "error": "RESTART already in progress", "messages": [...]}
 *
 * The response is written before close() returns. That matters for STOP, which
 * ends the process straight after closing its channel.
 */
final class HttpCommandChannel extends CommandChannel {

    private final HttpExchange mExchange;
    private final String mCommand;
    private final List<String> mMessages = new ArrayList<>();
    private String mError;
    private boolean mAcked;
    private boolean mClosed;

    HttpCommandChannel(HttpExchange exchange, String command) {
        mExchange = exchange;
        mCommand = command;
    }

    @Override
    synchronized void writeAck(String info) {
        mAcked = true;
        if (!info.isEmpty()) mMessages.add(info);
    }

    @Override
    synchronized void writeInfo(String info) {
        mMessages.add(info);
    }

    @Override
    synchronized void writeNack(String info) {
        if (mError == null) mError = info;
    }

    @Override
    synchronized void close() {
        if (mClosed) return;
        mClosed = true;

        String error = mError;
        if (error == null && !mAcked) error = "the command did not report an outcome (see the IBC log)";

        StringBuilder json = new StringBuilder();
        json.append("{\"ok\": ").append(error == null)
            .append(", \"command\": ").append(Json.quote(mCommand));
        if (error != null) json.append(", \"error\": ").append(Json.quote(error));
        json.append(", \"messages\": ").append(Json.array(mMessages)).append('}');

        RestServer.sendJson(mExchange, statusFor(error), json.toString());
    }

    private static int statusFor(String error) {
        if (error == null) return 200;
        if (error.contains("already in progress")) return 409;   // Conflict
        if (error.contains("not valid for")) return 422;         // not applicable to this session
        return 500;
    }

}
