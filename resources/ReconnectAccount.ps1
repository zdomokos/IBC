#Requires -Version 7

# Sends a RECONNECTACCOUNT command to IBC to cause TWS or Gateway to reconnect to IB's account server.
# The IBC instance is specified in SendCommand.ps1. Any arguments are passed on
# to it, for example -Server 192.168.1.20

& (Join-Path $PSScriptRoot 'SendCommand.ps1') RECONNECTACCOUNT @args
exit $LASTEXITCODE
