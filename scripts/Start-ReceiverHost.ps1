#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ReceiverExecutable,
    [string]$WorkingDirectory,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path @(
    (Join-Path $PSScriptRoot 'ReceiverSession.cs'),
    (Join-Path $PSScriptRoot 'ReceiverHost.cs')
) -ReferencedAssemblies System.dll, System.Core.dll, System.Web.Extensions.dll

if ($SelfTest) {
    $session = [IpadWhiteboard.ReceiverSession]::new()
    $session.ProcessLine(
        '*** CLIENT MUST NOW ENTER PIN = "0123" AS AIRPLAY PASSWORD',
        [DateTime]::UtcNow
    )
    if ($session.Snapshot().pin -ne '0123') {
        throw 'Receiver state self-test failed.'
    }
    $session.ProcessLine('Client authentication success', [DateTime]::UtcNow)
    if ($null -ne $session.Snapshot().pin) {
        throw 'Receiver state did not clear the accepted PIN.'
    }
    Write-Output 'Receiver state self-test passed.'
    return
}

if (-not (Test-Path -LiteralPath $ReceiverExecutable -PathType Leaf)) {
    throw "Receiver executable not found: $ReceiverExecutable"
}
if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    throw "Receiver working directory not found: $WorkingDirectory"
}

$createdNew = $false
$mutex = [Threading.Mutex]::new(
    $true, 'Local\iPadWhiteboardReceiverHost', [ref]$createdNew
)
if (-not $createdNew) {
    $mutex.Dispose()
    return
}

$receiverHost = [IpadWhiteboard.ReceiverHost]::new(
    $ReceiverExecutable, $WorkingDirectory
)
try {
    exit $receiverHost.Run()
}
finally {
    $receiverHost.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
