#Requires -Version 5.1

# Canonical desktop control and PIN view for the local AirPlay receiver.
[CmdletBinding()]
param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
Add-Type -AssemblyName UIAutomationClient

trap {
    [Console]::Error.WriteLine($_.Exception.Message)
    if (-not $ValidateOnly) {
        [void][System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            "InkBeam",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
    exit 1
}

$dataRoot = Join-Path $env:LOCALAPPDATA "iPadWhiteboardReceiver"
$runtimeManifestPath = Join-Path $dataRoot "runtime-current.json"
$configurationPath = Join-Path $dataRoot "config.json"
$windowsPowerShellPath = Join-Path $env:SystemRoot `
    "System32\WindowsPowerShell\v1.0\powershell.exe"

function Get-RuntimeInformation {
    if (-not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
        return $null
    }

    try {
        $runtime = Get-Content -LiteralPath $runtimeManifestPath -Raw |
            ConvertFrom-Json
    }
    catch {
        throw "Receiver runtime manifest is invalid: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace([string]$runtime.executable)) {
        throw "Receiver runtime manifest has no executable path."
    }
    if ($null -eq $runtime.PSObject.Properties["launcher"] -or
        [string]::IsNullOrWhiteSpace([string]$runtime.launcher)) {
        return $null
    }
    return $runtime
}

function ConvertTo-NativeQuotedArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-ReceiverPin {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new(
        ".",
        "iPadWhiteboardPin",
        [IO.Pipes.PipeDirection]::In
    )
    $reader = $null
    try {
        $pipe.Connect(150)
        $reader = [IO.StreamReader]::new($pipe)
        $pin = $reader.ReadLine()
        if ($pin -match "^\d{4}$") {
            return $pin
        }
        return $null
    }
    catch [TimeoutException] {
        return $null
    }
    catch [IO.IOException] {
        return $null
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        $pipe.Dispose()
    }
}

function Get-ReceiverConfiguration {
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
        return [pscustomobject]@{
            receiverName = "InkBeam"
            authentication = "every-connection"
        }
    }

    try {
        $configuration = Get-Content -LiteralPath $configurationPath -Raw |
            ConvertFrom-Json
    }
    catch {
        throw "Receiver configuration is invalid: $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace(
            [string]$configuration.receiverName
        )) {
        throw "Receiver configuration has no AirPlay name."
    }
    return $configuration
}

function Get-ReceiverProcesses {
    param([AllowNull()][psobject]$Runtime)

    if ($null -eq $Runtime -or
        -not (Test-Path -LiteralPath $Runtime.executable -PathType Leaf)) {
        return @()
    }

    $expectedPath = [System.IO.Path]::GetFullPath(
        [string]$Runtime.executable
    )
    return @(
        Get-Process -Name "uxplay-windows" -ErrorAction SilentlyContinue |
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

function Test-CastingConnection {
    param([Parameter(Mandatory = $true)][Diagnostics.Process[]]$Processes)

    foreach ($process in $Processes) {
        $connections = @(
            Get-NetTCPConnection `
                -OwningProcess $process.Id `
                -State Established `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.LocalPort -in @(7100, 7101, 7102) -and
                    $_.RemoteAddress -notin @("127.0.0.1", "::1")
                }
        )
        if ($connections.Count -gt 0) {
            return $true
        }
    }
    return $false
}

function Test-ActivePhysicalNetwork {
    $activeProfiles = @(
        Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Where-Object {
                $_.InterfaceAlias -notlike "vEthernet*" -and
                $_.InterfaceAlias -notmatch "^wt\d+$" -and
                ($_.IPv4Connectivity -ne "NoTraffic" -or
                    $_.IPv6Connectivity -ne "NoTraffic")
            }
    )
    return $activeProfiles.Count -gt 0
}

