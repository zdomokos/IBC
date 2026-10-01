# Matching the JVM Parameters of `tws.exe`

- **Date:** 2026-09-30
- **Install examined:** `C:\Jts\1045\tws.exe`, TWS 10.45 stable **standalone** (offline) build,
  Zulu JRE 17.0.16
- **IBC version:** 3.24.2 (`resources/scripts/StartIBC.bat`)
- **Related:** [How IBC works](how-ibc-works.md)

## Summary

`C:\Jts\1045` is the standalone TWS layout that IBC expects. With these two values in
`resources/StartTWS.bat` (both are already the defaults), IBC rebuilds the same JVM setup that
`tws.exe` uses. `StartTWS.bat` passes them on to `scripts\StartIBC.bat`, which does the work.

```bat
set TWS_MAJOR_VRSN=1045
set TWS_PATH=%SYSTEMDRIVE%\Jts
```

To change heap or GC settings, edit `C:\Jts\1045\tws.vmoptions`. Both `tws.exe` and IBC read it on
the next start.

> `C:\Jts\tws.exe` (with `C:\Jts\jars`) is a separate **auto-updating** install. IBC does not
> support it; it refuses with "IBC does not work with the auto-updating TWS/Gateway".

## Where `tws.exe` gets its JVM settings

`tws.exe` is an install4j launcher. It builds the JVM from four sources.

| # | Source | Contents on this machine | How IBC reproduces it |
|---|--------|--------------------------|-----------------------|
| 1 | `C:\Jts\1045\tws.vmoptions` | `-Xmx2048m`; `-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:ParallelGCThreads=20 -XX:ConcGCThreads=5 -XX:InitiatingHeapOccupancyPercent=70`; `-Dinstaller.uuid=…`, `-DvmOptionsPath=C:\Jts\1045\tws.vmoptions`, `-Dsun.awt.nopixfmt=true`, `-Dsun.java2d.noddraw=true`, `-Dswing.boldMetal=false`, `-Dsun.locale.formatasdefault=true`, `-Dsun.java2d.uiScale.enabled=true`, `-Dsun.java2d.uiScale=1.0` | `StartIBC.bat:357-362` reads the file line by line and skips `#` comments |
| 2 | `C:\Jts\1045\.install4j\i4jparams.conf`, `<variable name="javaOptions">` | module-access flags (`--add-opens=java.base/java.util=ALL-UNNAMED`, `--add-exports=java.desktop/sun.awt.windows=ALL-UNNAMED`, the JavaFX/jxbrowser flags, …) and `-DjxBrowserKey=…` | `getExtraJavaOptions.ps1` extracts the attribute value; `StartIBC.bat:390` puts it in `EXTRA_JAVA_OPTIONS` |
| 3 | `C:\Jts\1045\.install4j\pref_jre.cfg` (then `inst_jre.cfg`) | `%LOCALAPPDATA%\Programs\Common\i4j_jres\Oda-jK0QgTEmVssfllLP\17.0.16.0.101-zulu_64` | `StartIBC.bat:403-417`: `pref_jre.cfg` → `inst_jre.cfg` → `..\jre`; overridable with `/JavaPath` |
| 4 | Built into `tws.exe` itself | main class, classpath, a few `-D` properties. Not stored in any file | classpath = `C:\Jts\1045\jars\*.jar` + `.install4j\i4jruntime.jar` + `IBC.jar` (`StartIBC.bat:343-348`); known `-D` values hardcoded at `StartIBC.bat:364-368` |

The final IBC command line (`StartIBC.bat:484`) is:

```
"<JRE>\bin\java.exe" <EXTRA_JAVA_OPTIONS> -cp "<IBC_CLASSPATH>" <JAVA_VM_OPTIONS> <AUTORESTART_OPTION> ibcalpha.ibc.IbcTws "<config.ini>" [credentials] <mode>
```

## Where IBC's launch differs from `tws.exe`

| Difference | Details | Intended? |
|------------|---------|-----------|
| Main class | `ibcalpha.ibc.IbcTws` / `IbcGateway`, which then calls TWS's own `main` | Yes, this is how IBC works |
| Extra properties | `-DjtsConfigDir="<TWS_SETTINGS_PATH>"`, `-Dibcsessionid=<random>`, autorestart option (`-Drestart=…`) | Yes |
| `-Dchannel=latest` | Hardcoded at `StartIBC.bat:365`. The standalone 1045 `tws.vmoptions` sets no channel, so this may not match what `tws.exe` uses internally. Probably only affects update checks | **Check** with the procedure below |
| `-Dtwslaunch.autoupdate.serviceImpl=…`, `-Dexe4j.isInstall4j=true`, `-Dinstall4jType=standalone` | Hardcoded copies of settings built into the exe | Should match; **check** |
| Lines with spaces in `tws.vmoptions` | The parser uses `tokens=1 delims= `, so a line is cut at the first space (e.g. `-Dx=C:\Program Files\y` becomes `-Dx=C:\Program`). The current file has no such lines | Limitation |

## Checking against the running `tws.exe`

Settings built into the exe (source 4) can't be read from a file. The install4j launcher loads the
JVM **inside** `tws.exe`, so the process command line doesn't show the JVM args either. Ask the
running JVM with `jcmd`.

The bundled Zulu JRE has no `jcmd`. Use the local JDK 25 one, which can normally attach to a
Java 17 process. `jcmd` must run as the same Windows user as TWS.

1. Start TWS the normal way with `C:\Jts\1045\tws.exe`. Stay on the login screen.
2. Capture its settings:

   ```powershell
   $jcmd = 'C:\Program Files\Eclipse Adoptium\jdk-25.0.4.101-hotspot\bin\jcmd.exe'
   & $jcmd -l                                             # find the tws.exe PID
   & $jcmd <pid> VM.command_line    > tws-cmdline.txt     # JVM args, main class, classpath
   & $jcmd <pid> VM.system_properties > tws-props.txt
   & $jcmd <pid> VM.flags           > tws-flags.txt
   ```

3. Close TWS, start it through IBC (`StartTWS.bat`), and capture the same three outputs from the
   `java.exe` process (`ibc-*.txt`).
4. Compare them:

   ```powershell
   Compare-Object (Get-Content tws-props.txt)   (Get-Content ibc-props.txt)
   Compare-Object (Get-Content tws-flags.txt)   (Get-Content ibc-flags.txt)
   ```

   IBC's log also prints what it used, on the `Java VM Options=` and `EXTRA_JAVA_OPTIONS =` lines.

Focus on:

- `java_command` / main class and `java_class_path` in `VM.command_line`
- `channel`, `install4jType`, `exe4j.*`, `twslaunch.*`, `jtsConfigDir` in `VM.system_properties`
- heap and GC flags in `VM.flags`

Expected differences: the IBC main class, `IBC.jar` on the classpath, `jtsConfigDir`,
`ibcsessionid`, `restart`. Any other difference should be copied into `StartIBC.bat`
(section "Generate the JAVA VM options") or `tws.vmoptions`.

## After a TWS upgrade

Each standalone version installs into its own folder (`C:\Jts\<version>`) with its own
`tws.vmoptions`, `.install4j\i4jparams.conf` and `jars`. After upgrading:

1. Change `TWS_MAJOR_VRSN` in `StartTWS.bat` (and `StartGateway.bat` if used).
2. Copy any custom lines from the old `tws.vmoptions`. Lines below `### keep on update` survive
   in-place updates, not new version folders.
3. Repeat the `jcmd` comparison if IBKR changed the launcher (new `-D` properties built into
   `tws.exe` won't be picked up automatically).
