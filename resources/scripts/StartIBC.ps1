#Requires -Version 7

<#
.SYNOPSIS
Runs IBC, thus loading TWS or the IB Gateway.

.DESCRIPTION
This is a 'service script' called from StartTWS.ps1 and StartGateway.ps1. There
should be no reason for the end user to modify it in any way. So PLEASE DON'T
CHANGE IT UNLESS YOU KNOW WHAT YOU'RE DOING!

Unless -Inline is supplied, the calling script is re-run with -Inline in a new
console window, which then shows the banner and runs TWS/Gateway. Detailed
diagnostic information is written to the log file (see -LogPath).
#>

[CmdletBinding()]
param(
    # The major version number of TWS/Gateway, eg 1045
    [Parameter(Mandatory)][string]$TwsMajorVersion,

    # Load the IB Gateway rather than TWS
    [switch]$Gateway,

    # The location and filename of the IBC configuration file
    [string]$Config = "$env:USERPROFILE\Documents\IBC\config.ini",

    # 'live' or 'paper'. If empty, the TradingMode setting in the configuration file is used
    [ValidateSet('', 'live', 'paper')][string]$TradingMode = '',

    # What to do if IBC exits because second factor authentication timed out: 'restart' or 'exit'
    [ValidateSet('restart', 'exit')][string]$On2FATimeout = 'exit',

    # The IBC installation folder. Defaults to the parent of this script's folder
    [string]$IbcPath = (Split-Path $PSScriptRoot -Parent),

    # The TWS installation folder
    [string]$TwsPath = "$env:SystemDrive\Jts",

    # The TWS settings folder. Defaults to $TwsPath
    [string]$TwsSettingsPath = '',

    # Folder for the diagnostic log. 'CON' logs to this window; empty means no logging
    [string]$LogPath = '',

    [string]$UserId = '',
    [string]$Password = '',
    [string]$FixUserId = '',
    [string]$FixPassword = '',

    # Folder containing the java.exe to use. Defaults to the Java included with TWS
    [string]$JavaPath = '',

    # Minimise the IBC window (no effect with -Inline)
    [switch]$Hide,

    # Run in the current window rather than opening a new one. Required when
    # running from Task Scheduler
    [switch]$Inline,

    # Set when the calling script has been re-run in its own window
    [switch]$InWindow
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# exit codes set by this script
$E_NO_JAVA = 1001
$E_INVALID_ARG = 1003
$E_TWS_VERSION_NOT_INSTALLED = 1004
$E_IBC_PATH_NOT_EXIST = 1005
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
$appDesc = "$app $TwsMajorVersion"

#======================== Run in a new window if required =====================

if (-not $Inline) {
    $caller = $MyInvocation.PSCommandPath
    if (-not $caller) { $caller = $PSCommandPath }
    $pwsh = (Get-Process -Id $PID).Path
    Start-Process -FilePath $pwsh `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$caller`"", '-Inline', '-InWindow' `
        -WorkingDirectory $IbcPath `
        -WindowStyle ($Hide ? 'Minimized' : 'Normal')
    exit 0
}

$Host.UI.RawUI.WindowTitle = "IBC ($appDesc)"
if ($InWindow) {
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'Green'
    Clear-Host
}

#======================== Logging ==============================================

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

$phase = 'Starting'
$exitCode = 0

try {
    $ibcVersion = (Get-Content -LiteralPath (Join-Path $IbcPath 'version') -TotalCount 1 -ErrorAction SilentlyContinue) ?? 'unknown'
    $now = Get-Date

    Write-Host ('+' + '=' * 78)
    Write-Banner
    Write-Banner "IBC version $ibcVersion"
    Write-Banner
    Write-Banner "Running $appDesc at $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Banner

    if ($LogPath -eq 'CON') {
        $script:logToConsole = $true
    } elseif ($LogPath) {
        $phase = 'Opening the log file'
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null

        $readme = Join-Path $LogPath 'README.txt'
        if (-not (Test-Path -LiteralPath $readme)) {
            Set-Content -LiteralPath $readme -Value @(
                'You can delete the files in this folder at any time.'
                ''
                'Windows will inform you if a file is currently in use when you try to delete it.')
        }

        # one log file per day of the week, so each is overwritten a week later
        $dayName = $now.ToString('dddd', [cultureinfo]::InvariantCulture).ToUpperInvariant()
        $logFile = Join-Path $LogPath "IBC-${ibcVersion}_$app-${TwsMajorVersion}_$dayName.txt"
        if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).LastWriteTime.Date -ne $now.Date) {
            Remove-Item -LiteralPath $logFile
        }

        try {
            $script:logWriter = [System.IO.StreamWriter]::new($logFile, $true)
            $script:logWriter.AutoFlush = $true
        } catch {
            Fail $E_LOG_NOT_ACCESSIBLE "The log file $logFile could not be opened" @($_.Exception.Message)
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

    #======================== Check the arguments ==============================

    $phase = 'Checking supplied configuration data'

    $gotApiCredentials = [bool]($UserId -or $Password)
    $gotFixCredentials = [bool]($FixUserId -or $FixPassword)

    if ($gotFixCredentials -and -not $Gateway) {
        Fail $E_INVALID_ARG 'FIX user id and FIX password are only valid for the Gateway'
    }

    $entryPoint = $Gateway ? 'ibcalpha.ibc.IbcGateway' : 'ibcalpha.ibc.IbcTws'

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log ('=' * 80)
    Write-Log
    Write-Log "Starting IBC version $ibcVersion on $($now.ToString('yyyy-MM-dd')) at $($now.ToString('HH:mm:ss.ff'))"
    Write-Log
    Write-Log "Operating system:  $($os.Caption) $($os.Version) $($os.OSArchitecture)"
    Write-Log "PowerShell:  $($PSVersionTable.PSVersion)"
    Write-Log
    Write-Log 'Arguments:'
    Write-Log
    Write-Log "TWS version = $TwsMajorVersion"
    Write-Log "Program = $app"
    Write-Log "Entry point = $entryPoint"
    Write-Log "TwsPath = $TwsPath"
    Write-Log "TwsSettingsPath = $TwsSettingsPath"
    Write-Log "IbcPath = $IbcPath"
    Write-Log "Config = $Config"
    Write-Log "TradingMode = $TradingMode"
    Write-Log "On2FATimeout = $On2FATimeout"
    Write-Log "JavaPath = $JavaPath"
    Write-Log "User = $($gotApiCredentials ? '***' : '')"
    Write-Log "PW = $($gotApiCredentials ? '***' : '')"
    Write-Log "FIXUser = $($gotFixCredentials ? '***' : '')"
    Write-Log "FIXPW = $($gotFixCredentials ? '***' : '')"
    Write-Log

    #======================== Check everything ready to proceed ================

    if (-not $TwsSettingsPath) { $TwsSettingsPath = $TwsPath }

    $twsProgramPath = Join-Path $TwsPath $TwsMajorVersion
    $gatewayProgramPath = Join-Path $TwsPath 'ibgateway' $TwsMajorVersion

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
        Fail $E_TWS_VERSION_NOT_INSTALLED "Offline TWS/Gateway version $TwsMajorVersion is not installed: can't find jars folder" @(
            'Make sure you install the offline version of TWS/Gateway'
            'IBC does not work with the auto-updating TWS/Gateway')
    }
    if (-not (Test-Path -LiteralPath $TwsSettingsPath -PathType Container)) {
        Fail $E_TWS_SETTINGS_PATH_NOT_EXIST "TWS settings path: $TwsSettingsPath does not exist"
    }
    # normalise the settings path (no double or trailing backslashes): IBC compares it
    # with the paths of autorestart files
    $TwsSettingsPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $TwsSettingsPath).ProviderPath).TrimEnd('\')

    if (-not (Test-Path -LiteralPath $IbcPath -PathType Container)) {
        Fail $E_IBC_PATH_NOT_EXIST "IBC path: $IbcPath does not exist"
    }
    if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) {
        Fail $E_CONFIG_NOT_EXIST "IBC configuration file: $Config does not exist"
    }
    if (-not (Test-Path -LiteralPath $vmOptionsFile)) {
        Write-Log "$vmOptionsFile does not exist"
        Fail $E_TWS_VMOPTIONS_NOT_FOUND 'Neither tws.vmoptions nor ibgateway.vmoptions could be found'
    }
    if ($JavaPath -and -not (Test-Path -LiteralPath (Join-Path $JavaPath 'java.exe'))) {
        Fail $E_NO_JAVA "$JavaPath does not contain the Java runtime executable"
    }

    #======================== Generate the classpath ===========================

    $phase = 'Generating the classpath'

    $classpath = @(
        (Get-ChildItem -LiteralPath $jarsPath -Filter *.jar | Sort-Object Name).FullName
        Join-Path $install4jPath 'i4jruntime.jar'
        Join-Path $IbcPath 'IBC.jar'
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
        "-DjtsConfigDir=$TwsSettingsPath"
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

    if (-not $JavaPath) {
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
        $JavaPath = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'java.exe') } | Select-Object -First 1
    }
    if (-not $JavaPath) {
        Fail $E_NO_JAVA "Can't find suitable Java installation"
    }
    $javaExe = Join-Path $JavaPath 'java.exe'
    Write-Log "Location of java.exe=$JavaPath"

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
            Get-ChildItem -LiteralPath $TwsSettingsPath -Directory |
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
                Write-Log '         If you have two or more TWS/Gateway instances with the same setting'
                Write-Log '         for TwsSettingsPath, you should ensure that they are configured with'
                Write-Log '         different autorestart times, to avoid creation of multiple autorestart'
                Write-Log '         files.'
                Write-Log ('*' * 79)
                return [pscustomobject]@{ Option = $null; RestartNeeded = $true }
            }
        }
    }

    $autoRestartOption = (Get-AutoRestartOption).Option
    Write-Log

    $credentials = @()
    if ($gotFixCredentials) { $credentials += $FixUserId, $FixPassword }
    if ($gotApiCredentials) { $credentials += $UserId, $Password }
    $hiddenCredentials = @('***') * $credentials.Count

    # prevent other Java tools interfering with IBC
    $env:JAVA_TOOL_OPTIONS = $null

    Push-Location -LiteralPath $TwsSettingsPath
    try {
        while ($true) {
            $phase = 'Running IBC'

            # stop TWS/Gateway being restarted without IBC
            foreach ($exe in 'tws', 'ibgateway') {
                $exeFile = Join-Path $programPath "$exe.exe"
                if (Test-Path -LiteralPath $exeFile) {
                    Write-Log "Renaming $exe.exe to $($exe)1.exe to prevent restart without IBC"
                    Remove-Item -LiteralPath (Join-Path $programPath "$($exe)1.exe") -ErrorAction SilentlyContinue
                    Rename-Item -LiteralPath $exeFile -NewName "$($exe)1.exe"
                }
            }

            $javaArgs = @(
                $extraJavaOptions
                '-cp', $classpath
                $vmOptions
                if ($autoRestartOption) { $autoRestartOption }
                $entryPoint
                $Config
            )
            $tradingModeArg = @(if ($TradingMode) { $TradingMode })

            Write-Log
            Write-Log 'Starting IBC with this command:'
            Write-Log "`"$javaExe`" $(($javaArgs + $hiddenCredentials + $tradingModeArg) -join ' ')"
            Write-Log

            # IBC's console output goes to the log
            & $javaExe @javaArgs @credentials @tradingModeArg 2>$null | ForEach-Object { Write-Log $_ }
            $exitCode = $LASTEXITCODE

            Write-Log 'Program has exited'
            Write-Log "Exit code is $exitCode"

            if ($exitCode -eq $E_2FA_DIALOG_TIMED_OUT) {
                if ($On2FATimeout -eq 'restart') {
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
                $pauseFile = Join-Path $TwsSettingsPath "PAUSE$sessionId"
                if (Test-Path -LiteralPath $pauseFile) {
                    Remove-Item -LiteralPath $pauseFile
                    Write-Log 'IBC is paused'
                    break
                }
                Write-Log 'IBC will autorestart shortly'
                Start-Sleep -Seconds 2
                continue
            }

            $coldRestartFile = Join-Path $TwsSettingsPath "COLDRESTART$sessionId"
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

    if ($InWindow) {
        Write-Banner
        Write-Banner 'Press any key to close this window'
        [void][Console]::ReadKey($true)
    }
} finally {
    if ($script:logWriter) { $script:logWriter.Dispose() }
}

exit $exitCode
