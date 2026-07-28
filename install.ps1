#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$ValidateOnly
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
    'widget\iPadWhiteboardWidget.ps1',
    'widget\install.ps1'
)

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
    Write-Output "InkBeam $version package is valid."
    return
}

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
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    ('"{0}"' -f $controller)
    'install'
)
$controllerProcess = Start-Process `
    -FilePath $windowsPowerShell `
    -ArgumentList $controllerArguments `
    -PassThru
$controllerProcess.WaitForExit()
if ($controllerProcess.ExitCode -ne 0) {
    throw "Receiver installation failed with exit code $($controllerProcess.ExitCode)."
}

$widgetInstaller = Join-Path $appRoot 'widget\install.ps1'
& $widgetInstaller -NoLaunch:$NoLaunch

$programs = [Environment]::GetFolderPath('Programs')
$uninstallShortcut = Join-Path $programs 'Uninstall InkBeam.lnk'
$shell = New-Object -ComObject WScript.Shell
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
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}

if ($NoLaunch) {
    $stopArguments = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"{0}"' -f $controller)
        'stop'
    )
    $stopProcess = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList $stopArguments `
        -PassThru
    $stopProcess.WaitForExit()
    if ($stopProcess.ExitCode -ne 0) {
        throw "Receiver stop failed with exit code $($stopProcess.ExitCode)."
    }
}

Write-Host "InkBeam $version is installed." -ForegroundColor Green
