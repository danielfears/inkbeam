[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'start', 'stop', 'restart', 'status', 'doctor', 'configure', 'help')]
    [string]$Command = 'help',

    [string]$ReceiverName,

    [ValidateSet('every-connection', 'pair-once', 'open')]
    [string]$Authentication,

    [ValidateSet('on', 'off')]
    [string]$Audio,

    [ValidateSet('auto', 'd3d11', 'd3d12')]
    [string]$Renderer,

    [ValidateSet('on', 'off')]
    [string]$Fullscreen,

    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Script:InvocationParameters = $PSBoundParameters

$Script:RuntimeVersion = '2.0.0.1736'
$Script:RuntimeUri = 'https://github.com/leapbtw/uxplay-windows/releases/download/2.0.0.1736/uxplay-windows.zip'
$Script:RuntimeSha256 = '9d3a51c15fc9db857351195e7eb7bbb21700d9ae25d936a54bcf8536b62cca18'
$Script:DataRoot = Join-Path $env:LOCALAPPDATA 'iPadWhiteboardReceiver'
$Script:RuntimeRoot = Join-Path $Script:DataRoot "runtime\$($Script:RuntimeVersion)-x64"
$Script:ExecutablePath = Join-Path $Script:RuntimeRoot 'uxplay-windows.exe'
$Script:MdnsExecutablePath = Join-Path $Script:RuntimeRoot 'mDNSResponder.exe'
$Script:RuntimeManifestPath = Join-Path $Script:DataRoot 'runtime-current.json'
$Script:LauncherPath = Join-Path $Script:DataRoot 'Start-ReceiverHost.ps1'
$Script:ConfigurationPath = Join-Path $Script:DataRoot 'config.json'
$Script:ArgumentsPath = Join-Path $env:APPDATA 'leapbtw\uxplay-windows\arguments.txt'
$Script:WindowsPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Script:RequiredRuntimeFiles = @(
    'uxplay-windows.exe',
    'mDNSResponder.exe',
    'dnssd.dll',
    'Qt6Core.dll',
    'Qt6Widgets.dll',
    'libgstreamer-1.0-0.dll',
    'platforms\qwindows.dll',
    'lib\gstreamer-1.0\libgstcoreelements.dll',
    'lib\gstreamer-1.0\libgstd3d11.dll',
    'lib\gstreamer-1.0\libgstlibav.dll',
    'lib\gstreamer-1.0\libgstvideoparsersbad.dll',
    'lib\gstreamer-1.0\libgstwasapi2.dll'
)
$Script:FirewallRuleNames = @(
    'iPadWhiteboardReceiver-TCP',
    'iPadWhiteboardReceiver-UDP',
    'iPadWhiteboardReceiver-mDNS'
)

function Get-RuntimeMetadata {
    [pscustomobject]@{
        Version = $Script:RuntimeVersion
        Uri = $Script:RuntimeUri
        Sha256 = $Script:RuntimeSha256
        Architecture = 'x64'
    }
}

function Get-DefaultConfiguration {
    [pscustomobject][ordered]@{
        receiverName = 'InkBeam'
        authentication = 'every-connection'
        audioEnabled = $false
        renderer = 'd3d11'
        fullscreen = $false
    }
}

function Test-ReceiverName {
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 64) {
        return $false
    }

    return -not $Name.StartsWith('-') -and $Name -notmatch '["%\s]'
}

function Get-Configuration {
    $configuration = Get-DefaultConfiguration
    if (-not (Test-Path -LiteralPath $Script:ConfigurationPath -PathType Leaf)) {
        return $configuration
    }

    try {
        $saved = Get-Content -LiteralPath $Script:ConfigurationPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "The configuration file is invalid: $($Script:ConfigurationPath). $($_.Exception.Message)"
    }

    foreach ($property in @('receiverName', 'authentication', 'audioEnabled', 'renderer', 'fullscreen')) {
        if ($null -ne $saved.PSObject.Properties[$property]) {
            $configuration.$property = $saved.$property
        }
    }

    if (-not (Test-ReceiverName -Name ([string]$configuration.receiverName))) {
        throw 'The configured receiver name must be 1-64 characters, cannot start with a hyphen, and cannot contain whitespace, quotes, or percent signs.'
    }
    if (@('every-connection', 'pair-once', 'open') -notcontains [string]$configuration.authentication) {
        throw "Unsupported authentication mode: $($configuration.authentication)"
    }
    if (@('auto', 'd3d11', 'd3d12') -notcontains [string]$configuration.renderer) {
        throw "Unsupported renderer: $($configuration.renderer)"
    }

    $configuration.audioEnabled = [bool]$configuration.audioEnabled
    $configuration.fullscreen = [bool]$configuration.fullscreen
    return $configuration
}

