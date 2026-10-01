# IBC Java Code Review — Findings

- **Date:** 2026-09-30
- **Scope:** `src/ibcalpha/ibc` (83 files, ~8.8k lines) at commit `fc6d917` (version 3.24.2)
- **Method:** static reading of the source; none of the issues below have been reproduced at runtime.

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
   ~40 `WindowHandler`s `recogniseWindow(window)`. Windows are identified by their content: title,
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

---

## High severity

### H1. RECONNECTDATA can crash TWS; RECONNECTACCOUNT can hang

- **Location:** `CommandDispatcher.java:77-85`, `:94-102`
- **Problem:** `getMainWindow(1, TimeUnit.MILLISECONDS)` returns `null` if the main window is not
  yet known (during login, or on the Gateway before the splash frame closes).
  `new KeyEvent(null, ...)` then throws `IllegalArgumentException("null source")` on a pool thread,
  so the JVM halts.
- **Impact:** any client permitted on the command port can terminate TWS by sending
  `RECONNECTDATA` at the wrong moment. `RECONNECTACCOUNT` uses the no-timeout overload and blocks
  the client forever instead.
- **Also:** `jf.dispatchEvent(...)` is called from a pool thread, not the Swing event thread.
- **Fix:** null-check the window and reply `ERROR main window not available`; use a bounded
  timeout for both commands; send the events via `SwingUtilities.invokeLater`.

### H2. Race between `getMainWindow` and `setMainWindow`

- **Location:** `DefaultMainWindowManager.java:88-104` and `:139-140`
- **Problem:** `mainWindowFuture` is created inside `synchronized(futureCreationLock)` but
  dereferenced (`mainWindowFuture.get(...)`) after the lock is released. `setMainWindow` (on the
  Swing event thread) sets `mainWindowFuture = null` without taking the lock.
- **Scenario:** thread A leaves the synchronized block. The main window opens and the event thread
  sets the future to null. Thread A calls `.get()` on null → `NullPointerException` → JVM halt.
- **Impact:** the window is short but lines up with the moment STOP, RESTART and scheduled tasks
  are waiting for the main window.
- **Fix:** copy the future to a local variable inside the lock and call `.get()` on the local;
  clear the field in `setMainWindow` under the same lock.

### H3. STOP failures are swallowed and then block every later STOP

- **Location:** `StopTask.java:84` — `catch (Exception e) { }`
- **Problem:** if `Utils.invokeMenuItem(..., {"File","Exit"})` throws (e.g. IBKR renames the
  menu), nothing is logged. The static `SwitchLock _Running` is never cleared, so every later STOP
  answers "STOP already in progress".
- **Impact:** scheduled cold restarts (`ColdRestartTime`) and error-driven restarts stop working,
  with no trace in the log.
- **Fix:** log the exception, clear `_Running` on failure, and report `ERROR` to the channel.

### H4. `StopTask` "already in progress" path dereferences a null channel

- **Location:** `StopTask.java:40`
- **Problem:** five callers pass `null` as the channel (`AbstractLoginHandler:191`,
  `LoginErrorDialogHandler:42`, `LoginFailedDialogHandler:43`, `GatewayDialogHandler:45`,
  `IbcTws:504`). Every other method null-checks `mChannel`, but this path calls
  `mChannel.close()` directly → `NullPointerException` on a pool thread → JVM halt.
- **Scenario:** two error dialogs, or an error dialog plus the ColdRestartTime timer, trigger at
  the same time.
- **Fix:** `if (mChannel != null) mChannel.close();`. `RestartTask.java:62` has the same pattern
  and should get the same guard.

### H5. Restart countdown overlay can crash or abort the restart

- **Location:** `RestartTask.java:132-178` (fallback path used when there is no
  `File > Restart...` menu)
- **Problems:**
  - `Countdown.paintComponent` reads `secsRemaining`, which is filled in asynchronously by a
    scheduled task. The first paint can run first → `NullPointerException` on the Swing event
    thread → JVM halt about a minute before the planned restart.
  - `JFrame.setOpacity(0.80f)` throws `IllegalComponentStateException` if the frame is decorated.
    It propagates to `run()`'s catch → `Utils.exitWithException`, so IBC exits instead of
    restarting.
  - `setOpacity` / `setGlassPane` are called from a pool thread, not the Swing event thread.
  - The per-second `scheduleAtFixedRate` task is never cancelled.
- **Fix:** initialise `secsRemaining` in the constructor; build the overlay on the Swing event
  thread inside try/catch that only logs; keep the `ScheduledFuture` and cancel it.

---

## Security (command server)

### S1. `ControlFrom` accepts reverse-DNS hostnames (spoofable)

- **Location:** `CommandServer.java:183`
- **Problem:** `allowedClient.equalsIgnoreCase(socket.getInetAddress().getHostName())` relies on
  a reverse DNS (PTR) lookup. Whoever controls the source IP's reverse DNS controls the answer, so
  an attacker can pose as a hostname that is on the allowlist.
- **Also:** the lookup runs inside the single accept loop, so a slow DNS server stalls every new
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

- **Location:** `CommandServer.java:179`
- **Problem:** the client is compared with `InetAddress.getLoopbackAddress()` (normally
  `127.0.0.1`). A client connecting over `::1` is refused unless it is listed in `ControlFrom`.
- **Fix:** `socket.getInetAddress().isLoopbackAddress()`.

---

## Low severity

| # | Location | Issue |
|---|----------|-------|
| L1 | `CommandChannel.java:47` | If `setupStreams()` failed, `mInstream` is null and `close()` throws `NullPointerException` on a pool thread → JVM halt. Needs a connection reset at connect time. |
| L2 | `CommandChannel.java:137-138` | Streams use the platform default charset; specify UTF-8/ASCII explicitly. |
| L3 | `Utils.java:61-90` | `invokeMenuItem` retries every 250 ms with no limit while a menu item is disabled, so the calling thread can hang forever. |
| L4 | `AbstractLoginHandler.java:163` | `setMissingCredential` throws `NullPointerException` if the text field is not found (e.g. after an IBKR layout change); other finders are null-checked. |
| L5 | `DefaultLoginManager`, `config.ini` | Credentials can be passed as command-line arguments. They are masked in IBC's log (`IbcTws.java:460`) but visible to anyone who can list processes. `config.ini` stores them in plaintext. |
| L6 | `RestartTask.java:96-110` | Works out "now + 1 minute" by hand with a 1 ms busy-wait; `LocalTime.now().plusMinutes(1)` does the same. |

---

## Suggested fix order

1. H1: null-check the main window in RECONNECTDATA/RECONNECTACCOUNT, reply `ERROR`, and dispatch
   the key events on the Swing event thread.
2. H2: read the main-window future into a local variable inside the lock; clear it under the same lock.
3. H3 + H4: log and recover in `StopTask.stop`, clear `_Running` on failure, null-guard `mChannel`.
4. S1 + S3: remove the hostname match from `ControlFrom`; use `isLoopbackAddress()`.
5. H5: make the countdown overlay safe (initialise its state, run it on the Swing event thread,
   catch and log errors).
