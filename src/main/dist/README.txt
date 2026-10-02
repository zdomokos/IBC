IBC
===

IBC runs Interactive Brokers' Trader Workstation (TWS) or IB Gateway without
anyone at the keyboard: it logs in for you, deals with the dialogs TWS shows,
restarts TWS daily without logging in again, and accepts commands such as
STOP and RESTART.

IBC only works with the OFFLINE (standalone) TWS/Gateway installer, not the
self-updating TWS. This version runs on Windows.


Getting started
---------------

1. Install the offline TWS or Gateway, and run it once by hand to check that
   you can log in. Install PowerShell 7 if you don't have it:

     winget install Microsoft.PowerShell

2. Copy config.ini from this folder to %USERPROFILE%\Documents\IBC\ (ideally
   an encrypted folder) and set IbLoginId and IbPassword in it. Every
   setting is described in the file.

   For several accounts, name the files config-<account>.ini instead, eg
   config-live.ini and config-paper.ini, each with its own TwsSettingsPath,
   OverrideTwsApiPort and CommandServerPort (see the user guide).

3. Start TWS:

     .\ibc.ps1 start               TWS, with config.ini
     .\ibc.ps1 start paper         TWS, with config-paper.ini
     .\ibc.ps1 start -Gateway      IB Gateway instead of TWS

   or use the 'IBC (TWS)' and 'IBC (Gateway)' shortcuts. ibc.ps1 finds the
   newest TWS in C:\Jts and its existing settings by itself; the launcher
   settings at the top of config.ini change that if needed.

If Windows blocks the script because it came from the internet, run this once
in PowerShell:

     Get-ChildItem C:\IBC -Recurse | Unblock-File

Each run writes a diagnostic log; IBC's window shows where.


Sending commands
----------------

Set CommandServerPort in the config file (eg 7462) and restart IBC, then:

     .\ibc.ps1 stop [<account>]   (or restart, pause, enableapi,
                                   reconnectdata, reconnectaccount)
     .\ibc.ps1 help               (all commands and options)
     .\ibc.ps1 version


What's in this folder
---------------------

     ibc.ps1                             starts TWS/Gateway and sends commands
     config.ini                          sample configuration file, with every
                                           setting described
     IBC.jar                             the IBC program
     IBC (TWS).lnk, IBC (Gateway).lnk    shortcuts that run 'ibc.ps1 start'
     Start TWS (autorestart).xml         sample Task Scheduler task
     LICENSE.txt                         GNU General Public License v3


More information
----------------

The user guide covers installation, every setting, auto-restart, running
several TWS instances, scheduled tasks and the command server in detail:

     https://github.com/zdomokos/IBC/blob/master/docs/userguide.md

Source code, documentation and releases:

     https://github.com/zdomokos/IBC

This is a fork of IBC (https://github.com/IbcAlpha/IBC), which was retired
in September 2026. Settings and scripts differ from upstream IBC, so use this
fork's documentation rather than upstream's.
