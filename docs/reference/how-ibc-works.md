# How IBC Works

- **Scope:** `src/ibcalpha/ibc` (now `src/main/java/ibcalpha/ibc`), as of commit `fc6d917` (version 3.24.2)
- **Related:** [Code review findings](../spec/code-review-findings.md)

IBC automates the Interactive Brokers TWS and IB Gateway desktop apps: it logs in, dismisses
dialogs, applies configuration, and restarts or stops on command. It does this **from inside
the TWS/Gateway process**, working directly on the live Swing objects. It does not use
screen scraping, synthetic mouse input, OS accessibility APIs or reflection.

---

## 1. Process model: IBC and TWS share one JVM

```
ibc.ps1 start
        │  java -cp <IBC jar>;<TWS jars> ... ibcalpha.ibc.IbcTws  <config.ini> [mode]
        ▼
┌──────────────────────────── one JVM ────────────────────────────┐
│  IbcTws.main()                                                  │
│    ├─ set up IBC (settings, managers, listener, command server) │
│    └─ jclient.LoginFrame.main(args)   ← TWS's own entry point   │
│                                                                 │
│  TWS/Gateway Swing windows  ◄── IBC handlers act on them        │
└─────────────────────────────────────────────────────────────────┘
```

- The start scripts launch `java` with IBC's class as the entry point:
  `ibcalpha.ibc.IbcTws` for TWS, `ibcalpha.ibc.IbcGateway` for the Gateway
  (`src/main/dist/ibc.ps1`, `$entryPoint`). The TWS jars are on the classpath.
- After initialising, IBC starts TWS by calling its `main` directly:
  - TWS: `jclient.LoginFrame.main(twsArgs)` (`IbcTws.java:516`)
  - Gateway: `ibgateway.GWClient.main(twsArgs)` (`IbcTws.java:474`)
- IBC therefore controls the process from the start and can reference any TWS window object.

## 2. Startup sequence

`IbcTws.main` (`IbcTws.java:211`) → `setupDefaultEnvironment` → `load()`:

| Step | Code | Purpose |
|------|------|---------|
| 1 | `Thread.setDefaultUncaughtExceptionHandler(...)` | Any uncaught exception on any thread halts the JVM (`Runtime.halt`). |
| 2 | `SessionManager.initialise(isGateway)` | Records whether this is TWS or Gateway. |
| 3 | `Settings.initialise(new DefaultSettings(args))` | Loads `config.ini` (args[0]). |
| 4 | `LoginManager.initialise(...)` | Credentials from args or settings; tracks login state. |
| 5 | `MainWindowManager.initialise(...)` | Lets any thread wait for the TWS main window. |
| 6 | `TradingModeManager.initialise(...)` | Live or paper trading. |
| 7 | `startCommandServer()` | Optional TCP control port (section 7). |
| 8 | `startShutdownTimerIfRequired()` | Scheduled shutdown / `ColdRestartTime`. |
| 9 | `createToolkitListener()` | **The global window hook** (section 3). |
| 10 | `startSavingTwsSettingsAutomatically()` | `SaveTwsSettingsAt` → scheduled `File > Save Settings`. |
| 11 | `startTwsOrGateway()` | Checks `jts.ini`, starts the session, calls TWS's `main`, queues configuration tasks. |

The singletons (`Settings`, `LoginManager`, `MainWindowManager`, `ConfigDialogManager`,
`TradingModeManager`) are each an abstract class with a `Default*` implementation, so an
embedding application can plug in its own.

## 3. The window hook

```java
// IbcTws.java:301
Toolkit.getDefaultToolkit().addAWTEventListener(
    new TwsListener(createWindowHandlers()), AWTEvent.WINDOW_EVENT_MASK);
```

`addAWTEventListener` is public AWT API. It delivers **every** window event in the JVM
(opened, activated, closing, closed, …) whichever code created the window. This is how IBC
sees TWS's dialogs without TWS knowing about IBC.

`TwsListener.eventDispatched` (`TwsListener.java:43`):

1. Gets the `Window` from the `WindowEvent`.
2. Queues the work with `SwingUtilities.invokeLater` (`GuiDeferredExecutor`), so handlers run
   on the Swing event thread after TWS has finished building the window.
3. Goes through the handler list in order. The **first** handler whose `recogniseWindow`
   returns true takes the window:
   - `filterEvent(window, eventId)`: does this handler care about this event type (usually
     only `WINDOW_OPENED`)?
   - `handleWindow(window, eventId)`: do the work.
4. Optionally logs the window's component tree (section 9).

### The `WindowHandler` contract