function Save-Configuration {
    param([Parameter(Mandatory)][psobject]$Configuration)

    New-Item -ItemType Directory -Path (Split-Path -Parent $Script:ConfigurationPath) -Force | Out-Null
    $Configuration |
        ConvertTo-Json |
        Set-Content -LiteralPath $Script:ConfigurationPath -Encoding UTF8
}

function ConvertTo-UxPlayArguments {
    param([Parameter(Mandatory)][psobject]$Configuration)

    if (-not (Test-ReceiverName -Name ([string]$Configuration.receiverName))) {
        throw 'The receiver name must be 1-64 characters, cannot start with a hyphen, and cannot contain whitespace, quotes, or percent signs.'
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    [void]$parts.Add('-n')
    [void]$parts.Add([string]$Configuration.receiverName)
    [void]$parts.Add('-nh')

    switch ([string]$Configuration.authentication) {
        'every-connection' {
            # With no value, -pw asks for a fresh random PIN on every connection.
            [void]$parts.Add('-pw')
        }
        'pair-once' {
            [void]$parts.Add('-pin')
            [void]$parts.Add('-reg')
            [void]$parts.Add('trusted-clients.register')
        }
        'open' {
            # Deliberately no authentication argument.
        }
        default {
            throw "Unsupported authentication mode: $($Configuration.authentication)"
        }
    }

    [void]$parts.Add('-key')
    [void]$parts.Add('receiver.pem')
    [void]$parts.Add('-nofreeze')
    [void]$parts.Add('-nc')
    [void]$parts.Add('-p')
    [void]$parts.Add('7100')
    [void]$parts.Add('-fps')
    [void]$parts.Add('30')

    if (-not [bool]$Configuration.audioEnabled) {
        [void]$parts.Add('-as')
        [void]$parts.Add('0')
    }

    return $parts -join ' '
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

function Write-UxPlayConfiguration {
    param([Parameter(Mandatory)][psobject]$Configuration)

    New-Item -ItemType Directory -Path (Split-Path -Parent $Script:ArgumentsPath) -Force | Out-Null
    Write-Utf8NoBomFile `
        -Path $Script:ArgumentsPath `
        -Content (ConvertTo-UxPlayArguments -Configuration $Configuration)

    $settingsPath = 'HKCU:\Software\leapbtw\uxplay-windows'
    New-Item -Path $settingsPath -Force | Out-Null
    New-ItemProperty -Path $settingsPath -Name 'ble_enabled' -Value 'false' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $settingsPath -Name 'renderer_mode' -Value ([string]$Configuration.renderer) -PropertyType String -Force | Out-Null
    $fullscreenValue = if ([bool]$Configuration.fullscreen) { 'true' } else { 'false' }
    New-ItemProperty -Path $settingsPath -Name 'force_fs_enabled' -Value $fullscreenValue -PropertyType String -Force | Out-Null
}

function Get-RequiredRuntimeFiles {
    return @($Script:RequiredRuntimeFiles)
}

function Assert-RuntimeBundle {
    param([Parameter(Mandatory)][string]$Root)

    $missing = @(
        foreach ($relativePath in $Script:RequiredRuntimeFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
                $relativePath
            }
        }
    )
    if ($missing.Count -gt 0) {
        throw "The UxPlay runtime is incomplete. Missing: $($missing -join ', ')."
    }
}

function Write-RuntimeManifest {
    [pscustomobject][ordered]@{
        version = $Script:RuntimeVersion
        architecture = 'x64'
        executable = $Script:ExecutablePath
        mdnsExecutable = $Script:MdnsExecutablePath
        launcher = $Script:LauncherPath
        tcpPorts = @(7100, 7101, 7102)
    } |
        ConvertTo-Json |
        Set-Content -LiteralPath $Script:RuntimeManifestPath -Encoding UTF8
}

function Install-Runtime {
    if (Test-Path -LiteralPath $Script:ExecutablePath -PathType Leaf) {
        Assert-RuntimeBundle -Root $Script:RuntimeRoot
        Write-RuntimeManifest
        Write-Host "Receiver runtime $($Script:RuntimeVersion) is already installed."
        return
    }

    $downloadDirectory = Join-Path $Script:DataRoot 'downloads'
    $archivePath = Join-Path $downloadDirectory "uxplay-windows-$($Script:RuntimeVersion)-x64.zip"
    New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null

    $archiveIsValid = $false
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        $archiveIsValid = $archiveHash -eq $Script:RuntimeSha256
        if (-not $archiveIsValid) {
            Remove-Item -LiteralPath $archivePath -Force
        }
    }

    if (-not $archiveIsValid) {
        Write-Host "Downloading verified open-source receiver runtime $($Script:RuntimeVersion)..."
        $oldProgressPreference = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Script:RuntimeUri -OutFile $archivePath -UseBasicParsing
        }
        finally {
            $ProgressPreference = $oldProgressPreference
        }
    }

    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ne $Script:RuntimeSha256) {
        throw "Runtime checksum mismatch. Expected $($Script:RuntimeSha256), received $actualHash."
    }

    $temporaryRoot = Join-Path $env:TEMP "iPadWhiteboardReceiver-$([guid]::NewGuid().ToString('N'))"
    $extractPath = Join-Path $temporaryRoot 'runtime'
    $identityBackupPath = Join-Path $temporaryRoot 'identity'
    try {
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath

        $stagedExecutable = Join-Path $extractPath 'uxplay-windows.exe'
        if (-not (Test-Path -LiteralPath $stagedExecutable -PathType Leaf)) {
            throw 'The downloaded archive does not contain uxplay-windows.exe at its expected path.'
        }
        Assert-RuntimeBundle -Root $extractPath

        New-Item -ItemType Directory -Path (Split-Path -Parent $Script:RuntimeRoot) -Force | Out-Null
        if (Test-Path -LiteralPath $Script:RuntimeRoot) {
            New-Item -ItemType Directory -Path $identityBackupPath -Force | Out-Null
            foreach ($fileName in @('receiver.pem', 'trusted-clients.register')) {
                $identityPath = Join-Path $Script:RuntimeRoot $fileName
                if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
                    Copy-Item -LiteralPath $identityPath -Destination $identityBackupPath
                }
            }
            Remove-Item -LiteralPath $Script:RuntimeRoot -Recurse -Force
        }
        Move-Item -LiteralPath $extractPath -Destination $Script:RuntimeRoot
        if (Test-Path -LiteralPath $identityBackupPath -PathType Container) {
            Get-ChildItem -LiteralPath $identityBackupPath -File |
                Copy-Item -Destination $Script:RuntimeRoot
        }
        Write-RuntimeManifest
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }
}

