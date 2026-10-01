#Requires -Version 7

# Sends a STOP command to IBC to cause it to initiate a tidy closedown of TWS or Gateway.
# The IBC instance is specified in SendCommand.ps1. Any arguments are passed on
# to it, for example -Server 192.168.1.20

& (Join-Path $PSScriptRoot 'SendCommand.ps1') STOP @args
exit $LASTEXITCODE
