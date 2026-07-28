#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installRoot = Join-Path $env:LOCALAPPDATA 'iPadWhiteboardWidget'
$widgetSource = Join-Path $PSScriptRoot 'iPadWhiteboardWidget.ps1'
$launcherSource = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'scripts\LaunchPowerShellHidden.vbs'
foreach ($path in @($widgetSource, $launcherSource)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Widget package is incomplete: $path"
    }
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
$launcher = Join-Path $installRoot 'LaunchPowerShellHidden.vbs'
Copy-Item -LiteralPath $launcherSource -Destination $launcher -Force

$powerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$arguments = '"{0}" "{1}" "{2}"' -f $launcher, $powerShell, $widgetSource
$runtimeManifest = Join-Path $env:LOCALAPPDATA `
    'iPadWhiteboardReceiver\runtime-current.json'
$iconLocation = "$env:SystemRoot\System32\DisplaySwitch.exe,0"
if (Test-Path -LiteralPath $runtimeManifest -PathType Leaf) {
    $runtime = Get-Content -LiteralPath $runtimeManifest -Raw |
        ConvertFrom-Json
    if (Test-Path -LiteralPath $runtime.executable -PathType Leaf) {
        $iconLocation = "$($runtime.executable),0"
    }
}

$shell = New-Object -ComObject WScript.Shell
try {
    foreach ($legacyShortcut in @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) `
                'iPad Whiteboard.lnk'),
            (Join-Path ([Environment]::GetFolderPath('Startup')) `
                'iPad Whiteboard.lnk')
        )) {
        Remove-Item -LiteralPath $legacyShortcut -Force `
            -ErrorAction SilentlyContinue
    }
    foreach ($shortcutPath in @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) `
                'InkBeam.lnk'),
            (Join-Path ([Environment]::GetFolderPath('Startup')) `
                'InkBeam.lnk')
        )) {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        try {
            $shortcut.TargetPath = $wscript
            $shortcut.Arguments = $arguments
            $shortcut.WorkingDirectory = $PSScriptRoot
            $shortcut.IconLocation = $iconLocation
            $shortcut.Description = 'Control local iPad mirroring with InkBeam'
            $shortcut.Save()
        }
        finally {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $shortcut
            )
        }
    }
}
finally {
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}

Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -eq 'powershell.exe' -and
        $_.CommandLine -like '*iPadWhiteboardWidget.ps1*' -and
        $_.CommandLine -notlike '*-ValidateOnly*'
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

if (-not $NoLaunch) {
    Start-Process -FilePath $wscript -ArgumentList $arguments
}
