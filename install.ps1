#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$ValidateOnly,
    [switch]$ManagedInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
$dataRoot = Join-Path $env:LOCALAPPDATA 'iPadWhiteboardReceiver'
$appRoot = Join-Path $dataRoot 'app'
$windowsPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$requiredFiles = @(
    'CHANGELOG.md',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'THIRD_PARTY_NOTICES.md',
    'VERSION',
    'WhiteboardReceiver.ps1',
    'install.ps1',
    'uninstall.ps1',
    'Install.cmd',
    'Uninstall.cmd',
    'scripts\Configure-WindowsHost.ps1',
    'scripts\Build-Release.ps1',
    'scripts\LaunchPowerShellHidden.vbs',
    'scripts\Remove-WindowsHost.ps1',
    'scripts\Start-ReceiverHost.ps1',
    'scripts\ReceiverHost.cs',
    'scripts\ReceiverSession.cs'
)
$desktopRelativePath = 'desktop\InkBeam.exe'

foreach ($relativePath in $requiredFiles) {
    $sourcePath = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Installation package is incomplete: $relativePath"
    }
}

$powerShellFiles = @(
    $requiredFiles |
        Where-Object { [IO.Path]::GetExtension($_) -eq '.ps1' }
)
foreach ($relativePath in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot $relativePath),
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw "$relativePath has a PowerShell parse error: $($errors[0].Message)"
    }
}

if ($ValidateOnly) {
    Write-Output "InkBeam $version source package is valid."
    return
}

$desktopSource = Join-Path $PSScriptRoot $desktopRelativePath
if (-not (Test-Path -LiteralPath $desktopSource -PathType Leaf)) {
    throw "Installation package is incomplete: $desktopRelativePath"
}
$requiredFiles += $desktopRelativePath

function Copy-AppFile {
    param([Parameter(Mandatory)][string]$RelativePath)

    $source = Join-Path $PSScriptRoot $RelativePath
    $destination = Join-Path $appRoot $RelativePath
    if ([string]::Equals(
            [IO.Path]::GetFullPath($source),
            [IO.Path]::GetFullPath($destination),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        return
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) `
        -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

foreach ($relativePath in $requiredFiles) {
    Copy-AppFile -RelativePath $relativePath
}

$controller = Join-Path $appRoot 'WhiteboardReceiver.ps1'
$controllerArguments = @(
    '-NoProfile'
    '-NonInteractive'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    ('"{0}"' -f $controller)
    'install'
    '-NoLaunch'
)
$controllerProcess = Start-Process `
    -FilePath $windowsPowerShell `
    -ArgumentList $controllerArguments `
    -PassThru
$controllerProcess.WaitForExit()
if ($controllerProcess.ExitCode -ne 0) {
    throw "Receiver installation failed with exit code $($controllerProcess.ExitCode)."
}

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object {
        [string]$_.CommandLine -like '*iPadWhiteboardWidget.ps1*'
    } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'iPadWhiteboardWidget') `
    -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $appRoot 'widget') `
    -Recurse -Force -ErrorAction SilentlyContinue
foreach ($shortcutPath in @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'InkBeam.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'InkBeam.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'iPad Whiteboard.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Startup')) 'iPad Whiteboard.lnk')
    )) {
    Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue
}

$desktopExecutable = Join-Path $appRoot $desktopRelativePath
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$preferenceKey = 'HKCU:\Software\InkBeam'
$preferenceConfigured = $null -ne (
    Get-ItemProperty -Path $preferenceKey `
        -Name 'StartAtSignInConfigured' -ErrorAction SilentlyContinue
)
$runConfigured = $null -ne (
    Get-ItemProperty -Path $runKey -Name 'InkBeam' `
        -ErrorAction SilentlyContinue
)
if (-not $preferenceConfigured -and -not $runConfigured) {
    New-Item -Path $runKey -Force | Out-Null
    New-ItemProperty -Path $runKey -Name 'InkBeam' `
        -Value ('"{0}" --background' -f $desktopExecutable) `
        -PropertyType String -Force | Out-Null
}

if (-not $ManagedInstaller) {
    $programs = [Environment]::GetFolderPath('Programs')
    $uninstallShortcut = Join-Path $programs 'Uninstall InkBeam.lnk'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($uninstallShortcut)
        try {
            $shortcut.TargetPath = Join-Path $appRoot 'Uninstall.cmd'
            $shortcut.WorkingDirectory = $appRoot
            $shortcut.IconLocation = "$env:SystemRoot\System32\control.exe,0"
            $shortcut.Description = 'Remove InkBeam'
            $shortcut.Save()
        }
        finally {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

if (-not $NoLaunch) {
    Start-Process -FilePath $desktopExecutable | Out-Null
}

Write-Host "InkBeam $version is installed." -ForegroundColor Green
