# IBC Java Code Review — Findings

- **Date:** 2026-09-30
- **Scope:** `src/ibcalpha/ibc` (83 files, ~8.8k lines) at commit `fc6d917` (version 3.24.2)
- **Method:** static reading of the source; none of the issues below have been reproduced at runtime.
- **Revised:** 2026-10-01, after checking each finding against the source. None of the Java files
  discussed changed after `fc6d917`, so the line numbers still apply.

## Background: how IBC drives TWS

IBC is not an external automation tool. The start scripts launch `java` with
`ibcalpha.ibc.IbcTws` / `ibcalpha.ibc.IbcGateway` as the entry point and the TWS jars on the
classpath, so IBC and TWS share one JVM.

1. **Entry:** IBC's `main()` sets itself up, then calls TWS's own entry point directly —
   `jclient.LoginFrame.main(...)` (`IbcTws.java:516`) or `ibgateway.GWClient.main(...)`
   (`IbcTws.java:474`).
2. **Window hook:** before starting TWS it registers a global listener with
   `Toolkit.getDefaultToolkit().addAWTEventListener(..., WINDOW_EVENT_MASK)` (`IbcTws.java:301`).
   Every window event in the JVM reaches `TwsListener.eventDispatched`.
3. **Recognition:** `TwsListener` moves the work onto the Swing event thread and asks each of the
   34 `WindowHandler`s `recogniseWindow(window)`. Windows are identified by their content: title,
   label text or button captions.
4. **Finding controls:** `ComponentIterator` does a depth-first walk of `Container.getComponents()`.
   The `SwingUtils.find*` helpers match either by **type + text** (`findButton(w, "Log In")`) or by
   **type + position** (`findTextField(w, 0)` = username, `1` = password). Scoped searches are also
   used: find the container holding "Socket port", then take its first text field.
5. **Acting:** ordinary Swing calls such as `doClick()`, `setText()`, `setSelected()`, and for the
   config dialog `JTree.setSelectionPath(TreePath)`. No synthetic mouse input or screen
   coordinates are used, and no reflection.

## Cross-cutting issue: an uncaught exception halts the whole JVM

`IbcTws.java:212` / `IbcGateway.java:26` install `UncaughtExceptionHandler`, which calls
`Utils.exitWithException` → `Runtime.getRuntime().halt(...)`. Tasks are run with
`MyCachedThreadPool.execute()` (not `submit()`) and on the Swing event thread, so an unexpected
exception on any of these threads **kills TWS/Gateway**, not just the failing IBC task. Several
findings below get their severity from this.

The exception is `MyScheduledExecutorService`. Exceptions in tasks passed to `schedule()` or
`scheduleAtFixedRate()` are captured in the returned `ScheduledFuture`, which nobody reads, so they
never reach the handler: they are lost without any log entry. See H6.

---

## High severity

### H1. RECONNECTDATA can crash TWS; RECONNECTACCOUNT can hang

- **Location:** `CommandDispatcher.java:80-95`, `:97-111`
- **Problem:** `getMainWindow(1, TimeUnit.MILLISECONDS)` returns `null` if the main window is not
  yet known (during login, or on the Gateway before the splash frame closes).
  `new KeyEvent(null, ...)` then throws `IllegalArgumentException("null source")` on a pool thread,
  so the JVM halts.
- **Impact:** any client permitted on the command port can terminate TWS by sending
  `RECONNECTDATA` at the wrong moment. `RECONNECTACCOUNT` uses the no-timeout overload instead,
  so the client and its pool thread block until the main window appears (forever, if login never
  completes).
- **Also:** `jf.dispatchEvent(...)` is called from a pool thread, not the Swing event thread.
- **Fix:** null-check the window and reply `ERROR main window not available`; use a bounded
  timeout for both commands; send the events via `SwingUtilities.invokeLater`.

### H2. Race between `getMainWindow` and `setMainWindow`

- **Location:** `DefaultMainWindowManager.java:81-104` and `:143`
- **Problem:** `mainWindowFuture` is created inside `synchronized(futureCreationLock)` but
  dereferenced (`mainWindowFuture.get(...)`) after the lock is released. `setMainWindow` (on the
  Swing event thread) sets `mainWindowFuture = null` without taking the lock. The field is also
  not `volatile`, so the null may not even be seen consistently.
- **Scenario:** thread A leaves the synchronized block. The main window opens and the event thread
  sets the future to null. Thread A calls `.get()` on null → `NullPointerException` → JVM halt.
- **Impact:** the window is short but lines up with the moment STOP, RESTART and scheduled tasks
  are waiting for the main window.
- **Fix:** copy the future to a local variable inside the lock and call `.get()` on the local;
  clear the field in `setMainWindow` under the same lock.

