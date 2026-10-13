#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $projectRoot 'dist'
}
$version = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION must contain a three-part semantic version: $version"
}

$desktopProject = Join-Path $projectRoot 'desktop\src\InkBeam\InkBeam.csproj'
$desktopIcon = Join-Path $projectRoot 'desktop\src\InkBeam\Assets\InkBeam.ico'
foreach ($path in @($desktopProject, $desktopIcon)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release input is missing: $path"
    }
}

$payloadPaths = @(
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
    'scripts\Remove-WindowsHost.ps1',
    'scripts\Start-ReceiverHost.ps1',
    'scripts\ReceiverHost.cs',
    'scripts\ReceiverSession.cs'
)

function Copy-Payload {
    param([Parameter(Mandatory)][string]$Destination)

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($relativePath in $payloadPaths) {
        $source = Join-Path $projectRoot $relativePath
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Release input is missing: $relativePath"
        }
        $target = Join-Path $Destination $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) `
            -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }
}

function Write-Checksum {
    param([Parameter(Mandatory)][string]$Path)

    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksum = "$Path.sha256"
    "$hash *$(Split-Path -Leaf $Path)" |
        Set-Content -LiteralPath $checksum -Encoding Ascii
    return $checksum
}

$temporaryRoot = Join-Path $env:TEMP "InkBeamRelease-$([guid]::NewGuid().ToString('N'))"
try {
    $publishRoot = Join-Path $temporaryRoot 'publish'
    $published = @{}
    foreach ($runtime in @('win-x64', 'win-arm64')) {
        $destination = Join-Path $publishRoot $runtime
        & dotnet publish $desktopProject `
            -c Release `
            -r $runtime `
            --self-contained true `
            -p:Version=$version `
            -p:PublishSingleFile=true `
            -p:PublishTrimmed=false `
            -p:DebugType=embedded `
            -o $destination
        if ($LASTEXITCODE -ne 0) {
            throw "InkBeam desktop publish failed for $runtime with exit code $LASTEXITCODE."
        }
        $executable = Join-Path $destination 'InkBeam.exe'
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "Published application was not produced for $runtime."
        }
        $published[$runtime] = $executable
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $artifacts = [Collections.Generic.List[string]]::new()
    foreach ($runtime in @('win-x64', 'win-arm64')) {
        $name = "InkBeam-v$version-$runtime"
        $stageParent = Join-Path $temporaryRoot $name
        $stage = Join-Path $stageParent $name
        Copy-Payload -Destination $stage
        $desktopDestination = Join-Path $stage 'desktop'
        New-Item -ItemType Directory -Path $desktopDestination -Force | Out-Null
        Copy-Item -LiteralPath $published[$runtime] `
            -Destination (Join-Path $desktopDestination 'InkBeam.exe') -Force

        $archive = Join-Path $OutputDirectory "$name.zip"
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        Compress-Archive -LiteralPath $stage -DestinationPath $archive
        $artifacts.Add($archive)
        $artifacts.Add((Write-Checksum -Path $archive))
    }

    if (-not $SkipInstaller) {
        $universalStage = Join-Path $temporaryRoot 'installer-payload'
        Copy-Payload -Destination $universalStage
        $desktopStage = Join-Path $universalStage 'desktop'
        New-Item -ItemType Directory -Path $desktopStage -Force | Out-Null
        Copy-Item -LiteralPath $desktopIcon `
            -Destination (Join-Path $desktopStage 'InkBeam.ico') -Force
        foreach ($runtime in @('win-x64', 'win-arm64')) {
            $binaryDirectory = Join-Path $desktopStage "bin\$runtime"
            New-Item -ItemType Directory -Path $binaryDirectory -Force | Out-Null
            Copy-Item -LiteralPath $published[$runtime] `
                -Destination (Join-Path $binaryDirectory 'InkBeam.exe') -Force
        }

        $compilerCandidates = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
        )
        $compiler = @($compilerCandidates |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1)
        if ($compiler.Count -eq 0) {
            throw 'Inno Setup 6 is required to compose the installer. Install it with: winget install JRSoftware.InnoSetup'
        }
        $installerScript = Join-Path $projectRoot 'installer\InkBeam.iss'
        & $compiler[0] `
            "/DSourceRoot=$universalStage" `
            "/DBuildOutput=$OutputDirectory" `
            "/DAppVersion=$version" `
            $installerScript
        if ($LASTEXITCODE -ne 0) {
            throw "Inno Setup failed with exit code $LASTEXITCODE."
        }
        $installer = Join-Path $OutputDirectory "InkBeam-Setup-v$version.exe"
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
            throw 'The Windows installer was not produced.'
        }
        $artifacts.Add($installer)
        $artifacts.Add((Write-Checksum -Path $installer))
    }

    $artifacts
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
