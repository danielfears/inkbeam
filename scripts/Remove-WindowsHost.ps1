#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$RemoveBonjour,
    [string]$MdnsExecutable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Get-NetFirewallRule -Name 'iPadWhiteboardReceiver-*' `
    -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule

if ($RemoveBonjour -and
    -not [string]::IsNullOrWhiteSpace($MdnsExecutable) -and
    (Test-Path -LiteralPath $MdnsExecutable -PathType Leaf)) {
    & $MdnsExecutable -remove
    if ($LASTEXITCODE -ne 0) {
        throw "Bonjour service removal failed with exit code $LASTEXITCODE."
    }
}
