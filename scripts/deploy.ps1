#Requires -Version 7

<#
.SYNOPSIS
Builds IBC and deploys the Windows distribution to a local folder, with
settings for a live and a paper-trading account.

.DESCRIPTION
Runs the Gradle 'dist' task (unless -SkipBuild is given), then extracts
build/dist/IBC-<version>-windows.zip into the destination folder. Everything is
started and controlled with ibc.ps1 in that folder, eg 'ibc.ps1 start paper'.

Unless -NoAccounts is given, it also sets up two accounts, 'live' and 'paper',
which can run at the same time:

  For each account     live                            paper
  -------------------  ------------------------------  ------------------------------
  config file          <ConfigFolder>\config-live.ini  <ConfigFolder>\config-paper.ini
  TWS settings folder  <TwsPath>\live                  <TwsPath>\paper
  log folder           <Destination>\Logs\live         <Destination>\Logs\paper
  API port             7496                            7497
  command port         7462                            7463
  shortcuts            IBC (TWS live)                  IBC (TWS paper)
                       IBC (Gateway live)              IBC (Gateway paper)

The config files are only created if they don't exist, and are otherwise
never changed, except that one without a TwsSettingsPath setting (made by an
earlier version of this script) gets that line added, so that the two
accounts keep separate settings folders. Fill in IbLoginId and IbPassword in
each.

A new live or paper TWS settings folder starts as a copy of your existing TWS
settings (jts.ini, xmlopt.dat and the per-user folders, without their logs), so
both instances keep your layouts. Existing folders are never touched.

If the destination already contains an IBC installation, its config.ini (a
template; the config files you use are in ConfigFolder) is kept unless you
supply -OverwriteSettings, in which case it is first saved as config.ini.bak.
Everything else is replaced. Files that aren't part of the new version (for
example the start scripts and scripts\ folder of an earlier version) are listed
but not deleted.

Only the shortcuts that work on this computer are created: the plain
'IBC (TWS)' and 'IBC (Gateway)' only if <ConfigFolder>\config.ini exists, and
the Gateway ones only if IB Gateway is installed (<TwsPath>\ibgateway\<version>).
Ones from an earlier deploy that no longer apply are removed.

The shortcuts and the sample scheduled task are set to run pwsh.exe from
C:\Program Files\PowerShell\7 or, for a Microsoft Store install, from its
per-user alias in %LOCALAPPDATA%\Microsoft\WindowsApps (the Store's own
folder name changes with every update).

.PARAMETER Destination
The folder to deploy to, for example C:\IBC. It is created if necessary.

.PARAMETER IbcBin
The folder containing the TWS jar files, needed for the build. Any installed
version will do. Defaults to the IBC_BIN environment variable.

.PARAMETER TwsPath
The folder TWS/Gateway is installed in. Default: C:\Jts.

.PARAMETER ConfigFolder
Where to create the account config files. Default:
%USERPROFILE%\Documents\IBC, which should ideally be encrypted. This is also
where ibc.ps1 looks for them.

.PARAMETER NoAccounts
Don't set up the live and paper accounts.

.PARAMETER SkipBuild
Deploy the existing build/dist ZIP without building first.

.PARAMETER OverwriteSettings
Replace an existing config.ini in the destination (saved first as
config.ini.bak). The account config files are never replaced.

.EXAMPLE
./scripts/deploy.ps1 C:\IBC

