#Requires -Version 7

<#
.SYNOPSIS
Starts TWS or IB Gateway under IBC, and sends commands to a running IBC.

.DESCRIPTION
Usage: ibc.ps1 <command> [<account>] [options]

Commands:

  start             Start TWS (or IB Gateway with -Gateway) under IBC
  stop              Shut down TWS/Gateway tidily, as if File > Exit were used
  restart           Restart TWS/Gateway without needing to log in again
  pause             Shut down so that the next start continues the session
                    without logging in again
  enableapi         Enable the TWS API (TWS only)
  reconnectdata     Reconnect to IB's market data servers
  reconnectaccount  Reconnect to IB's account server
  version           Show the IBC version (also --version)
  help              Show this help (also --help, -h)

Accounts: <account> selects the configuration file
<ConfigFolder>\config-<account>.ini, eg 'ibc.ps1 start paper' uses
config-paper.ini. Without it, config.ini is used. -Config names a file
directly. ConfigFolder defaults to %USERPROFILE%\Documents\IBC.

Options:

  -Gateway          (start) start IB Gateway instead of TWS
  -Inline           (start) run in this window instead of opening a new
                    one; required when running from Task Scheduler
  -Config <file>    the IBC configuration file to use
  -ConfigFolder <folder>
                    where to look for config.ini and config-<account>.ini
  -Port <n>         (commands) the command server port. Default: the
                    CommandServerPort setting in the configuration file
  -Server <address> (commands) the computer running IBC. Default: the
                    BindAddress setting if set, otherwise this computer

Examples:

  .\ibc.ps1 start paper
  .\ibc.ps1 start live -Gateway
  .\ibc.ps1 stop paper
  .\ibc.ps1 restart -Server 192.168.1.20 -Port 7462

How start is configured: besides IBC's own settings, the configuration file
can hold these launcher settings, which IBC itself ignores. Each is optional:

  TwsMajorVersion   eg 1051. Default: the newest offline TWS/Gateway
                    installed in TwsPath
  TwsPath           where TWS/Gateway is installed. Default: C:\Jts
  TwsSettingsPath   where TWS keeps its settings. Default: the folder that
                    already holds them (jts.ini), eg C:\Jts\1051. Instances
                    running at the same time need different folders
  LogPath           folder for IBC's diagnostic log, or CON for this window,
                    or none. Default: the Logs folder next to this script,
                    plus a subfolder named after the account
  JavaPath          folder containing the java.exe to use. Default: the Java
                    that came with TWS
  On2FATimeout      restart or exit (default): what to do when IBC exits
                    because second factor authentication timed out
  MinimizeIbcWindow yes to minimise IBC's own window. Default: no

Write paths with doubled backslashes, as elsewhere in the file, eg
TwsSettingsPath=C:\\Jts\\paper. Credentials come only from the IbLoginId and
IbPassword settings.

Exit codes for commands other than start: 0 IBC accepted the command; 1 IBC
rejected it; 2 IBC couldn't be reached or didn't reply; 3 the port couldn't be
determined. For start, the exit code is 0 or the error code of IBC or this
script.

.PARAMETER Command
start, stop, restart, pause, enableapi, reconnectdata, reconnectaccount,
version or help. Not case-sensitive.

.PARAMETER Account
Selects <ConfigFolder>\config-<Account>.ini as the configuration file.

.PARAMETER Config
The IBC configuration file to use. Overrides Account.

.PARAMETER ConfigFolder
Where config.ini and the config-<account>.ini files are. Default:
%USERPROFILE%\Documents\IBC.

.PARAMETER Gateway
start: start IB Gateway instead of TWS.

.PARAMETER Inline
start: run in this window instead of opening a new one. Required when running
from Task Scheduler.

.PARAMETER InWindow
Used internally when start re-runs itself in a new window.

.PARAMETER Port
Commands: the command server port. Overrides CommandServerPort.

.PARAMETER Server
Commands: the name or IP address of the computer running IBC.

.PARAMETER Help
Show this help, like the help command.

.PARAMETER Version
Show the IBC version, like the version command.

.PARAMETER TimeoutSeconds
Commands: how long to wait for IBC's reply. Default 30.

.EXAMPLE
.\ibc.ps1 start paper