```java
interface WindowHandler {
    boolean recogniseWindow(Window window);          // is this my window?
    boolean filterEvent(Window window, int eventId); // do I care about this event?
    void    handleWindow(Window window, int eventID);// act on it
}
```

About 40 handlers are registered in `IbcTws.createWindowHandlers()` (`IbcTws.java:304`).
**Order matters**: for example, `SecondFactorAuthenticationDialogHandler` must come before
`SecurityCodeDialogHandler` because both windows contain an "Enter Read Only" button.

| Group | Handlers |
|-------|----------|
| Login | `LoginFrameHandler`, `GatewayLoginFrameHandler`, `SecondFactorAuthenticationDialogHandler`, `SecurityCodeDialogHandler`, `ReloginDialogHandler`, `LoginFailedDialogHandler`, `LoginErrorDialogHandler`, `TooManyFailedLoginAttemptsDialogHandler`, `ExistingSessionDetectedDialogHandler`, `TradingLoginHandoffDialogHandler`, `PasswordExpiryWarningFrameHandler` |
| Main window / lifecycle | `MainWindowFrameHandler`, `GatewayMainWindowFrameHandler`, `SplashFrameHandler`, `NonBrokerageAccountDialogHandler`, `ShutdownProgressDialogHandler`, `ExitConfirmationDialogHandler`, `RestartConfirmationDialogHandler`, `AutoRestartConfirmationDialog`, `GatewayDialogHandler` |
| Configuration | `GlobalConfigurationDialogHandler`, `ApiChangeConfirmationDialogHandler`, `ResetOrderIdConfirmationDialogHandler`, `BidAskLastSizeDisplayUpdateDialogHandler` |
| Nuisance dialogs | `TipOfTheDayDialogHandler`, `NewerVersionDialogHandler`, `NewerVersionFrameHandler`, `NotCurrentlyAvailableDialogHandler`, `NSEComplianceFrameHandler`, `BlindTradingWarningDialogHandler`, `CryptoOrderConfirmationDialogHandler`, `AcceptIncomingConnectionDialogHandler`, `ReconnectDataOrAccountConfirmationDialogHandler`, `TradesFrameHandler` |

## 4. Recognising a window

Handlers identify windows by **what they show**: class (`JFrame` / `JDialog`), title,
label text, button captions or menu items. Examples:

| Handler | Recognised by |
|---------|---------------|
| `ExitConfirmationDialogHandler` | a `JDialog` with the label "Are you sure you want to exit?" |
| `LoginFrameHandler` | a frame with a "Log In" or "Paper Log In" button |
| `MainWindowFrameHandler` | a `JFrame` whose menu bar has `File > Lock Application` |
| `GlobalConfigurationDialogHandler` | a `JDialog` whose title contains "Configuration" |

This is why IBC needs TWS to run in English: `JtsIniManager` makes sure `jts.ini` contains
`[Logon] Locale=en` (and `UseSSL=true`, `displayedproxymsg=1`) before TWS starts.

## 5. Finding controls

### Walking the component tree

A Swing window is a tree of `Container`s holding `Component`s. `ComponentIterator`
(`ComponentIterator.java`) walks it depth-first with an explicit stack, calling
`Container.getComponents()` under the component's tree lock.

### The `SwingUtils.find*` helpers

All of them follow one pattern: walk the tree and return the first component of the right
type that matches.

```java
static JButton findButton(Container container, String text) {
    ComponentIterator iter = new ComponentIterator(container);
    while (iter.hasNext()) {
        Component c = iter.next();
        if (c instanceof JButton && text.equalsIgnoreCase(((JButton) c).getText()))
            return (JButton) c;
    }
    return null;
}
```

| Strategy | Used for | Example |
|----------|----------|---------|
| **Type + text** | buttons, checkboxes, radio/toggle buttons, labels, menu items, text areas | `findButton(w, "Log In")`, `findCheckBox(dlg, "Enable ActiveX and Socket Clients")` |
| **Type + position** (nth of that type) | controls with no caption: text fields, combo boxes, lists | `findTextField(w, 0)` = username, `findTextField(w, 1)` = password |
| **Scoped search** | an unlabelled control next to a label | find the container holding "Socket port", then its first `JTextField` (`ConfigureTwsApiPortTask.java:43-46`) |
| **Menu path** | menu commands | `findMenuItemInAnyMenuBar(w, {"File", "Exit"})` |
| **Tree path** | Global Configuration navigation | `findTree` + `findChildNode(model, node, "API")` |

## 6. Acting on controls

Once IBC has the component object, it calls normal Swing methods on it:

