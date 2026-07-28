#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'dist'
}
$version = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') `
    -Raw).Trim()
$name = "InkBeam-v$version"
$stagingParent = Join-Path $env:TEMP `
    "InkBeamRelease-$([guid]::NewGuid().ToString('N'))"
$stagingRoot = Join-Path $stagingParent $name

$paths = @(
    '.gitattributes',
    'CHANGELOG.md',
    'Install.cmd',
    'LICENSE',
    'README.md',
    'SECURITY.md',
    'THIRD_PARTY_NOTICES.md',
    'Uninstall.cmd',
    'VERSION',
    'WhiteboardReceiver.ps1',
    'inkbeam',
    'install.ps1',
    'uninstall.ps1',
    'whiteboard',
    'scripts\Configure-WindowsHost.ps1',
    'scripts\Build-Release.ps1',
    'scripts\LaunchPowerShellHidden.vbs',
    'scripts\Remove-WindowsHost.ps1',
    'scripts\Start-ReceiverHost.ps1',
    'widget'
)

try {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    foreach ($relativePath in $paths) {
        $source = Join-Path $projectRoot $relativePath
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Release input is missing: $relativePath"
        }
        $destination = Join-Path $stagingRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) `
            -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $archive = Join-Path $OutputDirectory "$name.zip"
    $checksum = "$archive.sha256"
    Remove-Item -LiteralPath $archive, $checksum -Force `
        -ErrorAction SilentlyContinue
    Compress-Archive -LiteralPath $stagingRoot -DestinationPath $archive
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.
        ToLowerInvariant()
    "$hash *$name.zip" | Set-Content -LiteralPath $checksum -Encoding Ascii

    Write-Output $archive
    Write-Output $checksum
}
finally {
    Remove-Item -LiteralPath $stagingParent -Recurse -Force `
        -ErrorAction SilentlyContinue
}
