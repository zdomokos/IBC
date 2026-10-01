#Requires -Version 7

# Sends a RECONNECTDATA command to IBC to cause TWS or Gateway to reconnect to IB's market data servers.
# The IBC instance is specified in SendCommand.ps1. Any arguments are passed on
# to it, for example -Server 192.168.1.20

& (Join-Path $PSScriptRoot 'SendCommand.ps1') RECONNECTDATA @args
exit $LASTEXITCODE