| Action | Call |
|--------|------|
| Click a button | `JButton.doClick()`. `SwingUtils.clickButton` first re-enables a disabled button. |
| Enter text | `JTextField.setText(...)` |
| Tick / choose | `JCheckBox.setSelected(...)`, `JToggleButton.doClick()`, `JRadioButton` |
| Menu command | `JMenuItem.doClick()` via `Utils.invokeMenuItem` (runs on the Swing event thread and retries every 250 ms while the item is disabled) |
| Config page | `JTree.setSelectionPath(TreePath)` via `Utils.selectConfigSection` |
| Keyboard shortcut | `KeyEvent` sent with `Component.dispatchEvent` (only for RECONNECTDATA / RECONNECTACCOUNT) |

Nothing depends on screen coordinates or focus, so it works with the window minimised.

### Threading rules

- Swing is single-threaded. Code that reads or changes components must run on the Swing
  event thread (EDT).
- `GuiDeferredExecutor` = `SwingUtilities.invokeLater` (queue and return).
  `GuiExecutor` / `GuiSynchronousExecutor` run synchronously on the EDT.
- Waiting (for the main window, the config dialog, a menu item) happens on pool threads
  (`MyCachedThreadPool`, `MyScheduledExecutorService`), **never** on the EDT.
  `getMainWindow()` and `invokeMenuItem()` throw `IllegalStateException` if called from the EDT.

## 7. Key flows

### 7.1 Login

1. TWS opens its login frame. `LoginFrameHandler` recognises it (Log In button).
2. `AbstractLoginHandler.filterEvent` accepts `WINDOW_OPENED` only when the login state is
   `LOGGED_OUT` or `LOGIN_FAILED`.
3. `initiateLogin` (`AbstractLoginHandler.java:78`):
   - `initialise`: click the **Live Trading** / **Paper Trading** toggle; reload `jts.ini`; add a
     document listener on the username field that sets "Use/store settings on server" from
     `StoreSettingsOnServer`.
   - `setFields`: username → text field 0, password → text field 1.
   - `preLogin`: if a credential is missing, focus that field and leave it to the user.
   - `doLogin`: on the EDT, set state `LOGGING_IN` and click **Log In**.
4. For live accounts, 2FA is handled by `SecondFactorAuthenticationDialogHandler`. From TWS 1016
   the login frame turns into the 2FA frame in place, which is detected via the "LOGIN" label.
5. Failures are handled by `LoginFailedDialogHandler`, `LoginErrorDialogHandler`,
   `TooManyFailedLoginAttemptsDialogHandler`. Several of them trigger a **cold restart**
   (`StopTask` with the force-cold-restart flag, which writes a `COLDRESTART<sessionid>` file
   for the start script to see).
6. `SessionManager.startSession` schedules a watchdog: if no login dialog appears within
   `LoginDialogDisplayTimeout` seconds (default 60), IBC exits.
7. On an automatic restart (`-Drestart` VM option), IBC does not fill in credentials because TWS
   logs itself back in.

### 7.2 Detecting "logged in / ready"

- **TWS:** the main window opening means login is complete. `MainWindowFrameHandler` →
  `SessionManager.setMainWindow` → `MainWindowManager.setMainWindow` sets state `LOGGED_IN`
  and completes the future that other threads are waiting on.
- **Gateway:** the main window exists from the start, so readiness is when **both** the splash
  frame ("Starting application...") has closed **and** the non-brokerage-account dialog has
  closed (`SessionManager.setSplashScreenClosed` / `setNonBrokerageAccountDialogClosed`).
- `SessionManager.awaitReady()` blocks callers until this has happened.

### 7.3 Configuration changes (Global Configuration dialog)

Settings such as `OverrideTwsApiPort`, `OverrideTwsMasterClientID`, `ReadOnlyApi`,
`AutoRestartTime`/`AutoLogoffTime`, `ResetOrderIdsAtStart`, `SendMarketDataInLotsForUSstocks`,
the API-precaution flags and the `ENABLEAPI` command are applied through the TWS settings dialog:

```
ConfigurationTask(action).executeAsync()                   pool thread
  └─ ConfigDialogManager.getConfigDialog()                 blocks until the dialog is open
       └─ GetConfigDialogTask.call()
            ├─ wait for main window + SessionManager.awaitReady()
            ├─ invokeMenuItem: Gateway  "Configure > Settings"
            │                  TWS      "Edit > Global Configuration..." (Classic)
            │                        or "File > Global Configuration..." (Mosaic)
            └─ wait until GlobalConfigurationDialogHandler reports the dialog opened
  └─ action.initialise(dialog)
  └─ run action on the EDT (GuiExecutor) and wait
       e.g. Utils.selectApiSettings(dialog)  → tree path API > Settings
            find control, compare, set value, click "OK"
  └─ ConfigDialogManager.releaseConfigDialog()
```