function Get-ReceiverState {
    $runtime = Get-RuntimeInformation
    $configuration = Get-ReceiverConfiguration

    if ($null -eq $runtime -or
        -not (Test-Path -LiteralPath $runtime.executable -PathType Leaf)) {
        return [pscustomobject]@{
            Kind = "Missing"
            Label = "Setup required"
            Detail = "Run Install.cmd from the extracted release"
            ButtonLabel = "Unavailable"
            CanToggle = $false
            IsEnabled = $false
            ReceiverName = [string]$configuration.receiverName
            Authentication = [string]$configuration.authentication
            Runtime = $runtime
            Processes = @()
        }
    }

    $processes = @(Get-ReceiverProcesses -Runtime $runtime)
    $service = Get-Service -Name "Bonjour Service" -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.Status -ne "Running") {
        return [pscustomobject]@{
            Kind = "Error"
            Label = "Discovery unavailable"
            Detail = "Run Install.cmd again to repair"
            ButtonLabel = $(if ($processes.Count) { "Disable" } else { "Unavailable" })
            CanToggle = $processes.Count -gt 0
            IsEnabled = $processes.Count -gt 0
            ReceiverName = [string]$configuration.receiverName
            Authentication = [string]$configuration.authentication
            Runtime = $runtime
            Processes = $processes
        }
    }

    if (-not (Test-ActivePhysicalNetwork)) {
        return [pscustomobject]@{
            Kind = "Error"
            Label = "No network"
            Detail = "Connect the laptop to the iPad's network"
            ButtonLabel = $(if ($processes.Count) { "Disable" } else { "Unavailable" })
            CanToggle = $processes.Count -gt 0
            IsEnabled = $processes.Count -gt 0
            ReceiverName = [string]$configuration.receiverName
            Authentication = [string]$configuration.authentication
            Runtime = $runtime
            Processes = $processes
        }
    }

    if ($processes.Count -eq 0) {
        return [pscustomobject]@{
            Kind = "Disabled"
            Label = "Disabled"
            Detail = "Click Enable when you need to cast"
            ButtonLabel = "Enable"
            CanToggle = $true
            IsEnabled = $false
            ReceiverName = [string]$configuration.receiverName
            Authentication = [string]$configuration.authentication
            Runtime = $runtime
            Processes = @()
        }
    }

    if (Test-CastingConnection -Processes $processes) {
        return [pscustomobject]@{
            Kind = "Casting"
            Label = "Casting now"
            Detail = "The iPad screen is connected"
            ButtonLabel = "Disable"
            CanToggle = $true
            IsEnabled = $true
            ReceiverName = [string]$configuration.receiverName
            Authentication = [string]$configuration.authentication
            Runtime = $runtime
            Processes = $processes
        }
    }

    return [pscustomobject]@{
        Kind = "Ready"
        Label = "Ready to cast"
        Detail = "Select this receiver; the PIN appears below"
        ButtonLabel = "Disable"
        CanToggle = $true
        IsEnabled = $true
        ReceiverName = [string]$configuration.receiverName
        Authentication = [string]$configuration.authentication
        Runtime = $runtime
        Processes = $processes
    }
}

if ($ValidateOnly) {
    $state = Get-ReceiverState
    Write-Output "InkBeam widget configuration is valid ($($state.Kind))."
    return
}