### H3. STOP failures are swallowed and then block every later STOP

- **Location:** `StopTask.java:80-90` — `Utils.invokeMenuItem(...)` result ignored, then
  `catch (Exception e) { }`
- **Problem:** STOP can fail silently in three ways, and in each the static `SwitchLock _Running`
  stays set, so every later STOP answers "STOP already in progress":
  - **Menu item missing** (e.g. IBKR renames File > Exit / File > Close): `invokeMenuItem` does
    not throw. It catches its own "not found" `IbcException` and returns `false`, which `stop()`
    ignores. The client has already been told "OK Shutting down" (`StopTask.java:77`), and nothing
    is logged.
  - **Menu item disabled** (e.g. while a modal dialog is open): `invokeMenuItem` retries every
    250 ms with no limit (L3), so the STOP thread hangs forever with the lock held.
  - **Any other exception** (e.g. from `getMainWindow()`): swallowed by the empty catch.
- **Impact:** scheduled cold restarts (`ColdRestartTime`) and error-driven restarts stop working,
  with no trace in the log.
- **Fix:** check `invokeMenuItem`'s return value, log failures and exceptions, clear `_Running`
  on failure, and report `ERROR` to the channel. Give `invokeMenuItem` a retry limit (L3).

### H5. Restart countdown overlay can abort the restart

- **Location:** `RestartTask.java:127-178` (fallback path used when there is no
  `File > Restart...` menu, e.g. the Gateway)
- **Main problem:** `JFrame.setOpacity(0.80f)` throws `IllegalComponentStateException` if the
  frame is decorated. It propagates to `run()`'s catch → `Utils.exitWithException`, so IBC halts
  instead of restarting. The halt can happen before the asynchronous `ConfigurationTask` has
  saved the new auto-restart time, so the restart may not happen at all.
  **Needs checking against a real Gateway:** if its main frame is decorated, Gateway RESTART
  fails every time; if it is undecorated, this path is safe.
- **Lesser problems:**
  - `Countdown.paintComponent` reads `secsRemaining`, which is filled in by a scheduled task. If
    the first paint ran first, it would throw `NullPointerException` on the Swing event thread →
    JVM halt. Unlikely in practice: the task is scheduled with zero delay before the overlay is
    shown.
  - `setOpacity` / `setGlassPane` are called from a pool thread, not the Swing event thread.
  - The per-second `scheduleAtFixedRate` task is never cancelled. Harmless, since the process
    restarts a minute later.
- **Fix:** initialise `secsRemaining` in the constructor; build the overlay on the Swing event
  thread inside try/catch that only logs; keep the `ScheduledFuture` and cancel it.

### H6. One blocked scheduled task stops all the others

- **Location:** `MyScheduledExecutorService.java` (`Executors.newScheduledThreadPool(1)`),
  `TwsSettingsSaver.java:148-151`
- **Problem:** every scheduled task in IBC shares a single thread. The daily settings save runs
  `getMainWindow()` and `Utils.invokeMenuItem(..., {"File", "Save Settings"})` directly on that
  thread. Both can block indefinitely: `getMainWindow()` until the main window exists, and
  `invokeMenuItem` while the menu item is disabled (L3), e.g. while a modal dialog is open.
- **Impact:** while that thread is blocked, no other scheduled task runs: the `ColdRestartTime`
  shutdown (`IbcTws.java:503`), the login timeouts (`LoginManager.java:151`, `:170`), the
  `SessionManager.java:64` and `AbstractLoginHandler.java:119`/`:137` timers,
  `TooManyFailedLoginAttemptsDialogHandler.java:66`, and the restart countdown.
- **Also:** because scheduled-task exceptions are captured in the unread `ScheduledFuture` (see
  the cross-cutting section), a single exception in the settings save cancels all later daily
  saves, with nothing in the log.
- **Fix:** have scheduled tasks hand blocking work to `MyCachedThreadPool` instead of running it
  on the scheduler thread; wrap each scheduled task's body in try/catch that logs; give
  `invokeMenuItem` a retry limit (L3).

---

## Medium severity

### M1. `StopTask` "already in progress" path dereferences a null channel (was H4)

- **Location:** `StopTask.java:44`
- **Problem:** five callers pass `null` as the channel (`AbstractLoginHandler:191`,
  `LoginErrorDialogHandler:42`, `LoginFailedDialogHandler:43`, `GatewayDialogHandler:45`,
  `IbcTws:504`). Every other method null-checks `mChannel`, but this path calls
  `mChannel.close()` directly → `NullPointerException` on a pool thread → JVM halt.
- **Scenario:** two error dialogs, or an error dialog plus the ColdRestartTime timer, trigger at
  the same time.
