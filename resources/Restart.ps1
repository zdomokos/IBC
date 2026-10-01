#Requires -Version 7

# Sends a RESTART command to IBC to cause it to restart TWS or Gateway without needing to authenticate again.
# The IBC instance is specified in SendCommand.ps1. Any arguments are passed on
# to it, for example -Server 192.168.1.20

& (Join-Path $PSScriptRoot 'SendCommand.ps1') RESTART @args
exit $LASTEXITCODE
