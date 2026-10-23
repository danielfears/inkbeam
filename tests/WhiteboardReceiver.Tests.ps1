$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '..\WhiteboardReceiver.ps1')

$script:Failures = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Condition) {
        Write-Host "[PASS] $Message"
    }
    else {
        $script:Failures++
        Write-Host "[FAIL] $Message"
    }
}

function Assert-Matches {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message
    )

    Assert-True -Condition ([bool]($Value -match $Pattern)) -Message $Message
}

$parseTargets = @(
    (Join-Path $PSScriptRoot '..\WhiteboardReceiver.ps1'),
    (Join-Path $PSScriptRoot '..\scripts\Configure-WindowsHost.ps1'),
    (Join-Path $PSScriptRoot '..\scripts\Start-ReceiverHost.ps1'),
    (Join-Path $PSScriptRoot 'ReceiverRuntime.Smoke.ps1'),
    $PSCommandPath
)
foreach ($target in $parseTargets) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $target,
        [ref]$tokens,
        [ref]$errors
    )
    Assert-True -Condition ($errors.Count -eq 0) -Message "$(Split-Path -Leaf $target) parses cleanly"
}
Assert-True `
    -Condition ($null -ne (Get-Command Install-ReceiverLauncher -ErrorAction SilentlyContinue)) `
    -Message 'Receiver launcher installer is available at script scope'
Assert-True `
    -Condition ($null -ne (Get-Command Test-WindowsHostConfiguration -ErrorAction SilentlyContinue)) `
    -Message 'Windows host configuration check is available at script scope'
$encodingTestPath = Join-Path $env:TEMP `
    "iPadWhiteboardEncoding-$([guid]::NewGuid().ToString('N')).txt"
try {
    Write-Utf8NoBomFile -Path $encodingTestPath -Content 'test'
    $encodingBytes = [IO.File]::ReadAllBytes($encodingTestPath)
    $hasUtf8Bom = $encodingBytes.Length -ge 3 -and
        $encodingBytes[0] -eq 0xEF -and
        $encodingBytes[1] -eq 0xBB -and
        $encodingBytes[2] -eq 0xBF
    Assert-True `
        -Condition (-not $hasUtf8Bom) `
        -Message 'UxPlay arguments are written without a UTF-8 BOM'
}
finally {
    Remove-Item -LiteralPath $encodingTestPath -Force -ErrorAction SilentlyContinue
}
$pinHostSelfTest = @(
    & (Join-Path $PSScriptRoot '..\scripts\Start-ReceiverHost.ps1') -SelfTest
) -join "`n"
Assert-Matches `
    -Value $pinHostSelfTest `
    -Pattern 'Receiver state self-test passed' `
    -Message 'Receiver host consumes authoritative PIN events and clears accepted PINs'

$configuration = Get-DefaultConfiguration
Assert-True -Condition ($configuration.receiverName -eq 'InkBeam') -Message 'Default AirPlay name uses InkBeam branding'
Assert-True -Condition ($configuration.authentication -eq 'every-connection') -Message 'Default authentication requires every-connection approval'
Assert-True -Condition (-not $configuration.audioEnabled) -Message 'Audio is disabled by default'

$argumentLine = ConvertTo-UxPlayArguments -Configuration $configuration
Assert-Matches -Value $argumentLine -Pattern '(^| )-pw( |$)' -Message 'Secure arguments request a fresh PIN'
Assert-Matches -Value $argumentLine -Pattern '(^| )-as 0( |$)' -Message 'Secure arguments mute receiver audio'
Assert-Matches -Value $argumentLine -Pattern '(^| )-p 7100( |$)' -Message 'AirPlay ports are fixed for scoped firewall rules'
Assert-Matches -Value $argumentLine -Pattern '(^| )-key ' -Message 'Receiver identity uses a persistent local key'
Assert-True -Condition ($argumentLine -notmatch '(^| )-pin( |$)') -Message 'Every-connection mode does not silently trust returning clients'

$configuration.authentication = 'pair-once'
$pairedArguments = ConvertTo-UxPlayArguments -Configuration $configuration
Assert-Matches -Value $pairedArguments -Pattern '(^| )-pin( |$)' -Message 'Pair-once mode enables PIN pairing'
Assert-Matches -Value $pairedArguments -Pattern '(^| )-reg( |$)' -Message 'Pair-once mode stores a trusted-client register'

$configuration.authentication = 'open'
$openArguments = ConvertTo-UxPlayArguments -Configuration $configuration
Assert-True -Condition ($openArguments -notmatch '(^| )-(pw|pin)( |$)') -Message 'Open mode omits authentication arguments'

Assert-True -Condition (Test-ReceiverName -Name 'Workshop-Whiteboard') -Message 'Token-safe receiver names are accepted'
Assert-True -Condition (-not (Test-ReceiverName -Name 'Workshop Whiteboard')) -Message 'Names with whitespace are rejected for pinned parser compatibility'
Assert-True -Condition (-not (Test-ReceiverName -Name 'bad"name')) -Message 'Quoted receiver names are rejected'
Assert-True -Condition (-not (Test-ReceiverName -Name "bad`nname")) -Message 'Multiline receiver names are rejected'
Assert-True -Condition (-not (Test-ReceiverName -Name 'bad%name')) -Message 'Environment-variable markers are rejected'
Assert-True -Condition (-not (Test-ReceiverName -Name '-Workshop')) -Message 'Option-like receiver names are rejected'