$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="InkBeam"
    Width="350"
    Height="136"
    WindowStyle="None"
    ResizeMode="NoResize"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="False"
    ShowInTaskbar="False">
    <Window.Resources>
        <Style x:Key="ActionButton" TargetType="{x:Type Button}">
            <Setter Property="Width" Value="88" />
            <Setter Property="Height" Value="30" />
            <Setter Property="Foreground" Value="#F4F4F7" />
            <Setter Property="Background" Value="#32323A" />
            <Setter Property="BorderBrush" Value="#555560" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="FontFamily" Value="Segoe UI Semibold" />
            <Setter Property="FontSize" Value="11" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border
                            x:Name="ActionBorder"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}"
                            CornerRadius="6">
                            <ContentPresenter
                                HorizontalAlignment="Center"
                                VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter
                                    TargetName="ActionBorder"
                                    Property="BorderBrush"
                                    Value="#92929E" />
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter
                                    TargetName="ActionBorder"
                                    Property="Opacity"
                                    Value="0.78" />
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter
                                    TargetName="ActionBorder"
                                    Property="Opacity"
                                    Value="0.42" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="CloseButton" TargetType="{x:Type Button}">
            <Setter Property="Width" Value="22" />
            <Setter Property="Height" Value="22" />
            <Setter Property="Foreground" Value="#B8B8C0" />
            <Setter Property="Background" Value="Transparent" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="FontFamily" Value="Segoe UI" />
            <Setter Property="FontSize" Value="11" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Button}">
                        <Border
                            x:Name="CloseBorder"
                            Background="{TemplateBinding Background}"
                            CornerRadius="5">
                            <ContentPresenter
                                HorizontalAlignment="Center"
                                VerticalAlignment="Center" />
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter
                                    TargetName="CloseBorder"
                                    Property="Background"
                                    Value="#3A3A42" />
                                <Setter Property="Foreground" Value="#FFFFFF" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Border
        Background="#F21E1E24"
        BorderBrush="#51515C"
        BorderThickness="1"
        CornerRadius="11"
        Padding="12,8,12,10">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="28" />
                <RowDefinition Height="58" />
                <RowDefinition Height="28" />
            </Grid.RowDefinitions>
            <Grid Grid.Row="0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <Border
                    x:Name="DragRegion"
                    Grid.Column="0"
                    Background="Transparent">
                    <TextBlock
                        VerticalAlignment="Center"
                        Foreground="#D8D8DE"
                        FontFamily="Segoe UI Semibold"
                        FontSize="11"
                        Text="INKBEAM" />
                </Border>
                <Button
                    x:Name="CloseButton"
                    Grid.Column="1"
                    Style="{StaticResource CloseButton}"
                    Content="x"
                    ToolTip="Close" />
            </Grid>
            <Border
                Grid.Row="1"
                Background="#292930"
                BorderBrush="#44444E"
                BorderThickness="1"
                CornerRadius="8">
                <Grid Margin="11,7">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="18" />
                        <ColumnDefinition Width="*" />
                        <ColumnDefinition Width="Auto" />
                    </Grid.ColumnDefinitions>
                    <Ellipse
                        x:Name="StatusDot"
                        Grid.Column="0"
                        Width="9"
                        Height="9"
                        HorizontalAlignment="Left"
                        VerticalAlignment="Center"
                        Fill="#73737C" />
                    <StackPanel
                        Grid.Column="1"
                        VerticalAlignment="Center">
                        <TextBlock
                            x:Name="StatusText"
                            Foreground="#F2F2F5"
                            FontFamily="Segoe UI Semibold"
                            FontSize="14"
                            Text="Checking..." />
                        <TextBlock
                            x:Name="DetailText"
                            Margin="0,2,8,0"
                            Foreground="#AAAAB4"
                            FontFamily="Segoe UI"
                            FontSize="10.5"
                            Text="Reading receiver state"
                            TextTrimming="CharacterEllipsis" />
                    </StackPanel>
                    <Button
                        x:Name="ToggleButton"
                        Grid.Column="2"
                        VerticalAlignment="Center"
                        Style="{StaticResource ActionButton}"
                        Content="Checking..."
                        IsEnabled="False" />
                </Grid>
            </Border>
            <Grid Grid.Row="2" Margin="2,4,2,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto" />
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <TextBlock
                    Grid.Column="0"
                    VerticalAlignment="Center"
                    Foreground="#81818C"
                    FontFamily="Segoe UI"
                    FontSize="9.5"
                    Text="AIRPLAY NAME" />
                <TextBlock
                    x:Name="ReceiverNameText"
                    Grid.Column="1"
                    Margin="7,0,0,0"
                    VerticalAlignment="Center"
                    Foreground="#D3A7FF"
                    FontFamily="Cascadia Mono"
                    FontSize="10"
                    Text="InkBeam"
                    TextTrimming="CharacterEllipsis" />
                <TextBlock
                    x:Name="AuthenticationText"
                    Grid.Column="2"
                    VerticalAlignment="Center"
                    Foreground="#D3A7FF"
                    FontFamily="Cascadia Mono"
                    FontSize="13"
                    FontWeight="Bold"
                    Text="PIN ----" />
            </Grid>
        </Grid>
    </Border>
</Window>
"@

$window = [Windows.Markup.XamlReader]::Parse($xaml)
$statusDot = $window.FindName("StatusDot")
$statusText = $window.FindName("StatusText")
$detailText = $window.FindName("DetailText")
$toggleButton = $window.FindName("ToggleButton")
$receiverNameText = $window.FindName("ReceiverNameText")
$authenticationText = $window.FindName("AuthenticationText")
$closeButton = $window.FindName("CloseButton")
$dragRegion = $window.FindName("DragRegion")
$brushConverter = [System.Windows.Media.BrushConverter]::new()
$stateBrushes = @{
    Missing = $brushConverter.ConvertFromString("#73737C")
    Disabled = $brushConverter.ConvertFromString("#73737C")
    Ready = $brushConverter.ConvertFromString("#66D28E")
    Casting = $brushConverter.ConvertFromString("#60A5FA")
    Error = $brushConverter.ConvertFromString("#F0A35A")
}
$script:lastState = $null
$script:actionInProgress = $false

function Update-Display {
    try {
        $state = Get-ReceiverState
        $script:lastState = $state
        $statusDot.Fill = $stateBrushes[$state.Kind]
        $statusText.Text = $state.Label
        $detailText.Text = $state.Detail
        $toggleButton.Content = $state.ButtonLabel
        $toggleButton.IsEnabled = $state.CanToggle -and
            -not $script:actionInProgress
        $receiverNameText.Text = $state.ReceiverName
        $pin = if ($state.IsEnabled) { Get-ReceiverPin } else { $null }
        $authenticationText.Text = switch ($state.Authentication) {
            "every-connection" {
                if ($pin) { "PIN $pin" } else { "PIN ----" }
            }
            "pair-once" {
                if ($pin) { "PIN $pin" } else { "PIN ----" }
            }
            "open" { "OPEN ACCESS" }
            default { "CUSTOM AUTH" }
        }
        if ($pin -and $state.Kind -ne "Casting") {
            $detailText.Text = "Enter the PIN shown below on the iPad"
        }
        $statusDot.ToolTip = $state.Label
    }
    catch {
        $script:lastState = $null
        $statusDot.Fill = $stateBrushes.Error
        $statusText.Text = "Status check failed"
        $detailText.Text = $_.Exception.Message
        $toggleButton.Content = "Unavailable"
        $toggleButton.IsEnabled = $false
    }
}

