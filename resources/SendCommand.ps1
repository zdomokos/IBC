#Requires -Version 7

<#
.SYNOPSIS
Sends a command to a running instance of IBC, for example to cause it to
initiate a tidy closedown or restart of TWS or Gateway.

.DESCRIPTION
Connects to IBC's command server, sends the command and displays IBC's reply.
The exit code is 0 if IBC accepted the command, 1 if it rejected it and 2 if
IBC couldn't be reached or didn't reply.

IBC only accepts commands if the CommandServerPort setting in config.ini is
non-zero, and only from the addresses listed in its ControlFrom setting (the
local computer is always allowed).

.EXAMPLE
./SendCommand.ps1 STOP

.EXAMPLE
./SendCommand.ps1 RESTART -Server 192.168.1.20
#>

param(
    # The command to send (not case-sensitive)
    [Parameter(Mandatory)]
    [ValidateSet('STOP', 'RESTART', 'PAUSE', 'ENABLEAPI', 'RECONNECTDATA', 'RECONNECTACCOUNT')]
    [string]$Command,

    # You may need to change this line. Set it to the name or IP address of the
    # computer that is running IBC.
    [string]$Server = '127.0.0.1',

    # You may need to change this line. Make sure it's set to the value of the
    # CommandServerPort setting in config.ini.
    [int]$Port = 7462,

    # How long to wait for IBC's reply
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$client = [System.Net.Sockets.TcpClient]::new()
try {
    try {
        if (-not $client.ConnectAsync($Server, $Port).Wait([timespan]::FromSeconds(10))) {
            throw "timed out"
        }
    } catch {
        Write-Error "Can't connect to IBC at ${Server}:$Port ($($_.Exception.GetBaseException().Message)). Check that IBC is running and that CommandServerPort is set in config.ini." -ErrorAction Continue
        exit 2
    }

    $client.ReceiveTimeout = $TimeoutSeconds * 1000
    $stream = $client.GetStream()
    $reader = [System.IO.StreamReader]::new($stream)
    $writer = [System.IO.StreamWriter]::new($stream)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true

    # send the command, then wait for the OK or ERROR reply. IBC may send INFO lines
    # first, and lines may start with the CommandPrompt text if one is configured
    $writer.WriteLine($Command.ToUpperInvariant())
    $result = 2
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            Write-Output $line
            if ($line -match '\bOK\b') { $result = 0; break }
            if ($line -match '\bERROR\b') { $result = 1; break }
        }
    } catch [System.IO.IOException] {
        # read timed out, or IBC closed the connection while shutting down
    }
    if ($result -eq 2) {
        Write-Error "No reply from IBC to $Command" -ErrorAction Continue
    }

    # end the session tidily (IBC may already have closed it for STOP)
    try {
        $writer.WriteLine('EXIT')
        $client.ReceiveTimeout = 2000
        $null = $reader.ReadLine()
    } catch {
    }

    exit $result
} finally {
    $client.Dispose()
}
