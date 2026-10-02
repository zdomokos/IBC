# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

IBC was retired on 1 September 2026 and the upstream repo is archived. Work is limited to finishing in-progress items and fixing significant bugs. Don't propose new features unless asked.

This fork is Windows-only for now: the Linux/macOS `.sh` scripts were removed and will be added back when needed. The Java code must still stay cross-platform.

## Layout

- `src/main/java/ibcalpha/ibc/`: the Java source (one package).
- `src/main/dist/`: the other files in the distribution ZIP (`ibc.ps1`, `config.ini`, the two `.lnk` shortcuts, `Start TWS (autorestart).xml`); the `dist` task adds `IBC.jar`, `LICENSE.txt` and `docs/userguide.md`.
- `scripts/deploy.ps1`: developer tool that builds and installs the ZIP locally.
- `docs/`: user guide (`userguide.md`; `makedocs/makeUserGuide.ps1` generates `build/userguide.pdf`, which isn't committed), `reference/` design notes, `spec/` review findings, `upstream-README.md` (archived).
- `samples/`: `MultipleUsers` (config files) and `IbcLoader` (embedding IBC in a Java app; has its own `.bat` files and an old `IBC.jar`).

## Build

Gradle (Kotlin DSL, `build.gradle.kts`) via the committed wrapper, so only a JDK 17+ is needed. The code compiles with `release = 17`. The TWS jar folder (for example `C:\Jts\1051\jars`) must be given in the `IBC_BIN` environment variable or as `-PibcBin=<dir>`. Compilation fails without it, but tasks like `clean` still run. Any TWS version's jars work, because IBC compiles against TWS/Gateway entry points (`jclient.LoginFrame`, `ibgateway.GWClient`) whose package and class names don't change.

```
gradlew jar      # build/libs/IBC.jar
gradlew          # default "dist": build/dist/IBC-<ver>-windows.zip (IBC.jar + LICENSE.txt + docs/userguide.md + src/main/dist)
gradlew clean    # delete build/
```

- The version is the build date, `yy.M.d` (eg `26.10.1`), computed in `build.gradle.kts` through a `ValueSource` (so the configuration cache notices a new day); `-PibcVersion=<v>` overrides it. `scripts/deploy.ps1` deploys the newest `build/dist/IBC-*-windows.zip`. `IbcVersionInfo` is generated into `build/generated/sources/version`, so it doesn't exist in `src/`. The `dist` task stamps it into `ibc.ps1` (`@IBC_VERSION@`, Gradle `ReplaceTokens`).
- Nothing the build produces is committed; output only goes to `build/`.
- Compilation uses `-Xlint:all`. The configuration cache is enabled, so build logic must not touch `project` or script-level values at execution time (compute values at configuration time into locals).
- There is no test suite and no linter. The only way to verify a change is to run IBC against a real TWS and Gateway.

`scripts/deploy.ps1 <folder>` builds (`-SkipBuild` to skip) and installs the ZIP into a local folder. It also generates `live` and `paper` instances: shortcuts running `ibc.ps1 start <a>` (only applicable shortcuts are created: plain ones need `<ConfigFolder>\config.ini`, Gateway ones an installed `<TwsPath>\ibgateway\<n>\jars`; stale generated ones are deleted), `<ConfigFolder>\config-<a>.ini` created only if missing (an existing one without `TwsSettingsPath` gets that line appended), settings folder `<TwsPath>\<a>` seeded on creation by copying `jts.ini`, `xmlopt.dat` and the 40-letter user folders minus `*.ibgzenc` logs from the existing settings folder, ports 7496/7462 and 7497/7463; `-NoAccounts` skips. The `config.ini` template in the destination is kept on redeploy unless `-OverwriteSettings`; files from older layouts are reported, not deleted. Never deploy to the user's real `C:\IBC` without asking.

User guide PDF: `docs/makedocs/makeUserGuide.ps1` (pandoc + xelatex) builds `build/userguide.pdf` from `docs/userguide.md`; it isn't committed.

## ibc.ps1

The only script shipped is `src/main/dist/ibc.ps1` (PowerShell 7, `#Requires -Version 7`): `ibc.ps1 <command> [<account>] [options]`. `<account>` selects `<ConfigFolder>\config-<account>.ini` (default folder `%USERPROFILE%\Documents\IBC`; no account = `config.ini`; `-Config` overrides).
- `start [-Gateway] [-Inline]`: reads the launcher settings from the config file (section 0 of `config.ini`: `TwsMajorVersion` (default: newest `<TwsPath>\<n>` with `jars`), `TwsPath`, `TwsSettingsPath` (default: folder holding `jts.ini`, i.e. `<TwsPath>\<version>` on recent installers; created if set and missing), `LogPath` (default `<ibc folder>\Logs\<account>`), `JavaPath`, `On2FATimeout`, `MinimizeIbcWindow`). IBC's Java `Properties` loader ignores these keys; `Read-ConfigFile` un-doubles backslashes. Credentials and trading mode are not passed on the command line: IBC reads them from the config file. Without `-Inline` it re-runs itself in a new `pwsh` window with `-Config`/`-Account -Inline -InWindow`. Then the restart loop (exit codes 1111/1112, `autorestart` file, `PAUSE<id>`/`COLDRESTART<id>` marker files written by `RestartTask`/`StopTask`).
- `stop|restart|pause|enableapi|reconnectdata|reconnectaccount`: TCP command-server client; port/server from `CommandServerPort`/`BindAddress` (overridable with `-Port`/`-Server`).
- `version`/`--version`/`-Version`: shows the stamped version; unbuilt it reports `development`.
- The `.lnk` shortcuts and `Start TWS (autorestart).xml` run `pwsh.exe -ExecutionPolicy Bypass -File ...\ibc.ps1 start ...`.

## Architecture

`docs/reference/how-ibc-works.md` is the detailed design reference. Read it before making non-trivial changes. `docs/spec/code-review-findings.md` lists known bugs (races, STOP/RESTART issues, command-server security) with a suggested fix order.

**Single process.** IBC is the JVM's main class (`ibcalpha.ibc.IbcTws` or `IbcGateway`, launched by `ibc.ps1 start`). It calls TWS's own `main` in-process. IBC can't restart TWS after a crash: if either one exits, so does the other.

**Startup** (`IbcTws.load()`): `setupDefaultEnvironment` installs the pluggable singletons, then it starts the command server and shutdown timer, registers the AWT window listener, and launches TWS or Gateway.

**Pluggable managers.** `Settings`, `LoginManager`, `MainWindowManager`, `TradingModeManager` and `ConfigDialogManager` are abstract classes, each with a static `initialise(...)` and a `Default*` implementation. They are the dependency-injection seam that embedders such as `samples/IbcLoader` use, so keep them public and swappable. Settings come from the `.ini` file (`src/main/dist/config.ini` is the documented template) via `Settings.settings().getString/getInt/getBoolean`.

**Window handling (the core mechanism).** `TwsListener` is a global `AWTEventListener` for window events. For each event it walks the ordered `WindowHandler` list built in `IbcTws.createWindowHandlers()`. The *first* handler whose `recogniseWindow` matches takes the window (`filterEvent`, then `handleWindow`). No other handler sees it.
- Handlers recognise windows by their content (title, label text, button captions, menu items) using `SwingUtils.find*` helpers. They act through Swing calls (`doClick`, `setText`, `setSelected`), never screen coordinates. That's why TWS has to run in English: `JtsIniManager` forces `Locale=en` in `jts.ini`.
- **Registration order matters** when windows look alike. For example, `SecondFactorAuthenticationDialogHandler` must come before `SecurityCodeDialogHandler`.
- A new dialog handler is a new `*Handler` class plus a line in `createWindowHandlers()`. Usually it also needs a new setting documented in `src/main/dist/config.ini` and `docs/userguide.md`.

**Global Configuration changes.** Settings applied through TWS's settings dialog (API port, master client ID, read-only API, auto-restart time, `ENABLEAPI`, and so on) are `ConfigurationAction`s run through `ConfigurationTask`. It opens the dialog via `ConfigDialogManager` (menu path differs between Gateway, TWS Classic and TWS Mosaic), runs the action on the EDT, and then releases the dialog. The `Configure*Task` classes follow this pattern.

**Threading rules.** Touch Swing components only on the EDT. `GuiDeferredExecutor` queues work there asynchronously, while `GuiExecutor`/`GuiSynchronousExecutor` run it synchronously. Blocking waits (for the main window, the config dialog, a menu item) must run on pool threads (`MyCachedThreadPool`, `MyScheduledExecutorService`), never on the EDT. `getMainWindow()` and `Utils.invokeMenuItem()` throw if called from the EDT. Uncaught exceptions end in `Utils.exitWithException`, which kills TWS too.

**Session state.** `SessionManager` tracks Gateway vs TWS vs FIX mode and readiness (`awaitReady`). Many tasks branch on `SessionManager.isGateway()` / `isFIX()`.

**Command server.** `CommandServer` listens on `CommandServerPort` (restricted by `ControlFrom`/`BindAddress`). `CommandDispatcher` handles `STOP`, `RESTART`, `ENABLEAPI`, `RECONNECTDATA`, `RECONNECTACCOUNT`, `PAUSE` and `EXIT`. `ibc.ps1 stop` etc. send these commands.

## Contribution constraints (from CONTRIBUTING.md)

- This fork does **not** need backward compatibility with existing IBC installs (the owner's decision), despite CONTRIBUTING.md's backward-compatibility rule. Config and script formats may change freely.
- Java code must stay cross-platform (Windows, Linux, macOS) and work for both TWS and Gateway.
- Never bypass IB's login security, such as 2FA or security-code entry.
- Match the existing code style.
- User-facing changes belong in `config.ini`, `ibc.ps1` and the user guide.
