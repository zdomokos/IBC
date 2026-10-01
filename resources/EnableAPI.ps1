#Requires -Version 7

# Sends a ENABLEAPI command to IBC to cause it to enable the TWS API (TWS only).
# The IBC instance is specified in SendCommand.ps1. Any arguments are passed on
# to it, for example -Server 192.168.1.20

& (Join-Path $PSScriptRoot 'SendCommand.ps1') ENABLEAPI @args
exit $LASTEXITCODE
