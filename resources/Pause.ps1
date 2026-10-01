#Requires -Version 7

# Sends a PAUSE command to IBC to cause it to shut down TWS or Gateway in such
# a way that when restarted, the session will continue without requiring
# re-authentication.
# The IBC instance is specified in SendCommand.ps1. Any arguments are passed on
# to it, for example -Server 192.168.1.20

& (Join-Path $PSScriptRoot 'SendCommand.ps1') PAUSE @args
exit $LASTEXITCODE
