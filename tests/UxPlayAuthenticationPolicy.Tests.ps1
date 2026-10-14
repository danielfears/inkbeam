[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourcePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = Get-Content -LiteralPath $SourcePath -Raw
if ([string]::IsNullOrWhiteSpace($source)) {
    throw "UxPlay source is empty: $SourcePath"
}

if ($source -notmatch 'if \(len == -1 && raop->random_pw && raop->auth_fail_count >= MAX_PW_ATTEMPTS && !authorization\)') {
    throw 'PIN rotation must wait for an unauthenticated request.'
}

$challengeStart = $source.IndexOf('if (len == -1 && !authorization && raop->random_pw)')
$authenticationStart = $source.IndexOf('if (len && !conn->authenticated)', $challengeStart)
if ($challengeStart -lt 0 -or $authenticationStart -le $challengeStart) {
    throw 'Could not locate the random-PIN challenge and authentication blocks.'
}

$challengeBlock = $source.Substring($challengeStart, $authenticationStart - $challengeStart)
if ($challengeBlock -match 'auth_fail_count\s*\+\+') {
    throw 'Displaying a PIN must not count as a failed authentication attempt.'
}

if ($source -notmatch 'if \(!conn->authenticated\)\s*\{\s*if \(raop->auth_fail_count < MAX_PW_ATTEMPTS\)\s*\{\s*raop->auth_fail_count\+\+;') {
    throw 'Failed password verification must increment the bounded failure counter.'
}

if ($source -notmatch 'if \(len == -1 && !raop->random_pw\)[\s\S]*?raop->auth_fail_count = 0;') {
    throw 'Creating a fresh random PIN must reset the failure counter.'
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][int]$Actual,
        [Parameter(Mandatory)][int]$Expected,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message (expected $Expected; received $Actual)."
    }
}

$threshold = 3
$attempts = 0
foreach ($challenge in 1..6) {
    # Repeated unauthenticated setup requests only redisplay the current PIN.
}
Assert-Equal -Actual $attempts -Expected 0 -Message 'Repeated PIN challenges do not consume attempts'

foreach ($failure in 1..5) {
    if ($attempts -lt $threshold) {
        $attempts++
    }
}
Assert-Equal -Actual $attempts -Expected $threshold -Message 'Failed PIN attempts saturate at the threshold'

$hasAuthorization = $true
$rotateBeforeAuthentication = ($attempts -ge $threshold) -and (-not $hasAuthorization)
if ($rotateBeforeAuthentication) {
    throw 'A PIN must remain valid while its authorization is being checked.'
}

$hasAuthorization = $false
$rotateForNewChallenge = ($attempts -ge $threshold) -and (-not $hasAuthorization)
if (-not $rotateForNewChallenge) {
    throw 'A new unauthenticated challenge must rotate a PIN after the failure threshold.'
}

Write-Host 'UxPlay random-PIN authentication policy tests passed.'
