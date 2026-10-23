#Requires -Version 5.1

# Starts the packaged receiver through the same controller path as the Enable
# button and requires it to listen for AirPlay. Static checks cannot prove that
# every library and plugin actually loads, so this is the final release gate.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Archive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'This test starts a receiver and rewrites its settings, so it only runs on GitHub Actions.'
}

$workRoot = Join-Path $env:RUNNER_TEMP 'receiver-smoke'
if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $workRoot | Out-Null
$archivePath = (Resolve-Path -LiteralPath $Archive).ProviderPath

# The controller derives every install path from LOCALAPPDATA.
$env:LOCALAPPDATA = Join-Path $workRoot 'local'
. (Join-Path $PSScriptRoot '..\WhiteboardReceiver.ps1')

Expand-Archive -LiteralPath $archivePath -DestinationPath $Script:RuntimeRoot
Assert-RuntimeBundle -Root $Script:RuntimeRoot
Install-ReceiverLauncher

# A user's machine has none of the build tools on PATH.
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"

function Write-ReceiverConsole {
    $outputPath = Join-Path $workRoot 'receiver-output.txt'
    $errorPath = Join-Path $workRoot 'receiver-error.txt'
    $process = Start-Process `
        -FilePath $Script:ExecutablePath `
        -WorkingDirectory $Script:RuntimeRoot `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $outputPath `
        -RedirectStandardError $errorPath
    try {
        [void]$process.WaitForExit(15000)
        if ($process.HasExited) {
            Write-Host "Direct launch exited with code $($process.ExitCode)."
        }
        else {
            Write-Host 'Direct launch is still running after 15 seconds.'
        }
        foreach ($path in @($outputPath, $errorPath)) {
            if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 0) {
                Write-Host "--- $(Split-Path -Leaf $path)"
                Get-Content -LiteralPath $path -TotalCount 40 | ForEach-Object { Write-Host $_ }
            }
        }
    }
    finally {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force
        }
    }
}

try {
    foreach ($attempt in 1..2) {
        try {
            # The first start also builds the GStreamer plugin registry, which can
            # outlast the controller's start-up window on a cold runner.
            Start-Receiver
            break
        }
        catch {
            Write-Warning "Start attempt $attempt failed: $($_.Exception.Message)"
            if ($attempt -eq 2) {
                Write-ReceiverConsole
                throw
            }
        }
    }

    $state = Get-ReceiverHostState
    if ($null -eq $state -or $state.state -notin @('Ready', 'Pairing', 'Casting')) {
        throw 'The receiver stopped reporting a ready state after it started.'
    }
    Write-Host "Receiver state: $($state.state)"
}
finally {
    try {
        Stop-Receiver
    }
    catch {
        Write-Warning "Stopping the receiver failed: $($_.Exception.Message)"
    }
}
