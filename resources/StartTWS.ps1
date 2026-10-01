#Requires -Version 7

#==============================================================================+
#                                                                              +
#   Starts Interactive Brokers' Trader Workstation (TWS).                      +
#                                                                              +
#   If you run it without any arguments it opens a new window showing useful   +
#   information and then starts TWS. If you supply -Inline, the information    +
#   is displayed in the current window instead. (If you are using Task         +
#   Scheduler to run this, you MUST supply -Inline.)                           +
#                                                                              +
#   The settings below are the only lines you may need to change, and you      +
#   probably only need to change the first one. The notes at the end of this   +
#   file explain them.                                                         +
#                                                                              +
#==============================================================================+

param([switch]$Inline, [switch]$InWindow)

$Settings = @{
    TwsMajorVersion = '1045'
    Config          = "$env:USERPROFILE\Documents\IBC\config.ini"
    TradingMode     = ''
    On2FATimeout    = 'exit'
    IbcPath         = "$env:SystemDrive\IBC"
    TwsPath         = "$env:SystemDrive\Jts"
    TwsSettingsPath = ''
    LogPath         = "$env:SystemDrive\IBC\Logs"
    UserId          = ''
    Password        = ''
    JavaPath        = ''
    Hide            = $false
}


#              PLEASE DON'T CHANGE ANYTHING BELOW THIS LINE !!
#==============================================================================

& (Join-Path $Settings.IbcPath 'scripts\StartIBC.ps1') @Settings -Inline:$Inline -InWindow:$InWindow
exit $LASTEXITCODE


<#   Notes:

TwsMajorVersion

    Specifies the major version number of TWS to be run. If you are unsure of
    which version number to use, run TWS manually from the icon on the desktop,
    then click Help > About Trader Workstation. In the displayed information
    you'll see a line similar to this:

      Build 10.45.1g, May 27, 2026 4:00:50 PM

    The major version number is 1045 (ie ignore the period after the first part
    of the version number).

    Do not include the rest of the version number in this setting.


Config

    This is the location and filename of the IBC configuration file. This file
    should be in a folder in your personal filestore, so that other users of
    your computer can't access it. This folder and its contents should also be
    encrypted so that even users with administrator privileges can't see the
    contents. Note that you can use $env:USERPROFILE to address the root of
    your personal filestore (it is set automatically by Windows).


TradingMode

    This indicates whether the live account or the paper trading account
    corresponding to the supplied credentials is to be used. The values allowed
    here are 'live' and 'paper' (not case-sensitive). If no value is specified
    here, the value is taken from the TradingMode setting in the configuration
    file.

    If this is set to 'live', then the credentials for the live account must be
    supplied. If it is set to 'paper', then either the live or the
    paper-trading credentials may be supplied.


On2FATimeout

    If you use the IBKR Mobile app for second factor authentication, and after
    you acknowledge the alert login fails to proceed, this setting determines
    what action will occur. If you set it to 'restart', IBC will be
    automatically restarted and the authentication sequence will be repeated,
    giving you another opportunity to complete the login. If you set it to
    'exit', IBC will simply terminate.

    Note that if you have another automated mechanism (such as Task Scheduler)
    to periodically restart IBC, you should set this to 'exit'.

    Note also that if you set this to 'restart', you must also set
    ReloginAfterSecondFactorAuthenticationTimeout=yes in your config.ini file.


IbcPath

    The folder containing the IBC files.


TwsPath

    The folder where TWS is installed. The TWS installer always installs to
    C:\Jts. Note that even if you have installed from a Gateway download rather
    than a TWS download, you should still use this default setting. It is
    possible to move the TWS installation to a different folder, but there are
    virtually no good reasons for doing so.


TwsSettingsPath

    The folder where TWS is to store its settings. By default it uses the
    folder specified in TwsPath.

    It is also possible to specify this folder via the IbDir setting in the
    configuration file. If TWS is set to auto-restart each day (ie without
    having to log in again each time), then you must specify the settings
    folder here rather than via IbDir: this means that these two settings must
    either be identical, or the IbDir setting must be left unset. If they are
    different, auto-restart will fail.

    The recommended approach is to NOT use the IbDir setting in the
    configuration file.

    Note that if multiple IB accounts are used such as live and paper accounts
    for the same user, or accounts for different users, then they should either
    each have a unique settings folder, or autorestart must be configured to
    occur at a different time for each account: concurrent auto-restarts may
    interfere and not succeed. You could achieve this, for example, by having
    different versions of this file for different users.


LogPath

    Specifies the folder where diagnostic information is to be logged while
    this script is running. This information is very valuable when
    troubleshooting problems, so it is advisable to always have this set to a
    valid location, especially when setting up IBC. You must have write access
    to the specified folder.

    If the value is set to 'CON', log information is sent to the IBC window.

    If the value is empty, no log information is captured at all (but this is
    not recommended).


UserId
Password

    If your IBKR user id and password are not included in your IBC
    configuration file, you can set them here. However you are strongly advised
    not to set them here because this file is not normally in a protected
    location.


JavaPath

    IB's installer for TWS/Gateway includes a hidden version of Java which IB
    have used to develop and test that particular version. This means that it
    is not necessary to separately install Java. If there is a separate Java
    installation, that does not matter: it won't be used by IBC or TWS/Gateway
    unless you set the path to the folder containing java.exe here. You should
    not do this without a very good reason.


Hide

    If set to $true, the window that contains information about the running
    TWS, and where to find the log file, will be minimized to the taskbar.
    (Note that when -Inline is supplied, this setting has no effect.)

#>