function Set-ReceiverEnabled {
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    if ($null -eq $script:lastState -or
        $null -eq $script:lastState.Runtime) {
        throw "The receiver runtime is not installed."
    }

    if ($Enabled) {
        if (-not (Test-Path `
                -LiteralPath $script:lastState.Runtime.launcher `
                -PathType Leaf)) {
            throw "The PIN host is missing. Run Install.cmd again."
        }
        $launcherArguments = @(
            "-NoProfile"
            "-WindowStyle"
            "Hidden"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            (ConvertTo-NativeQuotedArgument `
                -Value $script:lastState.Runtime.launcher)
            "-ReceiverExecutable"
            (ConvertTo-NativeQuotedArgument `
                -Value $script:lastState.Runtime.executable)
            "-WorkingDirectory"
            (ConvertTo-NativeQuotedArgument `
                -Value (Split-Path -Parent `
                    $script:lastState.Runtime.executable))
        )
        Start-Process `
            -FilePath $windowsPowerShellPath `
            -WindowStyle Hidden `
            -ArgumentList $launcherArguments | Out-Null
        return
    }

    foreach ($process in @($script:lastState.Processes)) {
        Stop-Process -Id $process.Id -ErrorAction Stop
    }
}

$toggleButton.Add_Click({
    if ($script:actionInProgress -or $null -eq $script:lastState) {
        return
    }

    $script:actionInProgress = $true
    $toggleButton.IsEnabled = $false
    $detailText.Text = $(if ($script:lastState.IsEnabled) {
            "Stopping receiver..."
        } else {
            "Starting receiver..."
        })
    try {
        Set-ReceiverEnabled -Enabled (-not $script:lastState.IsEnabled)
        Start-Sleep -Milliseconds 600
    }
    catch {
        [void][System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            "InkBeam",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
    finally {
        $script:actionInProgress = $false
        Update-Display
    }
})
$closeButton.Add_Click({ $window.Close() })
$dragRegion.Add_MouseLeftButtonDown({ $window.DragMove() })
$window.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::Escape) {
        $window.Close()
    }
})

function Set-WidgetPosition {
    param(
        [switch]$Force
    )

    $workArea = [System.Windows.SystemParameters]::WorkArea
    if (-not $Force) {
        $centreX = $window.Left + ($window.ActualWidth / 2)
        $centreY = $window.Top + ($window.ActualHeight / 2)
        if ($centreX -ge $workArea.Left -and
            $centreX -lt $workArea.Right -and
            $centreY -ge $workArea.Top -and
            $centreY -lt $workArea.Bottom) {
            return
        }
    }

    $window.Left = $workArea.Right - $window.ActualWidth - 18
    $window.Top = $workArea.Top + 18
    try {
        $root = [Windows.Automation.AutomationElement]::RootElement
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty,
            "Azure Context"
        )
        $azureWidget = $root.FindFirst(
            [Windows.Automation.TreeScope]::Children,
            $condition
        )
        if ($null -ne $azureWidget) {
            $azureBounds = $azureWidget.Current.BoundingRectangle
            $azureCentreX = $azureBounds.Left + ($azureBounds.Width / 2)
            $azureCentreY = $azureBounds.Top + ($azureBounds.Height / 2)
            if ($azureCentreX -ge $workArea.Left -and
                $azureCentreX -lt $workArea.Right -and
                $azureCentreY -ge $workArea.Top -and
                $azureCentreY -lt $workArea.Bottom) {
                $window.Top = $azureBounds.Bottom + 10
            }
            else {
                $window.Top += $azureBounds.Height + 10
            }
        }
    }
    catch {
        $window.Top = $workArea.Top + 18
    }
    $window.Top = [Math]::Min(
        $window.Top,
        $workArea.Bottom - $window.ActualHeight - 18
    )
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    Set-WidgetPosition
    if (-not $script:actionInProgress) {
        Update-Display
    }
})

$createdNew = $false
$mutex = [System.Threading.Mutex]::new(
    $true,
    "Local\iPadWhiteboardWidget",
    [ref]$createdNew
)
if (-not $createdNew) {
    $mutex.Dispose()
    return
}

try {
    $window.Add_Loaded({
        Set-WidgetPosition -Force
        Update-Display
        $timer.Start()
    })
    [void]$window.ShowDialog()
}
finally {
    $timer.Stop()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