.EXAMPLE
./scripts/deploy.ps1 D:\Trading\IBC -IbcBin C:\Jts\1051\jars
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Destination,

    [string]$IbcBin = $env:IBC_BIN,

    [string]$TwsPath = "$env:SystemDrive\Jts",

    [string]$ConfigFolder = "$env:USERPROFILE\Documents\IBC",

    [switch]$NoAccounts,

    [switch]$SkipBuild,

    [switch]$OverwriteSettings
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repo = Split-Path $PSScriptRoot -Parent
$fullPath = { param($p) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p).TrimEnd('\') }
$Destination = & $fullPath $Destination
$TwsPath = & $fullPath $TwsPath
$ConfigFolder = & $fullPath $ConfigFolder

$accounts = if ($NoAccounts) { @() } else {
    @(
        @{ Name = 'live';  ApiPort = 7496; CommandPort = 7462; AcceptNonBrokerageAccountWarning = 'no' }
        @{ Name = 'paper'; ApiPort = 7497; CommandPort = 7463; AcceptNonBrokerageAccountWarning = 'yes' }
    )
}

$versionLine = Select-String -LiteralPath (Join-Path $repo 'gradle.properties') -Pattern '^\s*version\s*=\s*(\S+)' |
    Select-Object -First 1
if (-not $versionLine) { throw "Can't find the version in gradle.properties" }
$version = $versionLine.Matches[0].Groups[1].Value

#======================== Find TWS ==============================================

# Only used here for the shortcut icons and to find the existing settings: ibc.ps1
# works out the version to run each time it starts.
$twsVersion = @($TwsPath, (Join-Path $TwsPath 'ibgateway')) |
    Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object { Get-ChildItem -LiteralPath $_ -Directory } |
    Where-Object { $_.Name -match '^\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'jars')) } |
    Sort-Object { [int]$_.Name } -Descending |
    Select-Object -First 1 -ExpandProperty Name
if ($twsVersion) {
    Write-Host "Found TWS/Gateway version $twsVersion in $TwsPath"
} else {
    Write-Warning "No offline TWS/Gateway installation found in ${TwsPath}: ibc.ps1 won't be able to start TWS until there is one."
}

# Where the existing TWS settings are. Recent offline installers keep them in the
# version folder (<TwsPath>\<version>\jts.ini); older ones used <TwsPath> itself.
$twsSettings = @(
    if ($twsVersion) { Join-Path $TwsPath $twsVersion }
    $TwsPath) |
    Where-Object { Test-Path -LiteralPath (Join-Path $_ 'jts.ini') } |
    Select-Object -First 1
if ($twsSettings) { Write-Host "Found existing TWS settings in $twsSettings" }

#======================== Build ================================================

if (-not $SkipBuild) {
    if (-not $IbcBin) {
        throw 'The TWS jar folder is not set: supply -IbcBin or set the IBC_BIN environment variable'
    }
    Write-Host "Building IBC $version"
    & (Join-Path $repo 'gradlew.bat') --project-dir $repo dist "-PibcBin=$IbcBin"
    if ($LASTEXITCODE -ne 0) { throw "The build failed (exit code $LASTEXITCODE)" }
}

$zip = Join-Path $repo "build\dist\IBC-$version-windows.zip"
if (-not (Test-Path -LiteralPath $zip)) {
    throw "$zip doesn't exist: build first, or run without -SkipBuild"
}

#======================== Deploy ===============================================

Write-Host "Deploying $zip to $Destination"

$kept = [System.Collections.Generic.List[string]]::new()
$replaced = [System.Collections.Generic.List[string]]::new()
$created = [System.Collections.Generic.List[string]]::new()
$updated = [System.Collections.Generic.List[string]]::new()
$seeded = [System.Collections.Generic.List[string]]::new()
$generatedFiles = [System.Collections.Generic.List[string]]::new()

$staging = Join-Path ([System.IO.Path]::GetTempPath()) "ibc-deploy-$([guid]::NewGuid())"
Expand-Archive -LiteralPath $zip -DestinationPath $staging
try {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $packageFiles = Get-ChildItem -LiteralPath $staging -Recurse -File |
        ForEach-Object { [System.IO.Path]::GetRelativePath($staging, $_.FullName) }

    foreach ($rel in $packageFiles) {
        $source = Join-Path $staging $rel
        $target = Join-Path $Destination $rel

        if ($rel -eq 'config.ini' -and (Test-Path -LiteralPath $target)) {
            if (-not $OverwriteSettings) { $kept.Add($rel); continue }
            Copy-Item -LiteralPath $target -Destination "$target.bak" -Force
            $replaced.Add($rel)
        }

        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        try {
            Copy-Item -LiteralPath $source -Destination $target -Force
        } catch [System.IO.IOException] {
            throw "Can't replace $target ($($_.Exception.Message)). If IBC is running from $Destination, stop it first."
        }
    }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

#======================== Live and paper accounts ==============================

# Copies the settings part of a TWS settings folder: jts.ini, xmlopt.dat and the per-user
# folders (named with 40 lowercase letters), leaving out the encrypted logs (*.ibgzenc).
# The source may also be an installation folder, so nothing else is copied.
function Copy-TwsSettings([string]$Source, [string]$Target) {
    foreach ($file in 'jts.ini', 'xmlopt.dat') {
        $path = Join-Path $Source $file
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $Target }
    }
    Get-ChildItem -LiteralPath $Source -Directory |
        Where-Object { $_.Name -cmatch '^[a-z]{40}$' } |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Recurse -File |
                Where-Object Extension -ne '.ibgzenc' |
                ForEach-Object {
                    $to = Join-Path $Target ([System.IO.Path]::GetRelativePath($Source, $_.FullName))
                    New-Item -ItemType Directory -Path (Split-Path $to -Parent) -Force | Out-Null
                    Copy-Item -LiteralPath $_.FullName -Destination $to
                }
        }
}

# a path as written in a Java properties file
function ConvertTo-PropertyValue([string]$Path) { $Path.Replace('\', '\\') }

foreach ($account in $accounts) {
    $name = $account.Name
    $configFile = Join-Path $ConfigFolder "config-$name.ini"
    $settingsFolder = Join-Path $TwsPath $name

    # TWS settings folder: each instance needs its own. A new one starts as a copy of
    # the existing TWS settings (without the logs), so the instance keeps your layouts.
    # Both users' folders are copied, because their names don't say which is live and
    # which is paper; TWS only uses the one that logs in.
    if (-not (Test-Path -LiteralPath $settingsFolder)) {
        try {
            New-Item -ItemType Directory -Path $settingsFolder | Out-Null
            if ($twsSettings) {
                Copy-TwsSettings $twsSettings $settingsFolder
                $seeded.Add("$settingsFolder (from $twsSettings)")
            }
        } catch {
            Write-Warning "Can't create $settingsFolder ($($_.Exception.Message)): ibc.ps1 will try again when it starts the $name account."
        }
    }

    if (Test-Path -LiteralPath $configFile) {
        # made by an earlier version of this script, without TwsSettingsPath: add it, so
        # the accounts don't share a settings folder
        if (-not (Select-String -LiteralPath $configFile -Pattern '^\s*TwsSettingsPath\s*=\s*\S' -Quiet)) {
            Add-Content -LiteralPath $configFile -Value @(
                ''
                ''
                "# This account's own TWS settings folder (added by deploy.ps1)."
                ''
                "TwsSettingsPath=$(ConvertTo-PropertyValue $settingsFolder)")
            $updated.Add($configFile)
        }
        continue
    }

    # config file: created once, otherwise never changed, because it holds credentials
    New-Item -ItemType Directory -Path $ConfigFolder -Force | Out-Null
    Set-Content -LiteralPath $configFile -Value @"
# IBC configuration for the '$name' account (created by deploy.ps1).
#
# Start it with:   ibc.ps1 start $name           (TWS)
#                  ibc.ps1 start $name -Gateway  (IB Gateway)
# Stop it with:    ibc.ps1 stop $name
#
# Only the settings that must differ between the live and paper instances are
# set here. Every other setting takes its default, which is the value shown in
# the full config.ini in the IBC folder, where each setting is described. Add
# any other settings you need from that file.


# The IBKR username and password for this account. A live account and its
# paper-trading account have different usernames.

IbLoginId=
IbPassword=


TradingMode=$name


# This account's own TWS settings folder: instances running at the same time
# need different ones. Leave IbDir empty: if it differed, auto-restart would
# fail.

TwsSettingsPath=$(ConvertTo-PropertyValue $settingsFolder)
IbDir=


# The port that API programs connect to. TWS normally uses 7496 for live and
# 7497 for paper; IB Gateway normally uses 4001 and 4002, so change this if you
# mainly run the Gateway. Instances running at the same time need different
# ports.

OverrideTwsApiPort=$($account.ApiPort)


# The port for IBC commands such as 'ibc.ps1 stop $name'. Instances running at
# the same time need different ports. Set to 0 to disable commands.

CommandServerPort=$($account.CommandPort)


# Whether to accept the warning TWS shows when logging in to a paper-trading
# account (API connections are refused until it's accepted).

AcceptNonBrokerageAccountWarning=$($account.AcceptNonBrokerageAccountWarning)
"@
    $created.Add($configFile)
}

#======================== Shortcuts and scheduled task =========================

# The shortcuts and the scheduled task need a pwsh.exe path that survives PowerShell
# updates. A Microsoft Store install runs from a versioned folder, so for that use its
# per-user alias instead.
$pwsh = @(
    Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $pwsh) { $pwsh = (Get-Process -Id $PID).Path }

$ibcScript = Join-Path $Destination 'ibc.ps1'

# sample scheduled task
$defaultPath = "$env:SystemDrive\IBC"
$taskFile = Join-Path $Destination 'Start TWS (autorestart).xml'
if (Test-Path -LiteralPath $taskFile) {
    $text = [System.IO.File]::ReadAllText($taskFile)
    $text = $text -replace '<Command>[^<]*</Command>',
        "<Command>$([System.Security.SecurityElement]::Escape($pwsh))</Command>"
    if ($Destination -ne $defaultPath) {
        $escaped = [System.Security.SecurityElement]::Escape($Destination)
        $text = $text.Replace('C:\IBC\', "$escaped\").Replace('>C:\IBC<', ">$escaped<")
    }
    [System.IO.File]::WriteAllText($taskFile, $text)
}

# Icons: IBC renames tws.exe to tws1.exe (and ibgateway.exe to ibgateway1.exe) when it
# starts, so use whichever exists now
function Find-Icon([string[]]$Candidates) {
    $Candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}
$twsIcon = $gatewayIcon = $null
if ($twsVersion) {
    $twsIcon = Find-Icon @('tws1.exe', 'tws.exe' | ForEach-Object { Join-Path $TwsPath "$twsVersion\$_" })
    $gatewayIcon = Find-Icon @('ibgateway1.exe', 'ibgateway.exe' | ForEach-Object { Join-Path $TwsPath "ibgateway\$twsVersion\$_" })
}
if (-not $gatewayIcon) { $gatewayIcon = $twsIcon }

# Only create the shortcuts that work here: the plain ones need <ConfigFolder>\config.ini,
# and the Gateway ones an installed Gateway (without one, -Gateway would run the Gateway
# from the TWS installation, which works but is rarely what's wanted)
$hasDefaultConfig = Test-Path -LiteralPath (Join-Path $ConfigFolder 'config.ini')
$hasGateway = [bool](Get-ChildItem -LiteralPath (Join-Path $TwsPath 'ibgateway') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'jars')) })

$candidates = [System.Collections.Generic.List[object]]::new()
$candidates.Add(@{ Name = 'IBC (TWS).lnk'; Arguments = 'start'; Icon = $twsIcon; Wanted = $hasDefaultConfig })
$candidates.Add(@{ Name = 'IBC (Gateway).lnk'; Arguments = 'start -Gateway'; Icon = $gatewayIcon; Wanted = $hasDefaultConfig -and $hasGateway })
foreach ($account in $accounts) {
    $name = $account.Name
    $candidates.Add(@{ Name = "IBC (TWS $name).lnk"; Arguments = "start $name"; Icon = $twsIcon; Wanted = $true })
    $candidates.Add(@{ Name = "IBC (Gateway $name).lnk"; Arguments = "start $name -Gateway"; Icon = $gatewayIcon; Wanted = $hasGateway })
}

$createdShortcuts = [System.Collections.Generic.List[string]]::new()
$removedShortcuts = [System.Collections.Generic.List[string]]::new()
$shell = New-Object -ComObject WScript.Shell
foreach ($link in $candidates) {
    $file = Join-Path $Destination $link.Name
    $generatedFiles.Add($link.Name)
    if (-not $link.Wanted) {
        # one this script (or the package) made, which doesn't apply here (any more)
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file
            if ($link.Name -notin $packageFiles) { $removedShortcuts.Add($link.Name) }
        }
        continue
    }
    $createdShortcuts.Add($link.Name.Replace('.lnk', ''))
    $shortcut = $shell.CreateShortcut($file)
    $shortcut.TargetPath = $pwsh
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ibcScript`" $($link.Arguments)"
    $shortcut.WorkingDirectory = $Destination
    $shortcut.WindowStyle = 7   # ibc.ps1 opens its own window, so keep the launcher's out of the way
    if ($link.Icon) { $shortcut.IconLocation = "$($link.Icon),0" }
    $shortcut.Save()
}

#======================== Report ===============================================

$obsolete = Get-ChildItem -LiteralPath $Destination -Recurse -File |
    ForEach-Object { [System.IO.Path]::GetRelativePath($Destination, $_.FullName) } |
    Where-Object {
        $_ -notin $packageFiles -and $_ -notin $generatedFiles -and
        $_ -notlike 'Logs\*' -and $_ -notlike '*.bak'
    }

Write-Host
Write-Host "Deployed IBC $version to $Destination"
if ($accounts) {
    Write-Host "Set up the $(($accounts | ForEach-Object Name) -join ' and ') accounts: run eg 'ibc.ps1 start paper', or use the shortcuts."
}
Write-Host "Shortcuts: $($createdShortcuts ? ($createdShortcuts -join ', ') : 'none')"
$skipped = @(
    if (-not $hasDefaultConfig) { "IBC (TWS)/IBC (Gateway) need $(Join-Path $ConfigFolder 'config.ini')" }
    if (-not $hasGateway) { "Gateway shortcuts need an IB Gateway installation in $(Join-Path $TwsPath 'ibgateway')" })
if ($skipped) { Write-Host "    (not created: $($skipped -join '; '))" }
if ($removedShortcuts) {
    Write-Host "Removed shortcuts that no longer apply: $($removedShortcuts -join ', ')"
}
if ($seeded) {
    Write-Host 'Created these TWS settings folders as copies of your existing settings (without logs):'
    $seeded | ForEach-Object { Write-Host "    $_" }
}
if ($created) {
    Write-Host 'Created these config files. Fill in IbLoginId and IbPassword in each:'
    $created | ForEach-Object { Write-Host "    $_" }
}
if ($updated) {
    Write-Host 'Added a TwsSettingsPath line to these existing config files:'
    $updated | ForEach-Object { Write-Host "    $_" }
}
if ($kept) {
    Write-Host 'Kept your existing copy of (use -OverwriteSettings to replace it):'
    $kept | ForEach-Object { Write-Host "    $_" }
}
if ($replaced) {
    Write-Host 'Replaced, with the previous copy saved as .bak:'
    $replaced | ForEach-Object { Write-Host "    $_" }
}
if ($obsolete) {
    Write-Warning "These files in $Destination aren't part of IBC $version (left in place; you can delete them):"
    $obsolete | ForEach-Object { Write-Host "    $_" }
}
