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
Assert-True -Condition ($metadata.Version -eq '2.0.0.1736-authfix1') -Message 'Patched native runtime build is selected'
Assert-Matches `
    -Value $metadata.Uri `
    -Pattern '^https://github\.com/danielfears/inkbeam/releases/download/uxplay-2\.0\.0\.1736-authfix1/InkBeam-UxPlay-v2\.0\.0\.1736-authfix1-x64\.zip$' `
    -Message 'Patched runtime is downloaded from its immutable release asset'
Assert-Matches -Value $metadata.Sha256 -Pattern '^[a-f0-9]{64}$' -Message 'Pinned runtime has a SHA-256 checksum'
Assert-True -Condition ($metadata.Architecture -eq 'x64') -Message 'Tested x64 runtime is selected instead of the untested ARM64 release'
Assert-True -Condition ((Get-RequiredRuntimeFiles).Count -ge 10) -Message 'Runtime validation covers the application, codecs, and renderer'
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
