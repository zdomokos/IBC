# Running several TWS instances for different users

This sample runs two TWS instances at the same time, for the IBKR users `alice` and `bob`. Both
use the same TWS installation and the same IBC installation. Each user just needs a
configuration file, `config-<user>.ini`, and is started with `ibc.ps1 start <user>`.

For the common case of a live and a paper-trading account, you don't need this sample:
`deploy.ps1` creates the equivalent files for `live` and `paper` (see the main README).

## What each instance needs of its own

| | alice | bob | Why |
|---|---|---|---|
| Config file | `config-alice.ini` | `config-bob.ini` | each holds its user's credentials and ports |
| TWS settings folder (`TwsSettingsPath`) | `C:\Jts\alice` | `C:\Jts\bob` | some files TWS writes while running aren't separated by username, and separate folders also keep the auto-restart files apart |
| API port (`OverrideTwsApiPort`) | `7501` | `7502` | each TWS needs its own port for API programs |
| Command port (`CommandServerPort`) | `7471` | `7472` | each instance needs its own port for stop, restart, etc. |
| Log folder | `C:\IBC\Logs\alice` | `C:\IBC\Logs\bob` | automatic: named after the account |

`IbDir` is left empty in both config files: if it differed from `TwsSettingsPath`, auto-restart
would fail.

## Setting it up

1. Install IBC in `C:\IBC` and TWS in `C:\Jts` as usual.
2. Copy `config-alice.ini` and `config-bob.ini` into `%USERPROFILE%\Documents\IBC` (ideally an
   encrypted folder) and fill in `IbLoginId` and `IbPassword`. Add any other settings you need
   from the full `config.ini`; anything not listed takes its default.
3. Start each instance:

   ```powershell
   C:\IBC\ibc.ps1 start alice
   C:\IBC\ibc.ps1 start bob
   ```

   The settings folders are created on first run, empty. To start them with your existing TWS
   layouts, copy `jts.ini` and the per-user folders from `C:\Jts\<version>` into them first, or
   use TWS's `File > Save Settings As...` and `File > Settings Recovery...`.

To send a command to one instance, give its name; `ibc.ps1` reads the port from its config file:

```powershell
C:\IBC\ibc.ps1 stop alice
C:\IBC\ibc.ps1 restart bob
```

For more users, copy one user's config file, replace the name throughout, and pick ports no
other instance uses.

## Things to know

- Each IBKR username can only be logged in once at a time. A live account and its paper-trading
  account have different usernames, so running both at once works.
- For Task Scheduler, create one task per user, running
  `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "C:\IBC\ibc.ps1" start alice -Inline`.
- For a shortcut, copy `IBC (TWS).lnk` and add the user's name after `start` in its target.
- Each instance is a separate Java process, so memory use adds up.
