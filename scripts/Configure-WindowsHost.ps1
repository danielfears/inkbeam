#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ReceiverExecutable,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$MdnsExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$service = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue
if ($null -eq $service) {
    Push-Location (Split-Path -Parent $MdnsExecutable)
    try {
        & $MdnsExecutable -install
        if ($LASTEXITCODE -ne 0) {
            throw "mDNSResponder installation failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
    Start-Sleep -Seconds 1
    $service = Get-Service -Name 'Bonjour Service' -ErrorAction Stop
}

if ($service.Status -ne 'Running') {
    Start-Service -Name 'Bonjour Service'
}

$ruleGroup = 'InkBeam'
Get-NetFirewallRule -Name @(
    'iPadWhiteboardReceiver-TCP',
    'iPadWhiteboardReceiver-UDP',
    'iPadWhiteboardReceiver-mDNS'
) -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule
Get-NetFirewallRule -Group 'iPad Whiteboard Receiver' `
    -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule
Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule

$commonParameters = @{
    Group = $ruleGroup
    Direction = 'Inbound'
    Action = 'Allow'
    Enabled = 'True'
    Profile = @('Private', 'Domain', 'Public')
    RemoteAddress = 'LocalSubnet'
}

New-NetFirewallRule @commonParameters `
    -Name 'iPadWhiteboardReceiver-TCP' `
    -DisplayName 'InkBeam (TCP)' `
    -Program $ReceiverExecutable `
    -Protocol TCP `
    -LocalPort '7100-7102' | Out-Null

New-NetFirewallRule @commonParameters `
    -Name 'iPadWhiteboardReceiver-UDP' `
    -DisplayName 'InkBeam (UDP)' `
    -Program $ReceiverExecutable `
    -Protocol UDP `
    -LocalPort '7100-7102' | Out-Null

New-NetFirewallRule @commonParameters `
    -Name 'iPadWhiteboardReceiver-mDNS' `
    -DisplayName 'InkBeam (mDNS)' `
    -Program $MdnsExecutable `
    -Protocol UDP `
    -LocalPort 5353 | Out-Null

Write-Host 'Local discovery service and private/domain LAN firewall rules are ready.'
