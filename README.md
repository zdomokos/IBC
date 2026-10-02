# IBC

IBC automates the parts of running Interactive Brokers' Trader Workstation (TWS) and IB Gateway
that would otherwise need someone at the keyboard. It fills in the login dialog, handles the
dialogs TWS pops up, restarts TWS daily without re-authenticating, and accepts commands such as
STOP and RESTART over a TCP port.

This repository is a fork of [IbcAlpha/IBC](https://github.com/IbcAlpha/IBC), which was retired
on 1 September 2026 and is now archived. Compared with upstream, this fork:

- builds with Gradle instead of Ant,
- is run on Windows with a single PowerShell 7 script, `ibc.ps1`, instead of `.bat` and VBScript
  files, and
- currently supports Windows only. The Linux and macOS scripts were removed; they can be added
  back when needed (the Java code itself is still cross-platform).

It does not keep backward compatibility with existing IBC installations: config and script
formats may change. The upstream README is kept in
[docs/upstream-README.md](docs/upstream-README.md).

IBC only works with the **offline** (standalone) TWS installer, not the self-updating TWS.

## Repository layout

| Path | Contents |
|------|----------|
| `src/main/java/` | the Java source (package `ibcalpha.ibc`) |
| `src/main/dist/` | the other files in the distribution ZIP: `ibc.ps1`, `config.ini`, `README.txt`, shortcuts, sample scheduled task |
| `scripts/` | developer tools: `deploy.ps1` |
| `docs/` | user guide and design notes (see [Documentation](#documentation)) |
| `samples/MultipleUsers/` | config files for running TWS for several users at once |
| `samples/IbcLoader/` | example of running IBC and TWS inside your own Java application |

## Building

You need:

- **A JDK, version 17 or later.** Gradle is downloaded automatically by the included wrapper.
- **The TWS jar files.** IBC compiles against TWS's own classes, so point the build at the
  `jars` folder of any installed TWS or Gateway version (package and class names don't change
  between versions). Either set the `IBC_BIN` environment variable or pass `-PibcBin=<folder>`.

```powershell
[Environment]::SetEnvironmentVariable("IBC_BIN", "C:\Jts\1051\jars", "User")
```

Then, from the repository root:

| Command | Result |
|---------|--------|
| `gradlew jar` | compiles and writes `build/libs/IBC.jar` |
| `gradlew` | the default `dist` task: also builds the distribution, `build/dist/IBC-<version>-windows.zip` |
| `gradlew clean` | deletes `build/` |

Notes:

- The version number is set only in [gradle.properties](gradle.properties). It is compiled into
  IBC, stamped into `ibc.ps1` (`ibc.ps1 version`), and used in the ZIP's name.
- Build output only goes to `build/`; nothing the build produces is committed.
- There are no automated tests. Check changes by running IBC against a real TWS and Gateway.

### Deploying to a local folder

`scripts/deploy.ps1` builds the distribution and installs it into a folder, for example to try a
change on this machine:

```powershell
./scripts/deploy.ps1 C:\IBC                                  # uses IBC_BIN for the build
./scripts/deploy.ps1 D:\Trading\IBC -IbcBin C:\Jts\1051\jars
./scripts/deploy.ps1 C:\IBC -SkipBuild                       # deploy the existing build/dist ZIP
```

It also sets up a **live** and a **paper** account as separate instances that can run at the
same time (`-NoAccounts` skips this):

| | live | paper |
|---|---|---|
| Start with | `ibc.ps1 start live` (add `-Gateway` for IB Gateway) | `ibc.ps1 start paper` |
| Shortcuts | `IBC (TWS live)`, and `IBC (Gateway live)` if IB Gateway is installed | `IBC (TWS paper)`, `IBC (Gateway paper)` |
| Config file | `%USERPROFILE%\Documents\IBC\config-live.ini` | `...\config-paper.ini` |
| TWS settings folder | `C:\Jts\live` | `C:\Jts\paper` |
| Log folder | `<folder>\Logs\live` | `<folder>\Logs\paper` |
| API port / command port | 7496 / 7462 | 7497 / 7463 |

The two config files are created only if they don't exist: fill in `IbLoginId` and `IbPassword`
in each. Otherwise they're never changed, except that one made by an earlier version of the
script gets the `TwsSettingsPath` line it lacks. The `live` and `paper` settings folders start as
copies of your existing TWS settings, without the logs, so both keep your layouts; existing
folders are never touched.

It only creates the shortcuts that work on the computer: the plain `IBC (TWS)` and
`IBC (Gateway)` only if `%USERPROFILE%\Documents\IBC\config.ini` exists, and Gateway shortcuts
only if IB Gateway is installed.

On an existing installation it keeps the `config.ini` template (add `-OverwriteSettings` to
replace it; the old copy is saved as `.bak`), and lists, but doesn't delete, files that aren't
part of the new version, such as the start scripts of earlier versions. Stop IBC before deploying
over a running installation. Run `Get-Help ./scripts/deploy.ps1 -Full` for details.

To rebuild the user guide PDF (`docs/userguide.pdf`) you also need pandoc and xelatex (for
example MiKTeX): run `docs/makedocs/makeUserGuide.ps1`.

## Releasing

There is no release automation. A release is the distribution ZIP attached to a GitHub release:

1. **Set the version** in [gradle.properties](gradle.properties).
2. **Update the documentation** if behaviour or settings changed:
   [docs/userguide.md](docs/userguide.md) and the comments in
   [src/main/dist/config.ini](src/main/dist/config.ini). Rebuild the PDF with
   `docs/makedocs/makeUserGuide.ps1`.
3. **Build:** `gradlew clean dist`.
4. **Test the ZIP** from `build/dist/` on a clean install, with both TWS and Gateway: log in,
   auto-restart, and the stop/restart commands.
5. **Commit** `gradle.properties` (plus any doc changes), then tag the commit with the version
   number:

   ```
   git tag <version>
   git push origin master <version>
   ```

6. **Publish:** create a GitHub release from the tag and attach the ZIP from `build/dist/`,
   either in the GitHub web UI or with the GitHub CLI:

   ```
   gh release create <version> build/dist/*.zip --title "IBC <version>" --notes "<release notes>"
   ```

## Installing and running

See the [user guide](docs/userguide.md) ([PDF](docs/userguide.pdf)). In short: extract the ZIP to
`C:\IBC`, install [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
(`winget install Microsoft.PowerShell`), copy `config.ini` to `%USERPROFILE%\Documents\IBC` and
fill in your credentials (for a named account, name it `config-<account>.ini`), and use `ibc.ps1`:

```powershell
.\ibc.ps1 start               # TWS, with config.ini
.\ibc.ps1 start paper         # TWS, with config-paper.ini
.\ibc.ps1 start live -Gateway # IB Gateway, with config-live.ini
.\ibc.ps1 stop paper          # also restart, pause, enableapi, reconnectdata, reconnectaccount
.\ibc.ps1 version
.\ibc.ps1 help
```

The `IBC (TWS)` and `IBC (Gateway)` shortcuts run `ibc.ps1 start`. It finds the newest TWS
installed in `C:\Jts` and its existing settings by itself; the optional launcher settings at the
top of `config.ini` (`TwsMajorVersion`, `TwsSettingsPath`, `LogPath`, ...) override that.
Commands need `CommandServerPort` set in the config file.

### Running several TWS instances for different users

Several TWS instances can run at the same time, one per IBKR user, from the same TWS and IBC
installations. Each instance just needs its own config file, `config-<user>.ini`, with its own
`TwsSettingsPath`, API port and command port; it's then started with `ibc.ps1 start <user>`, and
logs to its own folder automatically. [samples/MultipleUsers](samples/MultipleUsers/README.md)
has ready-made files for two users, `alice` and `bob`, and explains each setting. Each IBKR
username can only be logged in once at a time. For a live and a paper account,
`scripts/deploy.ps1` sets this up for you (see above).

## Documentation

| Document | What it covers |
|----------|----------------|
| [docs/userguide.md](docs/userguide.md) | installing, configuring and running IBC; all settings; the command server |
| [src/main/dist/config.ini](src/main/dist/config.ini) | every configuration setting, with comments |
| [docs/reference/how-ibc-works.md](docs/reference/how-ibc-works.md) | how IBC drives TWS from inside the same JVM: window handlers, threading, key flows |
| [docs/reference/tws-jvm-parameters.md](docs/reference/tws-jvm-parameters.md) | how IBC reproduces the JVM settings that `tws.exe` uses, and how to check them |
| [docs/spec/code-review-findings.md](docs/spec/code-review-findings.md) | known bugs in the Java code, with a suggested fix order |
| [CONTRIBUTING.md](CONTRIBUTING.md) | contribution guidelines and build details |
| [CLAUDE.md](CLAUDE.md) | condensed build and architecture notes for AI coding assistants |
| [docs/upstream-README.md](docs/upstream-README.md) | the original upstream README, kept for history |
| [samples/MultipleUsers/README.md](samples/MultipleUsers/README.md) | running several TWS instances for different users at the same time |
| [samples/IbcLoader/README.md](samples/IbcLoader/README.md) | running IBC inside your own Java application |

## License

IBC is licensed under the [GNU General Public License version 3](LICENSE.txt).

IBC is a fork of the [IBController](https://github.com/ib-controller/ib-controller) project.
Thanks to its contributors, and to Richard L King, who maintained IBController and then created
and maintained IBC.