function Install-ReceiverLauncher {
    New-Item -ItemType Directory -Path $Script:DataRoot -Force | Out-Null
    foreach ($fileName in @('Start-ReceiverHost.ps1', 'ReceiverHost.cs', 'ReceiverSession.cs')) {
        $source = Join-Path $PSScriptRoot "scripts\$fileName"
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Missing receiver host file: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $Script:DataRoot $fileName) -Force
    }
    $legacyLauncher = Join-Path $Script:DataRoot 'Start-ReceiverWithConsole.ps1'
    if (Test-Path -LiteralPath $legacyLauncher -PathType Leaf) {
        Remove-Item -LiteralPath $legacyLauncher -Force
    }
    Write-RuntimeManifest
}

function ConvertTo-NativeQuotedArgument {
    param([Parameter(Mandatory)][string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Install-WindowsHostConfiguration {
    $hostScript = Join-Path $PSScriptRoot 'scripts\Configure-WindowsHost.ps1'
    if (-not (Test-Path -LiteralPath $hostScript -PathType Leaf)) {
        throw "Missing host configuration script: $hostScript"
    }

    $arguments = @(
        '-NoProfile'
        '-WindowStyle'
        'Hidden'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        (ConvertTo-NativeQuotedArgument -Value $hostScript)
        '-ReceiverExecutable'
        (ConvertTo-NativeQuotedArgument -Value $Script:ExecutablePath)
        '-MdnsExecutable'
        (ConvertTo-NativeQuotedArgument -Value $Script:MdnsExecutablePath)
    )

    Write-Host 'Windows will request administrator approval once for local discovery and local-subnet firewall rules.'
    $process = Start-Process `
        -FilePath $Script:WindowsPowerShellPath `
        -ArgumentList $arguments `
        -Verb RunAs `
        -PassThru `
        -Wait

    if ($process.ExitCode -ne 0) {
        throw "Windows host configuration failed with exit code $($process.ExitCode)."
    }
}

function Test-WindowsHostConfiguration {
    $service = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.Status -ne 'Running') {
        return $false
    }

    foreach ($ruleName in $Script:FirewallRuleNames) {
        $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($null -eq $rule -or $rule.Enabled -ne 'True' -or
            $rule.Action -ne 'Allow' -or $rule.Direction -ne 'Inbound' -or
            [string]$rule.Group -ne 'InkBeam') {
            return $false
        }
        $profiles = [string]$rule.Profile
        if (@('Domain', 'Private', 'Public') |
            Where-Object { $profiles -notmatch [regex]::Escape($_) }) {
            return $false
        }
    }
    return $true
}

function Install-StartMenuShortcut {
    $programs = [Environment]::GetFolderPath('Programs')
    $shortcutPath = Join-Path $programs 'InkBeam.lnk'
    foreach ($name in @('iPad Whiteboard Receiver.lnk', 'InkBeam Receiver.lnk')) {
        Remove-Item -LiteralPath (Join-Path $programs $name) -Force -ErrorAction SilentlyContinue
    }
    $applicationPath = Join-Path $Script:DataRoot 'app\desktop\InkBeam.exe'
    if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) {
        throw 'The Windows application is missing. Run the InkBeam installer.'
    }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        try {
            $shortcut.TargetPath = $applicationPath
            $shortcut.WorkingDirectory = Split-Path -Parent $applicationPath
            $shortcut.IconLocation = "$applicationPath,0"
            $shortcut.Description = 'Control local iPad screen mirroring with InkBeam'
            $shortcut.Save()
        }
        finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
    }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
}

function Get-ReceiverHostState {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        '.', 'InkBeamReceiverState', [IO.Pipes.PipeDirection]::In,
        [IO.Pipes.PipeOptions]::Asynchronous
    )
    $reader = $null
    try {
        $pipe.Connect(150)
        $reader = [IO.StreamReader]::new($pipe)
        $read = $reader.ReadLineAsync()
        if (-not $read.Wait(1000)) {
            throw 'The receiver state pipe did not respond within one second.'
        }
        $line = $read.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw 'The receiver state pipe returned an empty response.'
        }
        $state = $line | ConvertFrom-Json
        if ($state.version -ne 1 -or
            @('Starting', 'Ready', 'Pairing', 'Casting', 'Error') -notcontains $state.state) {
            throw 'The receiver state protocol is unsupported.'
        }
        return $state
    }
    catch [TimeoutException] { return $null }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $pipe.Dispose()
    }
}

function Wait-ReceiverHostStopped {
    $mutex = $null
    if ([Threading.Mutex]::TryOpenExisting('Local\iPadWhiteboardReceiverHost', [ref]$mutex)) {
        $acquired = $false
        try {
            try { $acquired = $mutex.WaitOne(10000) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            if (-not $acquired) {
                throw 'The previous receiver host did not exit within ten seconds.'
            }
        }
        finally {
            if ($acquired) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

function Get-ReceiverProcesses {
    if (-not (Test-Path -LiteralPath $Script:ExecutablePath -PathType Leaf)) {
        return @()
    }

    $expectedPath = [System.IO.Path]::GetFullPath($Script:ExecutablePath)
    return @(
        Get-Process -Name 'uxplay-windows' -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    [string]::Equals(
                        [System.IO.Path]::GetFullPath($_.Path),
                        $expectedPath,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
                catch {
                    $false
                }
            }
    )
}

function Start-Receiver {
    if (-not (Test-Path -LiteralPath $Script:ExecutablePath -PathType Leaf)) {
        throw 'The receiver is not installed. Run Install.cmd again.'
    }
    if (-not (Test-Path -LiteralPath $Script:LauncherPath -PathType Leaf)) {
        throw 'The PIN host is not installed. Run Install.cmd again.'
    }

    $running = @(Get-ReceiverProcesses)
    if ($running.Count -gt 0) {
        Write-Host 'InkBeam is already running.'
        return
    }

    $configuration = Get-Configuration
    Write-UxPlayConfiguration -Configuration $configuration
    $launcherArguments = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        (ConvertTo-NativeQuotedArgument -Value $Script:LauncherPath)
        '-ReceiverExecutable'
        (ConvertTo-NativeQuotedArgument -Value $Script:ExecutablePath)
        '-WorkingDirectory'
        (ConvertTo-NativeQuotedArgument -Value $Script:RuntimeRoot)
    )
    $hostProcess = Start-Process `
        -FilePath $Script:WindowsPowerShellPath `
        -WindowStyle Hidden `
        -ArgumentList $launcherArguments -PassThru

    $failureMessage = $null
    foreach ($attempt in 1..60) {
        Start-Sleep -Milliseconds 250
        $state = Get-ReceiverHostState
        $running = @(Get-ReceiverProcesses)
        if ($null -ne $state -and $running.Count -eq 1 -and
            $state.receiverPid -eq $running[0].Id) {
            if ($state.state -eq 'Error') {
                $failureMessage = [string]$state.message
                break
            }
            if ($state.state -in @('Ready', 'Pairing', 'Casting')) {
                Write-Host "Ready: choose '$($configuration.receiverName)' from the iPad Screen Mirroring menu."
                return
            }
        }
        if ($hostProcess.HasExited) { break }
    }
    foreach ($process in @(Get-ReceiverProcesses)) {
        Stop-Process -Id $process.Id -ErrorAction Stop
    }
    Wait-ReceiverHostStopped
    if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
        throw $failureMessage
    }
    throw 'The receiver did not establish a working AirPlay listener and status channel. Run the controller doctor command.'
}

function Stop-Receiver {
    $running = @(Get-ReceiverProcesses)
    if ($running.Count -eq 0) {
        Wait-ReceiverHostStopped
        Write-Host 'InkBeam is already stopped.'
        return
    }

    foreach ($process in $running) {
        Stop-Process -Id $process.Id -ErrorAction Stop
    }
    Wait-ReceiverHostStopped
    if (@(Get-ReceiverProcesses).Count -gt 0) {
        throw 'The receiver did not stop cleanly.'
    }
    Write-Host 'InkBeam stopped.'
}

function Show-Status {
    $configuration = Get-Configuration
    $running = @(Get-ReceiverProcesses).Count -gt 0
    $service = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue

    Write-Host ('Receiver:       ' + $(if ($running) { 'running' } else { 'stopped' }))
    Write-Host ('Discovery:      ' + $(if ($null -ne $service) { [string]$service.Status } else { 'not installed' }))
    Write-Host "AirPlay name:    $($configuration.receiverName)"
    Write-Host "Authentication:  $($configuration.authentication)"
    Write-Host ('Audio:          ' + $(if ([bool]$configuration.audioEnabled) { 'on' } else { 'off' }))
    Write-Host "Renderer:       $($configuration.renderer)"
}

function Write-DoctorCheck {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Result,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Host "[$Result] $Message"
}

function Invoke-Doctor {
    $failures = 0

    if (Test-Path -LiteralPath $Script:ExecutablePath -PathType Leaf) {
        Write-DoctorCheck -Result PASS -Message "Runtime $($Script:RuntimeVersion) is installed."
        try {
            Assert-RuntimeBundle -Root $Script:RuntimeRoot
            Write-DoctorCheck -Result PASS -Message 'The required codecs, renderer, and application files are present.'
        }
        catch {
            $failures++
            Write-DoctorCheck -Result FAIL -Message $_.Exception.Message
        }
    }
    else {
        $failures++
        Write-DoctorCheck -Result FAIL -Message 'Runtime is missing; run Install.cmd again.'
    }

    $service = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -eq 'Running') {
        Write-DoctorCheck -Result PASS -Message 'Local Bonjour discovery service is running.'
    }
    else {
        $failures++
        Write-DoctorCheck -Result FAIL -Message 'Local Bonjour discovery is not running; run Install.cmd again.'
    }

    $missingRules = @(
        foreach ($ruleName in $Script:FirewallRuleNames) {
            if ($null -eq (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
                $ruleName
            }
        }
    )
    if ($missingRules.Count -eq 0) {
        Write-DoctorCheck -Result PASS -Message 'Local-subnet firewall rules are installed.'
    }
    else {
        $failures++
        Write-DoctorCheck -Result FAIL -Message "Firewall rules are missing: $($missingRules -join ', ')."
    }

    $activeProfiles = @(
        Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object {
                $_.InterfaceAlias -notlike 'vEthernet*' -and
                $_.InterfaceAlias -notmatch '^wt\d+$' -and
                ($_.IPv4Connectivity -ne 'NoTraffic' -or
                    $_.IPv6Connectivity -ne 'NoTraffic')
            }
    )
    if ($activeProfiles.Count -gt 0) {
        if (@(
                $activeProfiles |
                    Where-Object { $_.NetworkCategory -eq 'Public' }
            ).Count -gt 0) {
            Write-DoctorCheck -Result WARN -Message 'The active network is Public; access remains PIN-gated and limited to its local subnet.'
        }
        else {
            Write-DoctorCheck -Result PASS -Message 'An active network can receive local AirPlay traffic.'
        }
    }
    else {
        $failures++
        Write-DoctorCheck -Result FAIL -Message 'No active Windows network connection was found.'
    }

    $configuration = Get-Configuration
    if ($configuration.authentication -eq 'open') {
        Write-DoctorCheck -Result WARN -Message 'Authentication is open; anyone on the permitted LAN can request a connection.'
    }
    else {
        Write-DoctorCheck -Result PASS -Message "Authentication mode is '$($configuration.authentication)'."
    }

    if (@(Get-ReceiverProcesses).Count -gt 0) {
        Write-DoctorCheck -Result PASS -Message 'Receiver process is running.'
    }
    else {
        Write-DoctorCheck -Result WARN -Message 'Receiver process is stopped; enable it in the InkBeam application.'
    }

    if ($failures -gt 0) {
        return 1
    }
    return 0
}

function Update-Configuration {
    $configuration = Get-Configuration

    if ($Script:InvocationParameters.ContainsKey('ReceiverName')) {
        if (-not (Test-ReceiverName -Name $ReceiverName)) {
            throw 'ReceiverName must be 1-64 characters, cannot start with a hyphen, and cannot contain whitespace, quotes, or percent signs.'
        }
        $configuration.receiverName = $ReceiverName
    }
    if ($Script:InvocationParameters.ContainsKey('Authentication')) {
        $configuration.authentication = $Authentication
    }
    if ($Script:InvocationParameters.ContainsKey('Audio')) {
        $configuration.audioEnabled = $Audio -eq 'on'
    }
    if ($Script:InvocationParameters.ContainsKey('Renderer')) {
        $configuration.renderer = $Renderer
    }
    if ($Script:InvocationParameters.ContainsKey('Fullscreen')) {
        $configuration.fullscreen = $Fullscreen -eq 'on'
    }

    Save-Configuration -Configuration $configuration
    Write-UxPlayConfiguration -Configuration $configuration

    if (@(Get-ReceiverProcesses).Count -gt 0) {
        Stop-Receiver
        Start-Receiver
    }

    Write-Host "Configured '$($configuration.receiverName)' with $($configuration.authentication) authentication."
}

function Show-Help {
    @'
Windows PowerShell:
  $controller = "$env:LOCALAPPDATA\iPadWhiteboardReceiver\app\WhiteboardReceiver.ps1"
  & $controller start|stop|restart|status|doctor
  & $controller configure [-ReceiverName <name>]
                          [-Authentication every-connection|pair-once|open]
                          [-Audio on|off]
                          [-Renderer auto|d3d11|d3d12]
                          [-Fullscreen on|off]

The secure defaults require a fresh PIN for every connection, disable audio
and Bluetooth discovery, and allow inbound traffic only from the local subnet.
'@ | Write-Host
}

function Invoke-Main {
    try {
        switch ($Command) {
            'install' {
                Stop-Receiver
                Install-Runtime
                Install-ReceiverLauncher
                $configuration = Get-Configuration
                if ($configuration.receiverName -eq 'iPad-Whiteboard') {
                    $configuration.receiverName = 'InkBeam'
                }
                Save-Configuration -Configuration $configuration
                Write-UxPlayConfiguration -Configuration $configuration
                if (-not (Test-WindowsHostConfiguration)) {
                    Install-WindowsHostConfiguration
                }
                Install-StartMenuShortcut
                if (-not $NoLaunch) { Start-Receiver }
                Write-Host 'InkBeam installation is complete.'
                return 0
            }
            'start' {
                Start-Receiver
                return 0
            }
            'stop' {
                Stop-Receiver
                return 0
            }
            'restart' {
                Stop-Receiver
                Start-Receiver
                return 0
            }
            'status' {
                Show-Status
                return 0
            }
            'doctor' {
                return Invoke-Doctor
            }
            'configure' {
                Update-Configuration
                return 0
            }
            'help' {
                Show-Help
                return 0
            }
        }
    }
    catch {
        Write-Error $_.Exception.Message
        return 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Main)
}
