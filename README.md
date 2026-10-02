# IBC

IBC automates the parts of running Interactive Brokers' Trader Workstation (TWS) and IB Gateway
that would otherwise need someone at the keyboard. It fills in the login dialog, handles the
dialogs TWS pops up, restarts TWS daily without re-authenticating, and accepts commands such as
STOP and RESTART over a TCP port. It runs on Windows, Linux and macOS.

This repository is a fork of [IbcAlpha/IBC](https://github.com/IbcAlpha/IBC), which was retired
on 1 September 2026 and is now archived. Compared with upstream, this fork:

- builds with Gradle instead of Ant, and
- uses PowerShell 7 scripts on Windows instead of `.bat` and VBScript files.

It does not keep backward compatibility with existing IBC installations: config and script
formats may change. The upstream README is kept in
[docs/upstream-README.md](docs/upstream-README.md).

IBC only works with the **offline** (standalone) TWS installer, not the self-updating TWS.

## Repository layout

| Path | Contents |
|------|----------|
| `src/ibcalpha/ibc/` | the Java source (single package) |
| `resources/` | everything that goes into the distribution ZIPs: `config.ini`, start and command scripts, `IBC.jar`, `version` |
| `resources/scripts/` | launcher internals called by the start scripts |
| `docs/` | user guide and design notes (see [Documentation](#documentation)) |
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

Then, from the repository root (`./gradlew` on Linux and macOS):

| Command | Result |
|---------|--------|
| `gradlew jar` | compiles and writes `build/libs/IBC.jar` |
| `gradlew` | the default `dist` task: also copies the jar to `resources/IBC.jar`, writes `resources/version`, and builds `build/dist/IBCWin-<version>.zip`, `IBCLinux-<version>.zip` and `IBCMacos-<version>.zip` |
| `gradlew clean` | deletes `build/` |

Notes:

- The version number is set only in [gradle.properties](gradle.properties). It is compiled into
  IBC and used for the ZIP names and `resources/version`.
- `resources/IBC.jar` is a committed file. `gradlew` (dist) overwrites it, so expect it to show
  as modified afterwards.
- There are no automated tests. Check changes by running IBC against a real TWS and Gateway.

To rebuild the user guide PDF (`docs/userguide.pdf`) you also need pandoc and xelatex (for
example MiKTeX): run `docs/makedocs/makeUserGuide.ps1`.

## Releasing

There is no release automation. A release is a set of three ZIP files attached to a GitHub
release:

1. **Set the version** in [gradle.properties](gradle.properties).
2. **Update the documentation** if behaviour or settings changed:
   [docs/userguide.md](docs/userguide.md) and the comments in
   [resources/config.ini](resources/config.ini). Rebuild the PDF with
   `docs/makedocs/makeUserGuide.ps1`.
3. **Build:** `gradlew clean dist`.
4. **Test the ZIPs** from `build/dist/` on a clean install of each platform you're releasing for,
   with both TWS and Gateway: log in, auto-restart, and the STOP/RESTART commands.
5. **Commit** `gradle.properties`, `resources/IBC.jar` and `resources/version` (plus any doc
   changes), then tag the commit with the version number:

   ```
   git tag <version>
   git push origin master <version>
   ```

6. **Publish:** create a GitHub release from the tag and attach the three ZIPs from
   `build/dist/`, either in the GitHub web UI or with the GitHub CLI:

   ```
   gh release create <version> build/dist/*.zip --title "IBC <version>" --notes "<release notes>"
   ```

## Installing and running

See the [user guide](docs/userguide.md) ([PDF](docs/userguide.pdf)). In short: extract the ZIP
for your platform (on Windows, to `C:\IBC`), copy `config.ini` to a private folder and fill in
your credentials, set the TWS major version in the start script, and run it:

- **Windows:** `StartTWS.ps1` or `StartGateway.ps1`, or the `IBC (TWS)` / `IBC (Gateway)`
  shortcuts. These need [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
  (`winget install Microsoft.PowerShell`).
- **Linux:** `twsstart.sh` or `gatewaystart.sh`.
- **macOS:** `twsstartmacos.sh` or `gatewaystartmacos.sh`.

## Documentation

| Document | What it covers |
|----------|----------------|
| [docs/userguide.md](docs/userguide.md) | installing, configuring and running IBC; all settings; the command server |
| [resources/config.ini](resources/config.ini) | every configuration setting, with comments |
| [docs/reference/how-ibc-works.md](docs/reference/how-ibc-works.md) | how IBC drives TWS from inside the same JVM: window handlers, threading, key flows |
| [docs/reference/tws-jvm-parameters.md](docs/reference/tws-jvm-parameters.md) | how IBC reproduces the JVM settings that `tws.exe` uses, and how to check them |
| [docs/spec/code-review-findings.md](docs/spec/code-review-findings.md) | known bugs in the Java code, with a suggested fix order |
| [CONTRIBUTING.md](CONTRIBUTING.md) | contribution guidelines and build details |
| [CLAUDE.md](CLAUDE.md) | condensed build and architecture notes for AI coding assistants |
| [docs/upstream-README.md](docs/upstream-README.md) | the original upstream README, kept for history |
| [samples/IbcLoader/README.md](samples/IbcLoader/README.md) | running IBC inside your own Java application |

## License

IBC is licensed under the [GNU General Public License version 3](LICENSE.txt).

IBC is a fork of the [IBController](https://github.com/ib-controller/ib-controller) project.
Thanks to its contributors, and to Richard L King, who maintained IBController and then created
and maintained IBC.