.EXAMPLE
.\ibc.ps1 stop paper
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'pause', 'enableapi', 'reconnectdata', 'reconnectaccount',
                 'version', '--version', 'help', '--help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [ValidatePattern('^[\w.-]+$')]
    [string]$Account,

    [string]$Config,

    [string]$ConfigFolder = "$env:USERPROFILE\Documents\IBC",

    [switch]$Gateway,

    [switch]$Inline,

    [switch]$InWindow,

    [ValidateRange(1, 65535)]
    [int]$Port,

    [string]$Server,

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 30,

    [switch]$Version,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# set by the build; a copy of this script taken straight from the source has none
$ibcVersion = '@IBC_VERSION@'
if ($ibcVersion.StartsWith('@')) { $ibcVersion = 'development' }

if ($Version -or $Command -in 'version', '--version') {
    "IBC $ibcVersion"
    exit 0
}

if ($Help -or $Command -in 'help', '--help') {
    (Get-Help $PSCommandPath).Description.Text
    exit 0
}

#======================== Configuration file ===================================

if (-not $Config) {
    $Config = Join-Path $ConfigFolder ($Account ? "config-$Account.ini" : 'config.ini')
}
# the account name, used for the log folder and window title. An instance started
# with -Config config-<name>.ini is named after <name>; with config.ini it has none.
# (A separate variable, because $Account keeps its parameter validation.)
$accountName = $Account ? $Account :
    ([System.IO.Path]::GetFileNameWithoutExtension($Config) -replace '^config-?', '')

# The configuration file in Java properties format, enough for the settings read here:
# 'key=value' lines, '#' or '!' comments, and doubled backslashes
function Read-ConfigFile([string]$Path) {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([^#!=\s][^=]*?)\s*=\s*(.*?)\s*$') {
            $values[$Matches[1]] = $Matches[2].Replace('\\', '\')
        }
    }
    $values
}

$settings = (Test-Path -LiteralPath $Config -PathType Leaf) ? (Read-ConfigFile $Config) : $null

function Write-Failure([string]$Message) {
    [Console]::Error.WriteLine("ibc: $Message")
}

#======================== Commands other than start ============================

if ($Command -ne 'start') {
    $E_REJECTED = 1
    $E_NO_REPLY = 2
    $E_NO_PORT = 3

    if (-not $PSBoundParameters.ContainsKey('Port')) {
        if (-not $settings) {
            Write-Failure "can't read the command server port: $Config doesn't exist. Use -Config, an account name, or -Port."
            exit $E_NO_PORT
        }
        $configured = $settings['CommandServerPort']
        if (-not $configured -or $configured -eq '0') {
            Write-Failure "the command server is disabled in $Config (CommandServerPort is not set). Set it there and restart IBC, or use -Port."
            exit $E_NO_PORT
        }
        $Port = [int]$configured
    }
    if (-not $Server) {
        $bindAddress = $settings ? $settings['BindAddress'] : $null
        $Server = ($bindAddress -and $bindAddress -notin '0.0.0.0', '::') ? $bindAddress : '127.0.0.1'
    }

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        try {
            if (-not $client.ConnectAsync($Server, $Port).Wait([timespan]::FromSeconds(10))) {
                throw 'timed out'
            }
        } catch {
            Write-Failure "can't connect to IBC at ${Server}:$Port ($($_.Exception.GetBaseException().Message)). Check that IBC is running and that CommandServerPort is set in its configuration file."
            exit $E_NO_REPLY
        }

        $client.ReceiveTimeout = $TimeoutSeconds * 1000
        $stream = $client.GetStream()
        $reader = [System.IO.StreamReader]::new($stream)
        $writer = [System.IO.StreamWriter]::new($stream)
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true

        # send the command, then wait for the OK or ERROR reply. IBC may send INFO lines
        # first, and lines may start with the CommandPrompt text if one is configured
        $writer.WriteLine($Command.ToUpperInvariant())
        $result = $E_NO_REPLY
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                Write-Output $line
                if ($line -match '\bOK\b') { $result = 0; break }
                if ($line -match '\bERROR\b') { $result = $E_REJECTED; break }
            }
        } catch [System.IO.IOException] {
            # read timed out, or IBC closed the connection while shutting down
        }
        if ($result -eq $E_NO_REPLY) {
            Write-Failure "no reply from IBC to $Command"
        }

        # end the session tidily (IBC may already have closed it for stop)
        try {
            $writer.WriteLine('EXIT')
            $client.ReceiveTimeout = 2000
            $null = $reader.ReadLine()
        } catch {
        }

        exit $result
    } finally {
        $client.Dispose()
    }
}