`DefaultConfigDialogManager` keeps a usage count so several tasks can share one open dialog.
It also tracks whether the user opened the dialog, so IBC doesn't close it on them.

### 7.4 Scheduled activities

| Setting | Mechanism |
|---------|-----------|
| `ClosedownAt` / `ColdRestartTime` | `MyScheduledExecutorService` → `StopTask` |
| `AutoRestartTime` / `AutoLogoffTime` | written into TWS's own Lock and Exit settings (TWS does the restart) |
| `SaveTwsSettingsAt` | `TwsSettingsSaver` → `invokeMenuItem("File", "Save Settings")` at fixed times or intervals |

### 7.5 Stop and restart

- **STOP** (`StopTask`): if not yet logged in, `Runtime.halt(0)` immediately. Otherwise invoke
  `File > Exit` (TWS) or `File > Close` (Gateway). `ExitConfirmationDialogHandler` then clicks
  **Yes**, but only while a stop is in progress, so a user-initiated exit still asks for confirmation.
- **RESTART / PAUSE** (`RestartTask`): invoke `File > Restart...` if the menu item exists. Otherwise
  set TWS's auto-restart time to the next minute and show a countdown on the main window's glass
  pane. PAUSE also writes a `PAUSE<sessionid>` flag file so the start script doesn't relaunch.

## 8. Command server

Optional, enabled by `CommandServerPort` (0 = off).

- `CommandServer` (pool thread) opens a `ServerSocket` on `BindAddress` (or all interfaces)
  and accepts connections one at a time.
- Clients are allowed if they come from the bound address, the loopback address, or any
  entry in `ControlFrom` (IP address or hostname).
- Each connection gets a `CommandDispatcher` on a pool thread, with a line-oriented text
  protocol over `CommandChannel`:

| Command | Effect |
|---------|--------|
| `STOP` | `StopTask` (section 7.5) |
| `RESTART` / `PAUSE` | `RestartTask` (TWS/Gateway only, not FIX) |
| `ENABLEAPI` | `EnableApiTask`: tick "Enable ActiveX and Socket Clients" (TWS only) |
| `RECONNECTDATA` | sends Ctrl+Alt+F (Cmd+Alt+F on macOS) to the main window |
| `RECONNECTACCOUNT` | sends Ctrl+Alt+R (Cmd+Alt+R on macOS) to the main window |
| `EXIT` | closes the connection |

- Replies: `OK <info>`, `ERROR <info>`, optional `INFO <info>` (hidden unless
  `SuppressInfoMessages=no`), and an optional `CommandPrompt`.
- `src/main/dist/ibc.ps1` is the bundled client (`ibc.ps1 stop`, `ibc.ps1 restart`, ...).

## 9. Diagnostics: window structure logging

When TWS changes a dialog, handlers stop matching. To find the new captions or field order:

| Setting | Values |
|---------|--------|
| `LogStructureScope` | `known` (default), `unknown`, `untitled`, `all` |
| `LogStructureWhen` | `never` (default), `open`, `activate`, `openclose`, or any window event name |

`SwingUtils.getWindowStructure` then prints the full component tree (type, text, state,
indented by depth) of matching windows to the IBC log. From that you can update a handler's
`recogniseWindow` text or `findTextField` index. `IncludeStackTraceForExceptions=yes` adds
stack traces to logged exceptions.

## 10. Error handling and exit codes

- Missing controls raise `IbcException` (the message names the control). In the login path this
  exits with `ErrorCodes.CANT_FIND_CONTROL`.
- Any uncaught exception on any thread goes to `UncaughtExceptionHandler` →
  `Utils.exitWithException(UNHANDLED_EXCEPTION)` → `Runtime.halt`. This takes TWS down with it;
  see the code review findings for the consequences.
- Exit codes are defined in `ErrorCodes.java`. The start scripts use them together with the
  `COLDRESTART` / `PAUSE` flag files to decide whether to relaunch.

## 11. Implications for porting

Everything above depends on holding live Java objects inside the TWS JVM. A separate
process in another language (e.g. C#) cannot do this. The nearest equivalent is the **Java
Access Bridge** (Windows only). It exposes a similar tree (role, name, children) and actions
(click, set text), so the *design* carries over: recognise by content, find by type + text or
position, act. But every call is IPC, the names are accessibility names, not `getText()`, and
cross-platform support is lost. The practical option is to keep this Java core and write only
the launcher, supervisor and command-server client in another language.