$metadata = Get-RuntimeMetadata
Assert-True -Condition ($metadata.Version -eq '2.0.0.1736-authfix2') -Message 'Patched native runtime build is selected'
Assert-Matches `
    -Value $metadata.Uri `
    -Pattern '^https://github\.com/danielfears/inkbeam/releases/download/uxplay-2\.0\.0\.1736-authfix2/InkBeam-UxPlay-v2\.0\.0\.1736-authfix2-x64\.zip$' `
    -Message 'Patched runtime is downloaded from its immutable release asset'
Assert-Matches -Value $metadata.Sha256 -Pattern '^[a-f0-9]{64}$' -Message 'Pinned runtime has a SHA-256 checksum'
Assert-True -Condition ($metadata.Architecture -eq 'x64') -Message 'Tested x64 runtime is selected instead of the untested ARM64 release'
Assert-True -Condition ((Get-RequiredRuntimeFiles).Count -ge 10) -Message 'Runtime validation covers the application, codecs, and renderer'

function New-TestPeFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Imports = @(),
        [switch]$Pe32
    )

    $optionalSize = if ($Pe32) { 224 } else { 240 }
    $directoryOffset = if ($Pe32) { 96 } else { 112 }
    $sectionRva = 0x3000
    $sectionRaw = 0x400
    $descriptorBytes = 20 * ($Imports.Count + 1)

    $section = New-Object System.IO.MemoryStream
    $sectionWriter = New-Object System.IO.BinaryWriter($section)
    $nameCursor = $descriptorBytes
    foreach ($module in $Imports) {
        $sectionWriter.Write([uint32]0)
        $sectionWriter.Write([uint32]0)
        $sectionWriter.Write([uint32]0)
        $sectionWriter.Write([uint32]($sectionRva + $nameCursor))
        $sectionWriter.Write([uint32]0)
        $nameCursor += $module.Length + 1
    }
    $sectionWriter.Write((New-Object byte[] 20))
    foreach ($module in $Imports) {
        $sectionWriter.Write([System.Text.Encoding]::ASCII.GetBytes($module))
        $sectionWriter.Write([byte]0)
    }
    $sectionWriter.Flush()
    $sectionData = $section.ToArray()

    $dosHeader = New-Object byte[] 64
    $dosHeader[0] = 0x4D
    $dosHeader[1] = 0x5A
    [BitConverter]::GetBytes([uint32]0x80).CopyTo($dosHeader, 60)
    $optionalHeader = New-Object byte[] $optionalSize
    [BitConverter]::GetBytes([uint16]$(if ($Pe32) { 0x10B } else { 0x20B })).CopyTo($optionalHeader, 0)
    [BitConverter]::GetBytes([uint32]$sectionRva).CopyTo($optionalHeader, $directoryOffset + 8)
    [BitConverter]::GetBytes([uint32]$descriptorBytes).CopyTo($optionalHeader, $directoryOffset + 12)
    $sectionName = New-Object byte[] 8
    [System.Text.Encoding]::ASCII.GetBytes('.idata').CopyTo($sectionName, 0)

    $file = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($file)
    $writer.Write($dosHeader)
    $writer.Write((New-Object byte[] 64))
    $writer.Write([uint32]0x4550)
    $writer.Write([uint16]$(if ($Pe32) { 0x14C } else { 0x8664 }))
    $writer.Write([uint16]1)
    $writer.Write((New-Object byte[] 12))
    $writer.Write([uint16]$optionalSize)
    $writer.Write([uint16]0x2022)
    $writer.Write($optionalHeader)
    $writer.Write($sectionName)
    $writer.Write([uint32]$sectionData.Length)
    $writer.Write([uint32]$sectionRva)
    $writer.Write([uint32]$sectionData.Length)
    $writer.Write([uint32]$sectionRaw)
    $writer.Write((New-Object byte[] 16))
    $writer.Flush()
    while ($file.Length -lt $sectionRaw) {
        $writer.Write([byte]0)
    }
    $writer.Write($sectionData)
    $writer.Flush()

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $file.ToArray())
}

$peRoot = Join-Path ([System.IO.Path]::GetTempPath()) "inkbeam-pe-$([guid]::NewGuid().ToString('N'))"
try {
    $sample64 = Join-Path $peRoot 'sample64.dll'
    $sample32 = Join-Path $peRoot 'sample32.dll'
    New-TestPeFile -Path $sample64 -Imports @('KERNEL32.dll', 'libexample-1.dll')
    New-TestPeFile -Path $sample32 -Imports @('USER32.dll') -Pe32
    $imports64 = @(Get-PeImportedModules -Path $sample64)
    Assert-True `
        -Condition ($imports64.Count -eq 2 -and $imports64[0] -ceq 'KERNEL32.dll' -and $imports64[1] -ceq 'libexample-1.dll') `
        -Message 'A 64-bit binary import table is read in full'
    $imports32 = @(Get-PeImportedModules -Path $sample32)
    Assert-True `
        -Condition ($imports32.Count -eq 1 -and $imports32[0] -ceq 'USER32.dll') `
        -Message 'A 32-bit binary import table is read in full'

    $notPe = Join-Path $peRoot 'not-a-binary.dll'
    Set-Content -LiteralPath $notPe -Value ('text' * 40)
    $rejected = $false
    try { [void](Get-PeImportedModules -Path $notPe) } catch { $rejected = $true }
    Assert-True -Condition $rejected -Message 'A file that is not a Windows binary is rejected'

    $kernel32 = @(Get-PeImportedModules -Path (Join-Path $env:SystemRoot 'System32\kernel32.dll'))
    Assert-True `
        -Condition ($kernel32 -contains 'ntdll.dll') `
        -Message 'A real Windows library import table is read'

    $closureRoot = Join-Path $peRoot 'closure'
    New-TestPeFile -Path (Join-Path $closureRoot 'app.exe') -Imports @('KERNEL32.dll', 'api-ms-win-crt-runtime-l1-1-0.dll', 'liba.dll')
    New-TestPeFile -Path (Join-Path $closureRoot 'liba.dll') -Imports @('KERNEL32.dll', 'libb.dll')
    New-TestPeFile -Path (Join-Path $closureRoot 'libc.dll') -Imports @('KERNEL32.dll')
    New-TestPeFile -Path (Join-Path $closureRoot 'unused.dll') -Imports @('libnothing.dll')
    New-TestPeFile -Path (Join-Path $closureRoot 'lib\plugins\plugin.dll') -Imports @('KERNEL32.dll', 'LIBC.dll', 'libgone-1.dll')
    $unresolved = @(Get-MissingRuntimeDependencies -Root $closureRoot)
    Assert-True -Condition ($unresolved.Count -eq 2) -Message 'Only genuinely unresolved libraries are reported'
    Assert-True `
        -Condition ($unresolved[0].Module -ceq 'libb.dll' -and $unresolved[0].RequiredBy -contains 'liba.dll') `
        -Message 'A library missing from a transitive dependency names its importer'
    Assert-True `
        -Condition ($unresolved[1].Module -ceq 'libgone-1.dll' -and $unresolved[1].RequiredBy -contains 'plugin.dll') `
        -Message 'A plugin import missing from the application directory is reported'

    $bundleRoot = Join-Path $peRoot 'bundle'
    foreach ($relativePath in (Get-RequiredRuntimeFiles)) {
        New-TestPeFile -Path (Join-Path $bundleRoot $relativePath) -Imports @('KERNEL32.dll')
    }
    $bundleComplete = $true
    try { Assert-RuntimeBundle -Root $bundleRoot } catch { $bundleComplete = $false }
    Assert-True -Condition $bundleComplete -Message 'A runtime with every file and library passes validation'

    New-TestPeFile `
        -Path (Join-Path $bundleRoot 'lib\gstreamer-1.0\libgstlibav.dll') `
        -Imports @('KERNEL32.dll', 'avcodec-63.dll')
    $bundleError = $null
    try { Assert-RuntimeBundle -Root $bundleRoot } catch { $bundleError = $_.Exception.Message }
    Assert-True `
        -Condition ($null -ne $bundleError -and $bundleError -match 'avcodec-63\.dll \(needed by libgstlibav\.dll\)') `
        -Message 'A codec plugin without its codec library fails validation by name'
}
finally {
    if (Test-Path -LiteralPath $peRoot) {
        Remove-Item -LiteralPath $peRoot -Recurse -Force
    }
}
$legacyRuntime = [pscustomobject]@{ version = '2.0.0.1736' }
$currentRuntime = [pscustomobject]@{
    version = $metadata.Version
    sha256 = $metadata.Sha256
}
Assert-True `
    -Condition (-not (Test-RuntimeManifest -Manifest $legacyRuntime)) `
    -Message 'The previous upstream runtime is replaced by the patched build'
Assert-True `
    -Condition (Test-RuntimeManifest -Manifest $currentRuntime) `
    -Message 'An installed runtime with the pinned build and digest is reused'

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) test(s) failed."
    exit 1
}

Write-Host 'All tests passed.'