#======================== start: run in a new window if required ===============

$minimize = $settings -and $settings['MinimizeIbcWindow'] -match '^(yes|true)$'

if (-not $Inline) {
    # Re-run in a new window. Any problem with the configuration is reported there,
    # where it stays visible.
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", 'start')
    $arguments += '-Config', "`"$Config`""
    if ($PSBoundParameters.ContainsKey('Account')) { $arguments += '-Account', $Account }
    if ($Gateway) { $arguments += '-Gateway' }
    $arguments += '-Inline', '-InWindow'
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments `
        -WorkingDirectory $PSScriptRoot -WindowStyle ($minimize ? 'Minimized' : 'Normal')
    exit 0
}

#======================== start ================================================

# exit codes set by this script
$E_NO_JAVA = 1001
$E_NO_TWS_VERSION = 1002
$E_INVALID_ARG = 1003
$E_TWS_VERSION_NOT_INSTALLED = 1004
$E_CONFIG_NOT_EXIST = 1006
$E_TWS_VMOPTIONS_NOT_FOUND = 1007
$E_TWS_SETTINGS_PATH_NOT_EXIST = 1008
$E_LOG_NOT_ACCESSIBLE = 1009

# exit code set by IBC if the second factor authentication dialog times out and
# the ExitAfterSecondFactorAuthenticationTimeout setting is true
$E_2FA_DIALOG_TIMED_OUT = 1111

# exit code set by IBC if the login dialog is not displayed within the time
# specified in the LoginDialogDisplayTimeout setting
$E_LOGIN_DIALOG_DISPLAY_TIMEOUT = 1112

$app = $Gateway ? 'Gateway' : 'TWS'
$ibcPath = $PSScriptRoot

class IbcError : System.Exception {
    [int]$Code
    [string[]]$Details
    IbcError([int]$code, [string]$message, [string[]]$details) : base($message) {
        $this.Code = $code
        $this.Details = $details
    }
}

function Fail([int]$Code, [string]$Message, [string[]]$Details = @()) {
    throw [IbcError]::new($Code, $Message, $Details)
}

$script:logWriter = $null
$script:logToConsole = $false

function Write-Log([string]$Text = '') {
    if ($script:logWriter) {
        $script:logWriter.WriteLine($Text)
    } elseif ($script:logToConsole) {
        Write-Host $Text
    }
}

function Write-Banner([string]$Text = '') {
    Write-Host "+ $Text"
}

# offline installs go in <TwsPath>\<version> (TWS) or <TwsPath>\ibgateway\<version>
function Find-NewestVersion([string[]]$Folders) {
    $Folders | Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Directory } |
        Where-Object { $_.Name -match '^\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'jars')) } |
        Sort-Object { [int]$_.Name } -Descending |
        Select-Object -First 1 -ExpandProperty Name
}

if ($InWindow) {
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'Green'
    Clear-Host
}

$phase = 'Reading the configuration file'
$exitCode = 0