- **Impact:** limited, because this only happens while a STOP is already in progress, so TWS is
  shutting down anyway. The JVM halts with exit code 1100 (`UNHANDLED_EXCEPTION`) instead of
  exiting through File > Exit, so TWS may not save its settings. A `COLDRESTART` marker written
  by the first STOP still triggers the restart.
- **Fix:** `if (mChannel != null) mChannel.close();`. `RestartTask.java:63` has the same pattern
  but is not currently a bug: its only caller, `CommandDispatcher`, always passes a channel.

---

## Security (command server)

### S1. `ControlFrom` hostname matching depends on DNS and stalls the accept loop

- **Location:** `CommandServer.java:186`
- **Problem:** `allowedClient.equalsIgnoreCase(socket.getInetAddress().getHostName())` relies on
  a reverse DNS (PTR) lookup. The spoofing risk is smaller than it looks: Java's `getHostName()`
  confirms the PTR name with a forward lookup and falls back to the IP literal if they don't
  match, so controlling only the source IP's reverse DNS is not enough. An attacker would also
  need control of the allowed hostname's forward DNS, or a poisoned DNS cache. Access control
  should still not depend on DNS.
- **Also:** the lookup runs inside the single accept loop, and runs for every connection that
  doesn't match by IP, including denied ones. A slow DNS server therefore stalls every new
  connection.
- **Fix:** match IP addresses only (or resolve the configured hostnames forward, once, at startup).

### S2. No authentication, no timeouts, unbounded threads

- **Location:** `CommandServer.java`, `CommandChannel.java`
- **Problem:** plaintext protocol with no shared secret; access depends only on the source IP.
  `readLine()` has no socket timeout or line-length limit, and `MyCachedThreadPool` is unbounded,
  so an allowed client can tie up threads indefinitely. With `BindAddress` empty, the server
  listens on all interfaces.
- **Fix (suggested):** default the bind address to loopback; add `setSoTimeout`; optionally add a
  shared-secret handshake.

### S3. IPv6 loopback clients are rejected

- **Location:** `CommandServer.java:182`
- **Problem:** the client is compared with `InetAddress.getLoopbackAddress()` (normally
  `127.0.0.1`). A client connecting over `::1` is refused unless it is listed in `ControlFrom`.
  This is easy to hit: on Windows `localhost` usually resolves to `::1` first. (The bundled
  `SendCommand.ps1` and `commandsend.sh` default to `127.0.0.1`, so they are not affected.)
- **Fix:** `socket.getInetAddress().isLoopbackAddress()`.

---

## Low severity

| # | Location | Issue |
|---|----------|-------|
| L1 | `CommandChannel.java:46-54` | If `setupStreams()` failed, `mInstream` is null and `close()` throws `NullPointerException` on a pool thread → JVM halt. Needs a connection reset at connect time. |
| L2 | `CommandChannel.java:135-136` | Streams use the platform default charset; specify UTF-8/ASCII explicitly. |
| L3 | `Utils.java:59-91` | `invokeMenuItem` retries every 250 ms with no limit while a menu item is disabled, so the calling thread can hang forever. |
| L4 | `AbstractLoginHandler.java:163` | `setMissingCredential` throws `NullPointerException` if the text field is not found (e.g. after an IBKR layout change); other finders are null-checked. |
| L5 | `DefaultLoginManager`, `config.ini`, start scripts | Credentials can be passed as command-line arguments (the `UserId`/`Password` settings in `StartTWS.ps1`/`StartGateway.ps1`, and the Unix start scripts, still do this). They are masked in IBC's log (`IbcTws.java:460`) but visible to anyone who can list processes. `config.ini` stores them in plaintext. |
| L6 | `RestartTask.java:100-115` | Works out "next minute" with manual hour/minute rollover; `now.plusMinutes(1).withSecond(0).withNano(0)` does the same. The 1 ms busy-wait while the seconds are ≥ 58 is deliberate: it keeps the restart time at least about 2 s away. `plusMinutes` doesn't replace it, but sleeping until the next minute would. |

---

## Suggested fix order

1. H1: null-check the main window in RECONNECTDATA/RECONNECTACCOUNT, reply `ERROR`, and dispatch
   the key events on the Swing event thread.
2. H2: read the main-window future into a local variable inside the lock; clear it under the same lock.
3. H3 + L3 + M1: in `StopTask.stop`, check `invokeMenuItem`'s return value, log and recover,
   clear `_Running` on failure, null-guard `mChannel`; give `invokeMenuItem` a retry limit.
4. H6: move blocking work off the single scheduler thread and log scheduled-task exceptions.
5. S3 + S1: use `isLoopbackAddress()`; remove the hostname match from `ControlFrom`.
6. H5: first check whether the Gateway main frame is decorated; then make the countdown overlay
   safe (initialise its state, run it on the Swing event thread, catch and log errors).
