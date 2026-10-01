# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

IBC was retired on 1 September 2026 and the upstream repo is archived. Work is limited to finishing in-progress items and fixing significant bugs. Don't propose new features unless asked.

## Build

Gradle (Kotlin DSL, `build.gradle.kts`) via the committed wrapper, so only a JDK 17+ is needed. The code compiles with `release = 17`. The TWS jar folder (for example `C:\Jts\1051\jars`) must be given in the `IBC_BIN` environment variable or as `-PibcBin=<dir>`. Compilation fails without it, but tasks like `clean` still run. Any TWS version's jars work, because IBC compiles against TWS/Gateway entry points (`jclient.LoginFrame`, `ibgateway.GWClient`) whose package and class names don't change.

```
gradlew jar      # build/libs/IBC.jar
gradlew          # default "dist": also updates resources/IBC.jar + resources/version, writes build/dist/IBC{Win,Linux,Macos}-<ver>.zip
gradlew clean    # delete build/
```

- The version lives only in `gradle.properties`. `IbcVersionInfo` is generated into `build/generated/sources/version`, so it doesn't exist in `src/`.
- `src/` is the Java source root (not `src/main/java`).
- `resources/IBC.jar` is committed and ships in the release zips. `gradlew dist` overwrites it, which changes a tracked file.
- The per-platform zip contents are the include/exclude rules in the `distWin`/`distLinux`/`distMacos` tasks. `.sh` files get Unix execute permission in the zips.
- Compilation uses `-Xlint:all`. The configuration cache is enabled, so build logic must not touch `project` at execution time.
- There is no test suite and no linter. The only way to verify a change is to run IBC against a real TWS and Gateway.

User guide PDF: `docs/makedocs/makeUserGuide.ps1` (pandoc + xelatex) builds `docs/userguide.pdf` from `docs/userguide.md`.

## Windows scripts

All Windows scripts in `resources/` are PowerShell 7 (`#Requires -Version 7`, run with `pwsh`); there are no `.bat`/`.vbs` files. `StartTWS.ps1`/`StartGateway.ps1` hold the user's settings in a `$Settings` hashtable and splat it into `scripts/StartIBC.ps1`, which does everything: banner, day-of-week log file, Java/classpath/VM-option discovery, and the restart loop (exit codes 1111/1112, `autorestart` file, `PAUSE<id>`/`COLDRESTART<id>` marker files written by `RestartTask`/`StopTask`). Without `-Inline`, `StartIBC.ps1` re-runs the calling script in a new `pwsh` window with `-Inline -InWindow`. `SendCommand.ps1` talks to the command server over TCP directly; `Stop.ps1` etc. are one-line wrappers. The `.lnk` shortcuts and `Start TWS (autorestart).xml` invoke `pwsh.exe -ExecutionPolicy Bypass -File ...`. The Linux/macOS `.sh` scripts are separate and unchanged.

## Architecture

`docs/reference/how-ibc-works.md` is the detailed design reference. Read it before making non-trivial changes. `docs/spec/code-review-findings.md` lists known bugs (races, STOP/RESTART issues, command-server security) with a suggested fix order.

**Single process.** IBC is the JVM's main class (`ibcalpha.ibc.IbcTws` or `IbcGateway`, launched by `resources/scripts/StartIBC.ps1` / `ibcstart.sh`). It calls TWS's own `main` in-process. IBC can't restart TWS after a crash: if either one exits, so does the other.

**Startup** (`IbcTws.load()`): `setupDefaultEnvironment` installs the pluggable singletons, then it starts the command server and shutdown timer, registers the AWT window listener, and launches TWS or Gateway.

**Pluggable managers.** `Settings`, `LoginManager`, `MainWindowManager`, `TradingModeManager` and `ConfigDialogManager` are abstract classes, each with a static `initialise(...)` and a `Default*` implementation. They are the dependency-injection seam that embedders such as `samples/IbcLoader` use, so keep them public and swappable. Settings come from the `.ini` file (`resources/config.ini` is the documented template) via `Settings.settings().getString/getInt/getBoolean`.

**Window handling (the core mechanism).** `TwsListener` is a global `AWTEventListener` for window events. For each event it walks the ordered `WindowHandler` list built in `IbcTws.createWindowHandlers()`. The *first* handler whose `recogniseWindow` matches takes the window (`filterEvent`, then `handleWindow`). No other handler sees it.
- Handlers recognise windows by their content (title, label text, button captions, menu items) using `SwingUtils.find*` helpers. They act through Swing calls (`doClick`, `setText`, `setSelected`), never screen coordinates. That's why TWS has to run in English: `JtsIniManager` forces `Locale=en` in `jts.ini`.
- **Registration order matters** when windows look alike. For example, `SecondFactorAuthenticationDialogHandler` must come before `SecurityCodeDialogHandler`.
- A new dialog handler is a new `*Handler` class plus a line in `createWindowHandlers()`. Usually it also needs a new setting documented in `resources/config.ini` and `docs/userguide.md`.

**Global Configuration changes.** Settings applied through TWS's settings dialog (API port, master client ID, read-only API, auto-restart time, `ENABLEAPI`, and so on) are `ConfigurationAction`s run through `ConfigurationTask`. It opens the dialog via `ConfigDialogManager` (menu path differs between Gateway, TWS Classic and TWS Mosaic), runs the action on the EDT, and then releases the dialog. The `Configure*Task` classes follow this pattern.

**Threading rules.** Touch Swing components only on the EDT. `GuiDeferredExecutor` queues work there asynchronously, while `GuiExecutor`/`GuiSynchronousExecutor` run it synchronously. Blocking waits (for the main window, the config dialog, a menu item) must run on pool threads (`MyCachedThreadPool`, `MyScheduledExecutorService`), never on the EDT. `getMainWindow()` and `Utils.invokeMenuItem()` throw if called from the EDT. Uncaught exceptions end in `Utils.exitWithException`, which kills TWS too.

**Session state.** `SessionManager` tracks Gateway vs TWS vs FIX mode and readiness (`awaitReady`). Many tasks branch on `SessionManager.isGateway()` / `isFIX()`.

**Command server.** `CommandServer` listens on `CommandServerPort` (restricted by `ControlFrom`/`BindAddress`). `CommandDispatcher` handles `STOP`, `RESTART`, `ENABLEAPI`, `RECONNECTDATA`, `RECONNECTACCOUNT`, `PAUSE` and `EXIT`. The `resources/*.ps1`/`*.sh` command scripts send these commands.

## Contribution constraints (from CONTRIBUTING.md)

- This fork does **not** need backward compatibility with existing IBC installs (the owner's decision), despite CONTRIBUTING.md's backward-compatibility rule. Config and script formats may change freely.
- Java code must stay cross-platform (Windows, Linux, macOS) and work for both TWS and Gateway.
- Never bypass IB's login security, such as 2FA or security-code entry.
- Match the existing code style.
- `resources/scripts/` holds launcher internals that end users don't edit. User-facing changes belong in `config.ini`, the top-level start scripts and the user guide.