try {
    if (-not $settings) {
        $Host.UI.RawUI.WindowTitle = "IBC ($app)"
        Fail $E_CONFIG_NOT_EXIST "IBC configuration file $Config does not exist" @(
            $PSBoundParameters.ContainsKey('Account') ?
                "Create it, or check the account name '$Account'" :
                "Create it from the config.ini in $ibcPath, or use an account name or -Config")
    }

    # launcher settings
    $twsPath = $settings['TwsPath'] ? $settings['TwsPath'] : "$env:SystemDrive\Jts"
    $twsMajorVersion = $settings['TwsMajorVersion']
    if (-not $twsMajorVersion) {
        $preferred = $Gateway ? @((Join-Path $twsPath 'ibgateway'), $twsPath) : @($twsPath, (Join-Path $twsPath 'ibgateway'))
        $twsMajorVersion = (Find-NewestVersion $preferred[0]) ?? (Find-NewestVersion $preferred[1])
        if (-not $twsMajorVersion) {
            Fail $E_NO_TWS_VERSION "No offline TWS/Gateway installation found in $twsPath" @(
                'Install the offline TWS/Gateway, or set TwsPath or TwsMajorVersion in the configuration file'
                'IBC does not work with the auto-updating TWS/Gateway')
        }
    }
    $on2FATimeout = $settings['On2FATimeout'] ? $settings['On2FATimeout'].ToLowerInvariant() : 'exit'
    if ($on2FATimeout -notin 'restart', 'exit') {
        Fail $E_INVALID_ARG "On2FATimeout is '$on2FATimeout' in $Config but must be either 'restart' or 'exit'"
    }
    $javaPath = $settings['JavaPath']
    $logPath = $settings['LogPath']
    if (-not $logPath) {
        $logPath = Join-Path $ibcPath 'Logs'
        if ($accountName) { $logPath = Join-Path $logPath $accountName }
    }

    $appDesc = "$app $twsMajorVersion$($accountName ? " $accountName" : '')"
    $Host.UI.RawUI.WindowTitle = "IBC ($appDesc)"

    $now = Get-Date

    Write-Host ('+' + '=' * 78)
    Write-Banner
    Write-Banner "IBC version $ibcVersion"
    Write-Banner
    Write-Banner "Running $appDesc at $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Banner

    #======================== Logging ==========================================

    if ($logPath -eq 'CON') {
        $script:logToConsole = $true
    } elseif ($logPath -ne 'none') {
        $phase = 'Opening the log file'
        New-Item -ItemType Directory -Path $logPath -Force | Out-Null

        $readme = Join-Path $logPath 'README.txt'
        if (-not (Test-Path -LiteralPath $readme)) {
            Set-Content -LiteralPath $readme -Value @(
                'You can delete the files in this folder at any time.'
                ''
                'Windows will inform you if a file is currently in use when you try to delete it.')
        }

        # one log file per day of the week, so each is overwritten a week later
        $dayName = $now.ToString('dddd', [cultureinfo]::InvariantCulture).ToUpperInvariant()
        $logFile = Join-Path $logPath "IBC-${ibcVersion}_$app-${twsMajorVersion}_$dayName.txt"
        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).LastWriteTime.Date -ne $now.Date) {
            Remove-Item -LiteralPath $logFile
        }

        try {
            $script:logWriter = [System.IO.StreamWriter]::new($logFile, $true)
            $script:logWriter.AutoFlush = $true
        } catch {
            Fail $E_LOG_NOT_ACCESSIBLE "The log file $logFile could not be opened" @(
                $_.Exception.Message
                'If another instance is using the same LogPath, give each instance its own')
        }

        Write-Banner 'Diagnostic information is logged in:'
        Write-Banner
        Write-Banner $logFile
        Write-Banner

        Write-Log
        Write-Log ('=' * 80)
        Write-Log ('=' * 80)
        Write-Log
        Write-Log 'This log file is located at:'
        Write-Log
        Write-Log "    $logFile"
        Write-Log
    }

    Write-Banner
    Write-Banner "** Caution: closing this window will close $appDesc **"
    if ($InWindow) { Write-Banner "(window will close automatically when you exit from $appDesc)" }
    Write-Banner

    #======================== Check everything ready to proceed ================

    $phase = 'Checking the configuration'

    $entryPoint = $Gateway ? 'ibcalpha.ibc.IbcGateway' : 'ibcalpha.ibc.IbcTws'

    $twsProgramPath = Join-Path $twsPath $twsMajorVersion
    $gatewayProgramPath = Join-Path $twsPath 'ibgateway' $twsMajorVersion
    if ($Gateway) {
        $programPath = $gatewayProgramPath
        $vmOptionsFile = Join-Path $programPath 'ibgateway.vmoptions'
        $altProgramPath = $twsProgramPath
        $altVmOptionsFile = Join-Path $altProgramPath 'tws.vmoptions'
    } else {
        $programPath = $twsProgramPath
        $vmOptionsFile = Join-Path $programPath 'tws.vmoptions'
        $altProgramPath = $gatewayProgramPath
        $altVmOptionsFile = Join-Path $altProgramPath 'ibgateway.vmoptions'
    }
    # TWS and Gateway installations are interchangeable, so use whichever is present
    if (-not (Test-Path -LiteralPath (Join-Path $programPath 'jars'))) {
        $programPath = $altProgramPath
        $vmOptionsFile = $altVmOptionsFile
    }
    $jarsPath = Join-Path $programPath 'jars'
    $install4jPath = Join-Path $programPath '.install4j'

    if (-not (Test-Path -LiteralPath $jarsPath)) {
        Fail $E_TWS_VERSION_NOT_INSTALLED "Offline TWS/Gateway version $twsMajorVersion is not installed: can't find jars folder" @(
            'Make sure you install the offline version of TWS/Gateway'
            'IBC does not work with the auto-updating TWS/Gateway')
    }

    # TWS settings: by default the folder that already holds them. Recent offline
    # installers keep them in the version folder rather than in TwsPath.
    $twsSettingsPath = $settings['TwsSettingsPath']
    if ($twsSettingsPath) {
        # an instance's own settings folder: create it on first use
        New-Item -ItemType Directory -Path $twsSettingsPath -Force | Out-Null
    } else {
        $twsSettingsPath = @($programPath, $twsPath) |
            Where-Object { Test-Path -LiteralPath (Join-Path $_ 'jts.ini') } |
            Select-Object -First 1
        if (-not $twsSettingsPath) { $twsSettingsPath = $twsPath }
    }
    if (-not (Test-Path -LiteralPath $twsSettingsPath -PathType Container)) {
        Fail $E_TWS_SETTINGS_PATH_NOT_EXIST "TWS settings path: $twsSettingsPath does not exist"
    }
    # normalise the settings path (no double or trailing backslashes): it is compared
    # with the paths of autorestart files
    $twsSettingsPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $twsSettingsPath).ProviderPath).TrimEnd('\')

    if (-not (Test-Path -LiteralPath $vmOptionsFile)) {
        Write-Log "$vmOptionsFile does not exist"
        Fail $E_TWS_VMOPTIONS_NOT_FOUND 'Neither tws.vmoptions nor ibgateway.vmoptions could be found'
    }
    if ($javaPath -and -not (Test-Path -LiteralPath (Join-Path $javaPath 'java.exe'))) {
        Fail $E_NO_JAVA "$javaPath does not contain the Java runtime executable"
    }

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log ('=' * 80)
    Write-Log
    Write-Log "Starting IBC version $ibcVersion on $($now.ToString('yyyy-MM-dd')) at $($now.ToString('HH:mm:ss.ff'))"
    Write-Log
    Write-Log "Operating system:  $($os.Caption) $($os.Version) $($os.OSArchitecture)"
    Write-Log "PowerShell:  $($PSVersionTable.PSVersion)"
    Write-Log
    Write-Log 'Settings:'
    Write-Log
    Write-Log "Program = $app"
    Write-Log "Account = $accountName"
    Write-Log "Config = $Config"
    Write-Log "Entry point = $entryPoint"
    Write-Log "TwsMajorVersion = $twsMajorVersion"
    Write-Log "TwsPath = $twsPath"
    Write-Log "TwsSettingsPath = $twsSettingsPath"
    Write-Log "IBC folder = $ibcPath"
    Write-Log "LogPath = $logPath"
    Write-Log "JavaPath = $javaPath"
    Write-Log "On2FATimeout = $on2FATimeout"
    Write-Log

    #======================== Generate the classpath ===========================

    $phase = 'Generating the classpath'

    $classpath = @(
        (Get-ChildItem -LiteralPath $jarsPath -Filter *.jar | Sort-Object Name).FullName
        Join-Path $install4jPath 'i4jruntime.jar'
        Join-Path $ibcPath 'IBC.jar'
    ) -join ';'
    Write-Log "Classpath=$classpath"
    Write-Log

    #======================== Generate the Java VM options =====================

    $phase = 'Generating the Java VM options'

    # the first token of each line in the .vmoptions file, ignoring comments
    $vmOptions = @(
        Get-Content -LiteralPath $vmOptionsFile |
            ForEach-Object { ($_.Trim() -split '\s+')[0] } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
    $sessionId = Get-Random -Minimum 100000000 -Maximum 999999999
    $vmOptions += @(
        '-Dtwslaunch.autoupdate.serviceImpl=com.ib.tws.twslaunch.install4j.Install4jAutoUpdateService'
        '-Dchannel=latest'
        '-Dexe4j.isInstall4j=true'
        '-Dinstall4jType=standalone'
        "-DjtsConfigDir=$twsSettingsPath"
        "-Dibcsessionid=$sessionId"
    )
    Write-Log "Java VM Options=$($vmOptions -join ' ')"
    Write-Log

    # further options set by the TWS installer, in .install4j\i4jparams.conf
    $phase = 'Generating the extra Java options'
    $extraJavaOptions = @()
    $i4jParams = Join-Path $install4jPath 'i4jparams.conf'
    if (Test-Path -LiteralPath $i4jParams) {
        $match = Select-String -LiteralPath $i4jParams -Pattern '<variable name="javaOptions" value="([^"]*)"' | Select-Object -First 1
        if ($match) {
            $extraJavaOptions = @($match.Matches[0].Groups[1].Value -split '\s+' | Where-Object { $_ })
        }
    }
    Write-Log "Extra Java options=$($extraJavaOptions -join ' ')"
    Write-Log

    #======================== Determine the location of java.exe ===============

    $phase = 'Determining the location of java.exe'

    if (-not $javaPath) {
        $candidates = @()
        foreach ($cfg in 'pref_jre.cfg', 'inst_jre.cfg') {
            $cfgFile = Join-Path $install4jPath $cfg
            if (Test-Path -LiteralPath $cfgFile) {
                $jre = Get-Content -LiteralPath $cfgFile -TotalCount 1
                if ($jre) { $candidates += Join-Path $jre.Trim() 'bin' }
            }
        }
        $candidates += Join-Path $programPath 'jre' 'bin'
        $candidates += Join-Path $env:ProgramData 'Oracle\Java\javapath'
        $javaPath = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'java.exe') } | Select-Object -First 1
    }
    if (-not $javaPath) {
        Fail $E_NO_JAVA "Can't find suitable Java installation"
    }
    $javaExe = Join-Path $javaPath 'java.exe'
    Write-Log "Location of java.exe=$javaPath"

    $javaVersion = & $javaExe -XshowSettings:properties -version 2>&1 |
        ForEach-Object { "$_" } |
        Where-Object { $_ -match '^\s*java\.version = ' } |
        ForEach-Object { ($_ -split '=', 2)[1].Trim() } |
        Select-Object -First 1
    Write-Log "Java version is $javaVersion"
    Write-Log

    #======================== Start IBC ========================================

    function Get-AutoRestartOption {
        # TWS writes an 'autorestart' file in the settings subfolder for the logged-in
        # user, when it's due to auto-restart without needing to authenticate again
        Write-Log 'Finding autorestart file'
        $files = @(
            Get-ChildItem -LiteralPath $twsSettingsPath -Directory |
                ForEach-Object { Join-Path $_.FullName 'autorestart' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
        )
        switch ($files.Count) {
            0 {
                Write-Log 'autorestart file not found: full authentication will be required'
                return [pscustomobject]@{ Option = $null; RestartNeeded = $false }
            }
            1 {
                Write-Log "autorestart file found at $($files[0]): authentication will not be required"
                $folder = Split-Path (Split-Path $files[0] -Parent) -Leaf
                return [pscustomobject]@{ Option = "-Drestart=$folder"; RestartNeeded = $true }
            }
            default {
                $files | ForEach-Object {
                    Write-Log "WARNING: deleting autorestart file found at $_"
                    Remove-Item -LiteralPath $_
                }
                Write-Log ('*' * 79)
                Write-Log 'WARNING: More than one autorestart file was found. IBC can''t determine which is'
                Write-Log '         the right one, so they''ve all been deleted. Full authentication will'
                Write-Log '         be required.'
                Write-Log
                Write-Log '         If you have two or more TWS/Gateway instances with the same'
                Write-Log '         TwsSettingsPath, you should ensure that they are configured with'
                Write-Log '         different autorestart times, to avoid creation of multiple autorestart'
                Write-Log '         files.'
                Write-Log ('*' * 79)
                return [pscustomobject]@{ Option = $null; RestartNeeded = $true }
            }
        }
    }

    $autoRestartOption = (Get-AutoRestartOption).Option
    Write-Log

    # prevent other Java tools interfering with IBC
    $env:JAVA_TOOL_OPTIONS = $null

    Push-Location -LiteralPath $twsSettingsPath
    try {
        while ($true) {
            $phase = 'Running IBC'

            # stop TWS/Gateway being restarted without IBC. A single overwriting move,
            # rather than delete-then-rename, so that another IBC instance starting at
            # the same time can't delete the file this one has just renamed
            foreach ($exe in 'tws', 'ibgateway') {
                $exeFile = Join-Path $programPath "$exe.exe"
                if (Test-Path -LiteralPath $exeFile) {
                    Write-Log "Renaming $exe.exe to $($exe)1.exe to prevent restart without IBC"
                    try {
                        Move-Item -LiteralPath $exeFile -Destination (Join-Path $programPath "$($exe)1.exe") -Force
                    } catch {
                        # fine if another instance has just renamed it
                        if (Test-Path -LiteralPath $exeFile) { throw }
                    }
                }
            }

            # credentials and the trading mode come from the configuration file
            $javaArgs = @(
                $extraJavaOptions
                '-cp', $classpath
                $vmOptions
                if ($autoRestartOption) { $autoRestartOption }
                $entryPoint
                $Config
            )

            Write-Log
            Write-Log 'Starting IBC with this command:'
            Write-Log "`"$javaExe`" $($javaArgs -join ' ')"
            Write-Log

            # IBC's console output goes to the log
            & $javaExe @javaArgs 2>$null | ForEach-Object { Write-Log $_ }
            $exitCode = $LASTEXITCODE

            Write-Log 'Program has exited'
            Write-Log "Exit code is $exitCode"

            if ($exitCode -eq $E_2FA_DIALOG_TIMED_OUT) {
                if ($on2FATimeout -eq 'restart') {
                    Write-Log 'IBC will restart shortly due to 2FA completion timeout'
                    Start-Sleep -Seconds 2
                    continue
                }
                Write-Log '2FA completion timed out but On2FATimeout is exit, so not restarting IBC'
                Write-Banner 'Second factor authentication dialog has timed out, IBC not restarted'
                $exitCode = 0
                break
            }

            if ($exitCode -eq $E_LOGIN_DIALOG_DISPLAY_TIMEOUT) {
                Write-Log 'IBC will restart shortly due to login dialog display timeout'
                Start-Sleep -Seconds 2
                continue
            }

            $restart = Get-AutoRestartOption
            $autoRestartOption = $restart.Option
            if ($restart.RestartNeeded) {
                $pauseFile = Join-Path $twsSettingsPath "PAUSE$sessionId"
                if (Test-Path -LiteralPath $pauseFile) {
                    Remove-Item -LiteralPath $pauseFile
                    Write-Log 'IBC is paused'
                    break
                }
                Write-Log 'IBC will autorestart shortly'
                Start-Sleep -Seconds 2
                continue
            }

            $coldRestartFile = Join-Path $twsSettingsPath "COLDRESTART$sessionId"
            if (Test-Path -LiteralPath $coldRestartFile) {
                Remove-Item -LiteralPath $coldRestartFile
                $autoRestartOption = $null
                Write-Log 'IBC will cold-restart shortly'
                continue
            }

            break
        }
    } finally {
        Pop-Location
    }

    Write-Log 'Normal exit'
    Write-Log
    Write-Log "IBC running $appDesc has finished at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Log

    # killing the Java process gives exit code 1, which isn't treated as an error.
    # All exit codes set by IBC are greater than 1000
    if ($exitCode -ge 2) {
        Fail $exitCode 'IBC exited with an error'
    }
    $exitCode = 0
} catch {
    $err = $_.Exception
    $exitCode = ($err -is [IbcError]) ? $err.Code : 1

    Write-Log
    Write-Log '=========================== An error has occurred ============================='
    Write-Log
    Write-Log "Error while: $phase"
    Write-Log "Error: $($err.Message)"
    if ($err -is [IbcError]) { $err.Details | ForEach-Object { Write-Log "       $_" } }
    if ($err -isnot [IbcError]) { Write-Log $_.ScriptStackTrace }

    $Host.UI.RawUI.ForegroundColor = 'Red'
    Write-Host ('+' + '=' * 78)
    Write-Banner
    Write-Banner '                     **** An error has occurred ****'
    Write-Banner
    Write-Banner "Error while: $phase"
    Write-Banner
    Write-Banner "Exit code = $exitCode"
    Write-Banner
    Write-Banner "Error: $($err.Message)"
    if ($err -is [IbcError]) { $err.Details | ForEach-Object { Write-Banner "       $_" } }
    if ($script:logWriter) {
        Write-Banner
        Write-Banner 'Please look in the log file mentioned above for further information'
    }
    Write-Banner
    Write-Host ('+' + '=' * 78)

} finally {
    if ($script:logWriter) { $script:logWriter.Dispose() }
}

# keep IBC's own window open so the error can be read (after closing the log, so
# it can be opened or deleted meanwhile)
if ($exitCode -ne 0 -and $InWindow) {
    Write-Banner
    Write-Banner 'Press any key to close this window'
    [void][Console]::ReadKey($true)
}

exit $exitCode
