# IBC User Guide

This guide is for this fork of IBC, which runs on **Windows** and is controlled with a single
PowerShell script, `ibc.ps1`. The original IBC ([IbcAlpha/IBC](https://github.com/IbcAlpha/IBC))
was retired in September 2026; its settings and scripts differ from this fork's, so use this
guide rather than upstream's.

To see which version of IBC you have, run `ibc.ps1 version`.

## 1. What IBC does

IBC runs Interactive Brokers' Trader Workstation (TWS) or IB Gateway without anyone at the
keyboard, so that unattended automated trading systems can use them. It starts TWS, then watches
for the windows and dialogs that would normally need a person and deals with them. For example:

- it fills in your username and password and logs in
- it selects live or paper trading
- it answers dialogs such as "Accept incoming connection?" and the paper-trading account warning
- it lets TWS restart every day **without logging in again**, so that you only need to log in
  (and approve the IBKR Mobile alert) once a week
- it can retry the login when you miss an IBKR Mobile alert
- it accepts commands such as STOP and RESTART from other programs or computers

IBC and TWS run in the same Java process: IBC starts first and then starts TWS from inside
itself. So if TWS exits, IBC exits too, and the other way round.

## 2. Quick start

1. Install the **offline** TWS (see *Requirements*), and run it once by hand to check that you
   can log in and that it's set to English.
2. Install PowerShell 7: `winget install Microsoft.PowerShell`.
3. Extract the IBC ZIP to `C:\IBC`.
4. Copy `C:\IBC\config.ini` to `%USERPROFILE%\Documents\IBC\config.ini` and set `IbLoginId` and
   `IbPassword` in it. For your paper-trading account, also set `TradingMode=paper`.
5. Start it: double-click the `IBC (TWS)` shortcut in `C:\IBC`, or run
   `C:\IBC\ibc.ps1 start`.
6. In TWS, open the Global Configuration, go to **Lock and Exit**, and select **Auto restart**
   with a time when you don't need TWS (see *Keeping TWS running all week*).

To run your live and paper accounts side by side, see *Several accounts*.

## 3. Requirements

**Windows with PowerShell 7.** `ibc.ps1` needs PowerShell 7 (`pwsh`), not the Windows PowerShell
5.1 built into Windows. Install it with `winget install Microsoft.PowerShell` (or from Microsoft's
website). The shortcuts and the sample scheduled task use it automatically.

**The offline TWS or IB Gateway.** IBKR offers two kinds of TWS: a self-updating one and an
offline (standalone) one that never changes after installation. **IBC only works with the
offline version.** It installs into a folder named after its version, for example `C:\Jts\1051`
for TWS 10.51. The TWS download contains the Gateway too, so you don't need a separate Gateway
download; IBKR's Gateway-only download installs into `C:\Jts\ibgateway\<version>` instead.

It's safest to use the *stable* offline version of TWS for live trading: the *latest* version is
more likely to have bugs.

**Java** comes with TWS: IBC uses the Java that TWS installed for itself, so you don't need to
install Java. (You can choose another one with the `JavaPath` setting, but there's rarely a
reason to.)

**English.** IBC recognises TWS's windows by their text, so TWS must run in English. IBC makes
sure of this whenever it starts TWS.

## 4. Installing IBC

Either:

- **From a release:** download the ZIP (`IBC-<version>-windows.zip`) from the
  [releases page](https://github.com/zdomokos/IBC/releases). Before extracting it, right-click it
  in File Explorer, choose Properties, tick **Unblock** and click OK; otherwise PowerShell may
  refuse to run `ibc.ps1`. Then extract everything into `C:\IBC`. (If you've already extracted
  it, run `Get-ChildItem C:\IBC -Recurse | Unblock-File` in PowerShell instead.)
- **From the source:** `scripts/deploy.ps1` in the repository builds IBC and installs it into a
  folder, and can also set up live and paper accounts for you (see *Several accounts*).

The installed folder contains:

| File | Purpose |
|------|---------|
| `ibc.ps1` | starts TWS/Gateway and sends commands to a running IBC |
| `config.ini` | sample configuration file, with every setting described |
| `IBC.jar` | the IBC program |
| `IBC (TWS).lnk`, `IBC (Gateway).lnk` | shortcuts that run `ibc.ps1 start` |
| `Start TWS (autorestart).xml` | sample Task Scheduler task |
| `README.txt`, `LICENSE.txt` | brief instructions, licence |

IBC adds a `Logs` folder when it runs.

The default locations, which `ibc.ps1` assumes unless you tell it otherwise:

| What | Where |
|------|-------|
| TWS/Gateway | `C:\Jts` |
| IBC | `C:\IBC` (any folder works: `ibc.ps1` finds its own files) |
| your configuration files | `%USERPROFILE%\Documents\IBC` |

## 5. How IBC finds TWS, its settings and your configuration

It helps to know that TWS keeps its **program** and its **settings** in separate places, and that
IBC chooses each of them separately.

```
C:\Jts\1050\    TWS 1050 program: jars, Java, tws.vmoptions  ┐ TwsMajorVersion chooses
C:\Jts\1051\    TWS 1051 program                             ┘ which one runs

C:\Jts\1051\    settings TWS 1051 uses when started by hand (jts.ini and a folder per user)
C:\Jts\paper\   settings of an IBC instance: TwsSettingsPath chooses where
```

**The program** is the version folder, `C:\Jts\<version>`. It holds the jar files, the Java TWS
came with, and `tws.vmoptions` (the Java heap size and similar options, which IBC also uses).
IBC runs the version in the `TwsMajorVersion` setting; if that's not set, it runs the newest
offline version installed. So after installing a new TWS version, IBC uses it automatically.

**The settings** are `jts.ini` (login options, language), `xmlopt.dat`, and one folder per IBKR
user (named with 40 letters) holding that user's layout (`tws.xml` and daily backups), rules,
chart settings, logs, and the `autorestart` file used for restarting without logging in. Recent
offline installers keep them in the version folder, so started by hand each TWS version has its
own copy. IBC tells TWS where its settings are with the `TwsSettingsPath` setting; if that's not
set, it uses the folder that already holds `jts.ini`, normally the version folder, so IBC uses
the same settings as starting TWS by hand.

Because the settings folder isn't tied to a version, an IBC instance with its own settings folder
(such as `C:\Jts\paper`) keeps its layout and logins when you change `TwsMajorVersion`. Moving to
a newer version is the normal direction: TWS updates older settings as needed. Going back to an
older version usually works between neighbouring versions, but an older TWS may not understand
settings a newer one added.

**Your configuration file** holds your credentials and IBC's settings. `ibc.ps1` looks for it in
`%USERPROFILE%\Documents\IBC`:

| You run | Configuration file |
|---------|--------------------|
| `ibc.ps1 start` | `config.ini` |
| `ibc.ps1 start paper` | `config-paper.ini` |
| `ibc.ps1 start -Config D:\x\my.ini` | the file given |

The name after `start` (here `paper`) is the **account name**. You can use any name; each needs
its own `config-<name>.ini`. IBC's window title and its log folder are named after it too.

## 6. The configuration file

### Keeping it secure

The configuration file contains your IBKR password, so keep it where other users of the computer
can't read it: your `Documents` folder is private to you, and `ibc.ps1` expects
`%USERPROFILE%\Documents\IBC`. For more protection, encrypt that folder, so that not even an
administrator can read it: right-click the folder, choose Properties, click Advanced on the
General tab, tick **Encrypt contents to secure data**, and click OK (this needs a Professional or
higher edition of Windows).

`ibc.ps1` only takes your credentials from the configuration file. It never puts them on a
command line, where other programs could see them.

### The settings you're most likely to need

`config.ini` describes every setting in detail. Most have sensible defaults. These are the ones
you're most likely to need:

| Setting | Notes |
|---------|-------|
| `IbLoginId`, `IbPassword` | your IBKR username and password. A live account and its paper-trading account have different usernames. |
| `TradingMode` | `live` (the default) or `paper` |
| `AcceptNonBrokerageAccountWarning` | When you log in to a paper-trading account, TWS warns that it isn't a brokerage account, and refuses API connections until you accept. `yes` accepts it automatically. |
| `AcceptIncomingConnectionAction` | What to do when an unknown computer connects to the API. `reject` is safest, with the trusted addresses set in TWS's API settings. |
| `ExistingSessionDetectedAction` | What to do when the same username is already logged in elsewhere. |
| `OverrideTwsApiPort` | The port API programs connect to. Instances running at the same time need different ports. |
| `CommandServerPort` | The port for commands such as `ibc.ps1 stop`. `0` (the default) turns commands off. |
| `AutoRestartTime`, `ColdRestartTime`, `ClosedownAt` | daily restart, Sunday cold restart, closedown: see *Keeping TWS running all week* |
| `ReloginAfterSecondFactorAuthenticationTimeout` | see *Second factor authentication* |

Write paths with doubled backslashes, for example `C:\\Jts\\paper`, because the file uses Java's
escaping rules. A backslash in a password must be doubled too.

`IbDir` is deprecated: use `TwsSettingsPath` instead, and leave `IbDir` empty. If the two differ,
auto-restart fails.

### Launcher settings

Section 0 of `config.ini` holds settings that only `ibc.ps1 start` uses (IBC itself ignores them).
They're all optional; leave them empty to use the defaults.

| Setting | Default | Notes |
|---------|---------|-------|
| `TwsMajorVersion` | the newest offline TWS/Gateway installed | eg `1050` for TWS 10.50 (see Help > About Trader Workstation) |
| `TwsPath` | `C:\Jts` | where TWS/Gateway is installed |
| `TwsSettingsPath` | the folder that already holds `jts.ini` | where TWS keeps its settings; created if it doesn't exist. Instances running at the same time need different ones. |
| `LogPath` | `<IBC folder>\Logs\<account>` | IBC's diagnostic log; `CON` shows it in IBC's window, `none` turns it off |
| `JavaPath` | the Java TWS came with | folder containing `java.exe` |
| `On2FATimeout` | `exit` | `restart` starts IBC again when it exits because the IBKR Mobile alert timed out |
| `MinimizeIbcWindow` | `no` | `yes` starts IBC's window minimised |

## 7. Starting and stopping

### Starting

```
C:\IBC\ibc.ps1 start                  # TWS, with config.ini
C:\IBC\ibc.ps1 start paper            # TWS, with config-paper.ini
C:\IBC\ibc.ps1 start live -Gateway    # IB Gateway, with config-live.ini
```

You can also double-click a shortcut in the IBC folder (`IBC (TWS)`, `IBC (TWS paper)` and so on;
double-clicking `ibc.ps1` itself opens it in an editor), copy the shortcuts to your desktop or
Start menu, or use a scheduled task (see *Scheduled tasks*). To start another account from a
shortcut, add its name after `start` in the shortcut's target.

`ibc.ps1 start` opens a new window, titled for example `IBC (TWS 1051 paper)`, which shows where
the log is. **Closing that window closes TWS.** The window closes by itself when TWS exits. If
something goes wrong, it turns red, shows the error, and waits for a key press.

With `-Inline`, IBC runs in the current window instead of opening a new one. That's needed for
Task Scheduler.

Run `ibc.ps1 help` for all commands and options.

### The log

Each run writes a diagnostic log to `C:\IBC\Logs\<account>\IBC-<IBC version>_TWS-<TWS
version>_<DAY>.txt`. There's one file per weekday, which is replaced a week later. It records the
settings used, the Java command, and what IBC did with each TWS window. It's the first place to
look when something goes wrong.

### Stopping

Exit TWS as usual (File > Exit), or, if `CommandServerPort` is set, run `ibc.ps1 stop` (with the
account name if you use one, eg `ibc.ps1 stop paper`).

### The renamed TWS program

When IBC starts TWS, it renames `C:\Jts\<version>\tws.exe` to `tws1.exe` (and `ibgateway.exe` to
`ibgateway1.exe`). This is needed for auto-restart: TWS's restart would otherwise start a new TWS
without IBC. As a result, the TWS desktop shortcut stops working. To run TWS without IBC, see
*Running TWS without IBC*.

## 8. Keeping TWS running all week

IBKR requires TWS to restart every day. In TWS's Global Configuration, under **Lock and Exit**,
there are two choices:

| Choice | What happens at the chosen time | For unattended use with IBC |
|--------|---------------------------------|-----------------------------|
| **Auto restart** | TWS shuts down and starts again by itself **without logging in**, because it reuses the existing session | **use this** |
| **Auto logoff** | TWS shuts down and stays down. Something else must start it again, with a full login (and IBKR Mobile alert for a live account). | not suitable |

Choose **Auto restart**, at a time when you don't need TWS, for example `11:45 PM`, outside your
trading hours.

Instead of setting it in TWS, you can set it in the configuration file, so that it's applied
every time IBC starts:

```
AutoRestartTime=11:45 PM
```

The time must be in exactly this format: `hh:mm AM` or `hh:mm PM`, with one space. Setting
`AutoRestartTime` also clears any auto-logoff time. This is the safer choice for an instance
whose settings folder was copied from elsewhere, since it might have inherited a different time.

**How the restart works with IBC.** At the restart time, TWS writes an `autorestart` file into the
user's folder in its settings folder and exits. `ibc.ps1` notices the file and starts TWS again,
telling it to resume the session without the login dialog. IBC's window stays open throughout.
You can see it in the log: `autorestart file found ... authentication will not be required`,
then `IBC will autorestart shortly`.

**The weekly login.** Auto-restart only lasts the week: IBKR requires a full shutdown and new
login once a week, after 01:00 US/Eastern on Sunday. IBC can do that for you:

```
ColdRestartTime=07:05
```

This is a 24-hour time in your local time zone; choose one that's after 01:00 US/Eastern all year
round. At that time on Sundays, IBC closes TWS and `ibc.ps1` starts it again with a full login.
For a live account, choose a time when you can approve the IBKR Mobile alert.

**Weekends.** To stop TWS after Friday's markets close rather than keep it running through
Saturday, use:

```
ClosedownAt=Friday 22:00
```

`ClosedownAt=22:00` (without a day) closes TWS every day.

**Live and paper.** Each instance restarts at its own time, in its own settings folder, so they
don't interfere. Giving them different times (eg `11:45 PM` and `11:50 PM`) keeps their logs
easier to read.

**If TWS stops for another reason** (a crash, File > Exit, a power cut), auto-restart doesn't
happen. A scheduled task that runs every few minutes can start it again (see *Scheduled tasks*).

## 9. Second factor authentication

With the IBKR Mobile app, each login sends an alert to your phone, and the login completes when
you approve it. IBC can't approve it for you, but since you don't need to be at the computer, it
works well with IBC. Thanks to auto-restart, you only need to approve one alert a week.

If you don't approve the alert in time (currently 3 minutes), TWS can't complete the login on
its own. With this setting, IBC starts the login again, as many times as needed:

```
ReloginAfterSecondFactorAuthenticationTimeout=yes
```

Sometimes the login doesn't complete even though you approved the alert. IBC can then close down
and start again, giving you another alert: `SecondFactorAuthenticationExitInterval` sets how many
seconds IBC waits after the approval, and `ExitAfterSecondFactorAuthenticationTimeout=yes` makes
it close down. For `ibc.ps1` to then start IBC again, set the launcher setting
`On2FATimeout=restart`. If something else already restarts IBC (such as a scheduled task that
repeats), leave it at `exit`, so that the two don't both start it.

## 10. Several accounts

You can run several TWS instances at the same time, for example your live and paper-trading
accounts, or accounts of different people, from one TWS installation and one IBC installation.
Each instance needs:

- its own configuration file, `config-<account>.ini`, with its own credentials;
- its own TWS settings folder (`TwsSettingsPath`): some files TWS writes while running aren't
  kept per user, and separate folders keep the auto-restart files apart;
- its own API port (`OverrideTwsApiPort`) and, if you use commands, command port
  (`CommandServerPort`).

Its log goes to its own folder automatically. Each IBKR username can only be logged in once at a
time.

### Live and paper with deploy.ps1

`scripts/deploy.ps1` (in the source repository) sets this up for a `live` and a `paper` account:

| | live | paper |
|---|---|---|
| Start with | `ibc.ps1 start live` | `ibc.ps1 start paper` |
| Shortcuts | `IBC (TWS live)` (and `IBC (Gateway live)` if IB Gateway is installed) | `IBC (TWS paper)` (and `IBC (Gateway paper)`) |
| Configuration file | `config-live.ini` | `config-paper.ini` |
| TWS settings folder | `C:\Jts\live` | `C:\Jts\paper` |
| Log folder | `C:\IBC\Logs\live` | `C:\IBC\Logs\paper` |
| API port / command port | 7496 / 7462 | 7497 / 7463 |

The configuration files are created only if they don't exist yet; fill in `IbLoginId` and
`IbPassword` in each. A new settings folder starts as a copy of your existing TWS settings
(`jts.ini`, `xmlopt.dat` and the user folders, without the logs), so both instances start with
your layouts. Existing configuration files and settings folders are left alone when you deploy
again.

### Setting it up by hand

1. Create a configuration file per account in `%USERPROFILE%\Documents\IBC`, eg
   `config-live.ini` and `config-paper.ini`, from `config.ini` (or start from the short files in
   the repository's `samples/MultipleUsers` folder).
2. In each, set the credentials, `TradingMode`, a different `TwsSettingsPath` (eg
   `C:\\Jts\\live` and `C:\\Jts\\paper`), a different `OverrideTwsApiPort` and, if you use
   commands, a different `CommandServerPort`. Leave `IbDir` empty.
3. To keep your current layouts, copy `jts.ini`, `xmlopt.dat` and the user folders from your
   current settings folder (eg `C:\Jts\1051`) into each new settings folder before the first
   start. Otherwise they start empty; you can also use TWS's `File > Save Settings As...` and
   `File > Settings Recovery...`.
4. Run `ibc.ps1 start live` and `ibc.ps1 start paper`.

### Different TWS versions per account

Each account can run its own TWS version: set `TwsMajorVersion` in its configuration file, for
example `TwsMajorVersion=1050` in `config-paper.ini` to try a version with your paper account
while live uses another. Install each version in the normal way; each goes into its own
`C:\Jts\<version>` folder.

## 11. Scheduled tasks

Task Scheduler can start IBC automatically. The task's action runs
`C:\Program Files\PowerShell\7\pwsh.exe` (or the `pwsh.exe` in
`%LOCALAPPDATA%\Microsoft\WindowsApps` for a Microsoft Store install) with arguments like these:

```
-NoProfile -ExecutionPolicy Bypass -File "C:\IBC\ibc.ps1" start paper -Inline
```

**Always use `-Inline` in a scheduled task.** Without it, `ibc.ps1` opens IBC in a new window and
exits at once, so Task Scheduler thinks the task has finished: it can't show it as running, can't
stop it after a time limit, and repeating the task would start IBC several times.

When you create the task:

- select **Run only when user is logged on**, so that you can see and use TWS. ("Run whether
  user is logged on or not" starts it in a separate, invisible session.) You'll need to be logged
  on to Windows when the task runs; Windows can be set to log on automatically at startup, but
  consider the security implications;
- change the settings so that Windows doesn't stop the task after a certain time.

With auto-restart set, the task keeps running all week, because `ibc.ps1` stays running through
the daily restarts. It ends when TWS is shut down without a restart: at the Sunday cold restart
it continues, but File > Exit, a STOP command, `ClosedownAt`, or a crash end it.

The sample task `Start TWS (autorestart).xml` in the IBC folder shows a useful pattern. Import it
into Task Scheduler, then enable it and set the user account it runs under (and add an account
name after `start` in its arguments if you use one):

- it starts TWS on Sunday at 22:15 (choose any convenient time);
- it repeats every 10 minutes, but only if it isn't already running, so that TWS is started again
  if it stops during the week;
- the repetition is limited to just under a day, and there are extra starts at the same time
  Monday to Thursday, so that it's covered until Friday evening;
- it can also be started by hand from the Task Scheduler console.

You can disable a task (right-click > Disable) without losing its definition.

## 12. Commands

IBC can accept commands from `ibc.ps1` or other programs, on this computer or another one. Set
`CommandServerPort` in the configuration file (eg `7462`) and restart IBC to turn this on.

```
C:\IBC\ibc.ps1 stop
C:\IBC\ibc.ps1 restart paper
C:\IBC\ibc.ps1 enableapi -Server 192.168.1.20 -Port 7462
```

`ibc.ps1` reads the port, and `BindAddress` if set, from the configuration file (the account name
selects which one); `-Port` and `-Server` override them. It shows IBC's reply, and its exit code
is 0 if IBC accepted the command, 1 if IBC rejected it, 2 if IBC couldn't be reached, and 3 if the
port couldn't be determined.

IBC only accepts commands from this computer and from the addresses in the `ControlFrom` setting.
`BindAddress` limits which of the computer's addresses it listens on.

The commands:

**stop**: shuts TWS down tidily, as if File > Exit had been used.

**restart**: restarts TWS without logging in again, as if the auto-restart time had arrived. For
TWS this happens at once (File > Restart). The Gateway has no restart command, so IBC sets its
auto-restart time to the next minute (shown with a countdown); that time stays set afterwards, so
use `AutoRestartTime` to put it back. A restart can't avoid the weekly login on Sunday.

**pause**: shuts TWS down like stop, but keeps the session, so that the next `ibc.ps1 start`
resumes it without logging in. For TWS this takes a few seconds; for the Gateway up to about 75
seconds. It's useful, for example, when a UPS reports that the power is about to fail. The kept
session expires at the weekly login.

**enableapi**: ticks "Enable ActiveX and Socket Clients" in TWS's API settings (TWS only; rarely
needed nowadays).

**reconnectdata**: makes TWS reconnect to IBKR's market data servers (like Ctrl+Alt+F).

**reconnectaccount**: makes TWS reconnect to IBKR's account server (like Ctrl+Alt+R).

Other programs can send commands too: open a TCP connection to the port, send the command as a
line of text (eg `STOP`), and read the reply, which starts with `OK` or `ERROR`. Send `EXIT` to
close the connection when finished (not needed after STOP).

## 13. Running TWS without IBC

Because IBC renames `tws.exe` to `tws1.exe` (see *Starting and stopping*), the TWS desktop
shortcut stops working. To run TWS by hand:

- double-click `C:\Jts\<version>\tws1.exe`, or point the desktop shortcut at it; or
- rename it back to `tws.exe` (not while IBC is running: an auto-restart would then start TWS
  without IBC).

Remember that started by hand, TWS uses the settings in its version folder, not an IBC instance's
own settings folder such as `C:\Jts\paper`, so changes made in one don't appear in the other.

## 14. Troubleshooting

Look in the log first (`C:\IBC\Logs\<account>\...`). IBC's window shows its location, and when
something fails it shows the error and an exit code.

| Exit code / message | Meaning |
|---------------------|---------|
| 1001 Can't find suitable Java | the Java that came with TWS wasn't found; check the TWS installation or set `JavaPath` |
| 1002 No offline TWS/Gateway installation found | install the offline TWS, or set `TwsPath`/`TwsMajorVersion` |
| 1003 | a launcher setting has an invalid value (eg `On2FATimeout`) |
| 1004 ... is not installed: can't find jars folder | `TwsMajorVersion` names a version that isn't installed, or it's the self-updating TWS |
| 1006 IBC configuration file ... does not exist | create `config.ini` (or `config-<account>.ini`) in `%USERPROFILE%\Documents\IBC`, or check the account name |
| 1007 | the TWS installation has no `tws.vmoptions`/`ibgateway.vmoptions` |
| 1008 | the TWS settings folder doesn't exist and couldn't be created |
| 1009 The log file ... could not be opened | another instance uses the same log folder; give each its own |
| 1100 | an unexpected error inside IBC; see the log |
| 1107 | IBC.jar couldn't find TWS's classes: the TWS installation is incomplete |
| 1111 | the IBKR Mobile alert wasn't approved in time and IBC was set to exit (see *Second factor authentication*) |
| 1112 | the TWS login dialog didn't appear in time; IBC starts again |

Other common problems:

- **PowerShell refuses to run `ibc.ps1`** ("not digitally signed" or "cannot be loaded"): the
  files are still marked as downloaded; run `Get-ChildItem C:\IBC -Recurse | Unblock-File`.
  Use the shortcuts, which bypass this, or run `ibc.ps1` from PowerShell 7 (`pwsh`), not Windows
  PowerShell 5.1.
- **IBC doesn't recognise a dialog**: TWS must be in English. The log shows the windows IBC saw;
  `LogStructureScope` and `LogStructureWhen` in `config.ini` make it record their contents in
  detail.
- **The login fails with "existing session"**: the same username is logged in elsewhere (eg TWS
  started by hand); see `ExistingSessionDetectedAction`.
- **TWS starts without IBC after a restart**: `tws.exe` was renamed back while IBC was running.

For help, or to report a bug, open an issue on
[github.com/zdomokos/IBC](https://github.com/zdomokos/IBC/issues), with the IBC and TWS versions
and the log file.
