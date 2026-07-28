#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$KeepSettings,
    [switch]$RemoveBonjour
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dataRoot = Join-Path $env:LOCALAPPDATA 'iPadWhiteboardReceiver'
$widgetRoot = Join-Path $env:LOCALAPPDATA 'iPadWhiteboardWidget'
$manifestPath = Join-Path $dataRoot 'runtime-current.json'
$windowsPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$runtime = $null

if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $runtime = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (Test-Path -LiteralPath $runtime.executable -PathType Leaf) {
        $expectedPath = [IO.Path]::GetFullPath([string]$runtime.executable)
        Get-Process -Name 'uxplay-windows' -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    [string]::Equals(
                        [IO.Path]::GetFullPath($_.Path),
                        $expectedPath,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
                catch {
                    $false
                }
            } |
            Stop-Process -Force
    }
}

$managedCommandPatterns = @(
    '*iPadWhiteboardWidget.ps1*',
    '*Start-ReceiverHost.ps1*'
)
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object {
        $commandLine = [string]$_.CommandLine
        @($managedCommandPatterns | Where-Object {
                $commandLine -like $_
            }).Count -gt 0
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

$removeHostScript = Join-Path $PSScriptRoot 'scripts\Remove-WindowsHost.ps1'
if (Test-Path -LiteralPath $removeHostScript -PathType Leaf) {
    $removeArguments = @(
        '-NoProfile'
        '-WindowStyle'
        'Hidden'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"{0}"' -f $removeHostScript)
    )
    if ($RemoveBonjour) {
        $removeArguments += '-RemoveBonjour'
        if ($null -ne $runtime -and
            $null -ne $runtime.PSObject.Properties['mdnsExecutable']) {
            $removeArguments += @(
                '-MdnsExecutable'
                ('"{0}"' -f [string]$runtime.mdnsExecutable)
            )
        }
    }
    $removeProcess = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList $removeArguments `
        -Verb RunAs `
        -PassThru `
        -Wait
    if ($removeProcess.ExitCode -ne 0) {
        throw "Windows host cleanup failed with exit code $($removeProcess.ExitCode)."
    }
}

$desktop = [Environment]::GetFolderPath('Desktop')
$startup = [Environment]::GetFolderPath('Startup')
$programs = [Environment]::GetFolderPath('Programs')
foreach ($shortcutPath in @(
        (Join-Path $desktop 'iPad Whiteboard.lnk'),
        (Join-Path $desktop 'InkBeam.lnk'),
        (Join-Path $startup 'iPad Whiteboard.lnk'),
        (Join-Path $startup 'InkBeam.lnk'),
        (Join-Path $programs 'iPad Whiteboard Receiver.lnk'),
        (Join-Path $programs 'InkBeam Receiver.lnk'),
        (Join-Path $programs 'Uninstall iPad Whiteboard Receiver.lnk'),
        (Join-Path $programs 'Uninstall InkBeam.lnk')
    )) {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
}

if ($KeepSettings) {
    foreach ($path in @(
            (Join-Path $dataRoot 'app'),
            (Join-Path $dataRoot 'runtime'),
            (Join-Path $dataRoot 'downloads'),
            (Join-Path $dataRoot 'Start-ReceiverHost.ps1'),
            $widgetRoot
        )) {
        Remove-Item -LiteralPath $path -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}
else {
    Remove-Item -LiteralPath $widgetRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dataRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (
        Join-Path $env:APPDATA 'leapbtw\uxplay-windows\arguments.txt'
    ) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'HKCU:\Software\leapbtw\uxplay-windows' `
        -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'InkBeam has been removed.' -ForegroundColor Green
