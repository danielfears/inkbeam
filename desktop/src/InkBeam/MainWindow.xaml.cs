using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Interop;
using System.Runtime.InteropServices;
using InkBeam.Core;
using DrawingIcon = System.Drawing.Icon;
using Forms = System.Windows.Forms;
using MessageBox = System.Windows.MessageBox;

namespace InkBeam;

public partial class MainWindow : Window
{
    private static readonly IReadOnlyDictionary<
        ReceiverDisplayState,
        System.Windows.Media.Brush>
        StateBrushes =
            new Dictionary<ReceiverDisplayState, System.Windows.Media.Brush>
        {
            [ReceiverDisplayState.SetupRequired] = Brush("#94A3B8"),
            [ReceiverDisplayState.Disabled] = Brush("#64748B"),
            [ReceiverDisplayState.Starting] = Brush("#FBBF24"),
            [ReceiverDisplayState.Ready] = Brush("#34D399"),
            [ReceiverDisplayState.Pairing] = Brush("#FBBF24"),
            [ReceiverDisplayState.Casting] = Brush("#60A5FA"),
            [ReceiverDisplayState.Error] = Brush("#FB7185")
        };

    private readonly ReceiverStatusService _statusService;
    private readonly ControllerClient _controller;
    private readonly StartupManager _startupManager;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _uiAction = new(1, 1);
    private readonly Forms.NotifyIcon _trayIcon;
    private readonly Forms.ToolStripMenuItem _trayStatus;
    private readonly Forms.ToolStripMenuItem _trayEnable;
    private readonly Forms.ToolStripMenuItem _trayDisable;
    private Task? _refreshTask;
    private ReceiverSnapshot? _lastSnapshot;
    private bool _actionInProgress;
    private bool _isExiting;
    private bool _closeChoiceOpen;

    public MainWindow(
        ReceiverStatusService statusService,
        ControllerClient controller,
        StartupManager startupManager)
    {
        InitializeComponent();
        _statusService = statusService;
        _controller = controller;
        _startupManager = startupManager;

        _trayStatus = new Forms.ToolStripMenuItem("Status: checking…")
        {
            Enabled = false
        };
        Forms.ToolStripMenuItem showItem = new("Show InkBeam");
        _trayEnable = new Forms.ToolStripMenuItem("Enable receiver");
        _trayDisable = new Forms.ToolStripMenuItem("Disable receiver");
        Forms.ToolStripMenuItem exitItem = new("Exit InkBeam");

        showItem.Click += (_, _) => Dispatcher.Invoke(ShowFromTray);
        _trayEnable.Click += async (_, _) =>
            await Dispatcher.InvokeAsync(() => SetReceiverEnabledAsync(true)).Task.Unwrap();
        _trayDisable.Click += async (_, _) =>
            await Dispatcher.InvokeAsync(() => SetReceiverEnabledAsync(false)).Task.Unwrap();
        exitItem.Click += async (_, _) =>
            await Dispatcher.InvokeAsync(ExitApplicationAsync).Task.Unwrap();

        Forms.ContextMenuStrip menu = new();
        menu.Items.AddRange(
        [
            _trayStatus,
            new Forms.ToolStripSeparator(),
            showItem,
            _trayEnable,
            _trayDisable,
            new Forms.ToolStripSeparator(),
            exitItem
        ]);

        Stream iconStream = System.Windows.Application.GetResourceStream(
            new Uri("pack://application:,,,/Assets/InkBeam.ico")).Stream;
        using DrawingIcon sourceIcon = new(iconStream);
        _trayIcon = new Forms.NotifyIcon
        {
            Icon = (DrawingIcon)sourceIcon.Clone(),
            Text = "InkBeam",
            ContextMenuStrip = menu,
            Visible = true
        };
        iconStream.Dispose();
        _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowFromTray);

        string version = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion
            .Split('+')[0] ?? "unknown";
        VersionText.Text = $"Version {version}";
    }

    public async Task StartAsync(bool background)
    {
        await LoadSettingsAsync();
        _refreshTask = RefreshLoopAsync(_lifetime.Token);

        if (background)
        {
            _trayIcon.ShowBalloonTip(
                3500,
                "InkBeam is running",
                "Use the notification-area icon to show, enable, disable, or exit InkBeam.",
                Forms.ToolTipIcon.Info);
        }
    }

    public void ShowFromTray()
    {
        if (!IsVisible)
        {
            Show();
        }

        if (WindowState == WindowState.Minimized)
        {
            WindowState = WindowState.Normal;
        }

        ShowInTaskbar = true;
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
    }

    public void PrepareForShutdown()
    {
        _isExiting = true;
        _lifetime.Cancel();
        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        Close();
    }

    private void Window_SourceInitialized(object? sender, EventArgs e)
    {
        nint handle = new WindowInteropHelper(this).Handle;
        int darkMode = 1;
        int result = DwmSetWindowAttribute(
            handle, 20, ref darkMode, sizeof(int));
        if (result != 0)
        {
            _ = DwmSetWindowAttribute(
                handle, 19, ref darkMode, sizeof(int));
        }

        int captionColour = 0x00120B08;
        _ = DwmSetWindowAttribute(
            handle, 35, ref captionColour, sizeof(int));
        int captionTextColour = 0x00FFF3F5;
        _ = DwmSetWindowAttribute(
            handle, 36, ref captionTextColour, sizeof(int));
    }

    private async Task LoadSettingsAsync()
    {
        try
        {
            AppPaths paths = new();
            ReceiverConfiguration configuration =
                await ConfigurationReader.ReadAsync(
                    paths.ConfigurationPath,
                    _lifetime.Token);
            ApplyConfigurationToSettings(configuration);
            StartAtSignInCheckBox.IsChecked = _startupManager.GetPreference();
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or
            System.Text.Json.JsonException)
        {
            SettingsResultText.Text = exception.Message;
            SettingsResultText.Foreground = StateBrushes[ReceiverDisplayState.Error];
        }
    }

    private async Task RefreshLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            ReceiverSnapshot? snapshot = null;
            try
            {
                snapshot = await _statusService.GetSnapshotAsync(cancellationToken);
                await Dispatcher.InvokeAsync(() =>
                {
                    _lastSnapshot = snapshot;
                    if (!_actionInProgress)
                    {
                        ApplySnapshot(snapshot);
                    }
                });
            }
            catch (OperationCanceledException) when (
                cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                await Dispatcher.InvokeAsync(() =>
                    ApplyUnexpectedStatusError(exception.Message));
            }

            TimeSpan delay = snapshot?.State switch
            {
                ReceiverDisplayState.Pairing => TimeSpan.FromMilliseconds(350),
                ReceiverDisplayState.Starting => TimeSpan.FromMilliseconds(500),
                _ => TimeSpan.FromSeconds(1)
            };

            try
            {
                await Task.Delay(delay, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private void ApplySnapshot(ReceiverSnapshot snapshot)
    {
        StatusDot.Fill = StateBrushes[snapshot.State];
        StatusTitle.Text = snapshot.Label;
        StatusDetail.Text = snapshot.Detail;
        ReceiverNameLabel.Text = snapshot.Configuration.ReceiverName;
        AuthenticationLabel.Text = AuthenticationLabelFor(
            snapshot.Configuration.Authentication);

        PinPanel.Visibility =
            snapshot.State == ReceiverDisplayState.Pairing &&
            snapshot.Pin is not null
                ? Visibility.Visible
                : Visibility.Collapsed;
        PinText.Text = snapshot.Pin ?? "----";

        ToggleReceiverButton.Content = snapshot.IsReceiverRunning
            ? "Disable"
            : snapshot.CanEnable ? "Enable" : "Unavailable";
        ToggleReceiverButton.IsEnabled = snapshot.CanEnable && !_actionInProgress;

        ApplyPrerequisite(snapshot.Discovery, DiscoveryLabel, DiscoveryDetail);
        ApplyPrerequisite(snapshot.Network, NetworkLabel, NetworkDetail);

        _trayStatus.Text = $"Status: {snapshot.Label}";
        _trayEnable.Enabled =
            snapshot.CanEnable && !snapshot.IsReceiverRunning && !_actionInProgress;
        _trayDisable.Enabled =
            snapshot.CanEnable && snapshot.IsReceiverRunning && !_actionInProgress;
        _trayIcon.Text = $"InkBeam — {snapshot.Label}"[..Math.Min(
            63,
            $"InkBeam — {snapshot.Label}".Length)];
    }

    private static void ApplyPrerequisite(
        PrerequisiteStatus status,
        TextBlock label,
        TextBlock detail)
    {
        label.Text = status.Label;
        detail.Text = status.Detail;
        label.Foreground = status.State switch
        {
            PrerequisiteState.Available => Brush("#34D399"),
            PrerequisiteState.Unavailable => Brush("#FB7185"),
            _ => Brush("#FBBF24")
        };
    }

    private void ApplyUnexpectedStatusError(string message)
    {
        StatusDot.Fill = StateBrushes[ReceiverDisplayState.Error];
        StatusTitle.Text = "Status unavailable";
        StatusDetail.Text = message;
        ToggleReceiverButton.IsEnabled = false;
        _trayStatus.Text = "Status: unavailable";
        _trayEnable.Enabled = false;
        _trayDisable.Enabled = false;
    }

    private async void ToggleReceiver_Click(object sender, RoutedEventArgs e)
    {
        if (_lastSnapshot is null)
        {
            return;
        }

        await SetReceiverEnabledAsync(!_lastSnapshot.IsReceiverRunning);
    }

    private async Task SetReceiverEnabledAsync(bool enabled)
    {
        if (!await _uiAction.WaitAsync(0))
        {
            return;
        }

        try
        {
            SetBusy(true, enabled ? "Starting receiver…" : "Stopping receiver…");
            ControllerCommandResult result = enabled
                ? await _controller.StartAsync(_lifetime.Token)
                : await _controller.StopAsync(_lifetime.Token);
            if (!result.Success)
            {
                ShowControllerError(result.Message);
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
        }
        finally
        {
            SetBusy(false, null);
            _uiAction.Release();
        }
    }

    private async void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        if (!ReceiverNameValidator.IsValid(ReceiverNameTextBox.Text))
        {
            ShowControllerError(ReceiverNameValidator.ErrorMessage);
            return;
        }

        string authentication = SelectedAuthentication();
        if (authentication == "open")
        {
            MessageBoxResult confirmation = MessageBox.Show(
                "Open access removes the PIN requirement. Anyone on the permitted local network can request a connection.\n\nSave this setting?",
                "Confirm open access",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (confirmation != MessageBoxResult.Yes)
            {
                return;
            }
        }

        if (!await _uiAction.WaitAsync(0))
        {
            return;
        }

        try
        {
            SetBusy(true, "Saving settings…");
            ReceiverConfiguration configuration = new(
                ReceiverNameTextBox.Text,
                authentication,
                AudioCheckBox.IsChecked == true,
                FullscreenCheckBox.IsChecked == true);
            ControllerCommandResult result = await _controller.ConfigureAsync(
                configuration,
                _lifetime.Token);
            if (!result.Success)
            {
                ShowControllerError(result.Message);
                return;
            }

            _startupManager.SetPreference(StartAtSignInCheckBox.IsChecked == true);
            SettingsResultText.Text = "Settings saved.";
            SettingsResultText.Foreground =
                StateBrushes[ReceiverDisplayState.Ready];
        }
        catch (Exception exception) when (
            exception is UnauthorizedAccessException or IOException)
        {
            ShowControllerError(exception.Message);
        }
        finally
        {
            SetBusy(false, null);
            _uiAction.Release();
        }
    }

    private void ApplyConfigurationToSettings(ReceiverConfiguration configuration)
    {
        ReceiverNameTextBox.Text = configuration.ReceiverName;
        foreach (ComboBoxItem item in AuthenticationComboBox.Items)
        {
            if (string.Equals(
                    item.Tag as string,
                    configuration.Authentication,
                    StringComparison.Ordinal))
            {
                AuthenticationComboBox.SelectedItem = item;
                break;
            }
        }

        AudioCheckBox.IsChecked = configuration.AudioEnabled;
        FullscreenCheckBox.IsChecked = configuration.Fullscreen;
    }

    private string SelectedAuthentication() =>
        (AuthenticationComboBox.SelectedItem as ComboBoxItem)?.Tag as string ??
        "every-connection";

    private void Authentication_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (OpenAccessWarning is not null)
        {
            OpenAccessWarning.Visibility = SelectedAuthentication() == "open"
                ? Visibility.Visible
                : Visibility.Collapsed;
        }
    }

    private void SetBusy(bool busy, string? detail)
    {
        _actionInProgress = busy;
        ToggleReceiverButton.IsEnabled =
            !busy && (_lastSnapshot?.CanEnable ?? false);
        SaveSettingsButton.IsEnabled = !busy;
        HeaderExitButton.IsEnabled = !busy;
        _trayEnable.Enabled =
            !busy && (_lastSnapshot?.CanEnable ?? false) &&
            !(_lastSnapshot?.IsReceiverRunning ?? false);
        _trayDisable.Enabled =
            !busy && (_lastSnapshot?.CanEnable ?? false) &&
            (_lastSnapshot?.IsReceiverRunning ?? false);

        if (busy && detail is not null)
        {
            StatusDetail.Text = detail;
            SettingsResultText.Text = detail;
        }
        else if (_lastSnapshot is not null)
        {
            ApplySnapshot(_lastSnapshot);
        }
    }

    private void ShowControllerError(string message)
    {
        SettingsResultText.Text = message;
        SettingsResultText.Foreground =
            StateBrushes[ReceiverDisplayState.Error];
        MessageBox.Show(
            message,
            "InkBeam",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
    }

    private async void Exit_Click(object sender, RoutedEventArgs e) =>
        await ExitApplicationAsync();

    private async Task ExitApplicationAsync()
    {
        if (_actionInProgress || _isExiting)
        {
            return;
        }

        if (!await _uiAction.WaitAsync(0))
        {
            return;
        }

        try
        {
            SetBusy(true, "Stopping the receiver before exit…");
            if (_controller.IsInstalled)
            {
                ControllerCommandResult result =
                    await _controller.StopAsync(CancellationToken.None);
                if (!result.Success)
                {
                    ShowControllerError(
                        $"InkBeam is still running because the receiver could not be stopped.\n\n{result.Message}");
                    return;
                }
            }

            _isExiting = true;
            await ((App)System.Windows.Application.Current)
                .ShutdownApplicationAsync();
        }
        finally
        {
            if (!_isExiting)
            {
                SetBusy(false, null);
                _uiAction.Release();
            }
        }
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_isExiting)
        {
            return;
        }

        e.Cancel = true;
        if (_closeChoiceOpen)
        {
            return;
        }

        _closeChoiceOpen = true;
        try
        {
            CloseChoiceWindow choiceWindow = new() { Owner = this };
            CloseChoice choice = choiceWindow.ShowChoice();
            switch (choice)
            {
                case CloseChoice.MinimiseToTray:
                    ShowInTaskbar = false;
                    Hide();
                    _trayIcon.ShowBalloonTip(
                        3000,
                        "InkBeam is still running",
                        "Use the notification-area icon to show or exit InkBeam.",
                        Forms.ToolTipIcon.Info);
                    break;
                case CloseChoice.ExitAndStop:
                    _ = ExitApplicationAsync();
                    break;
            }
        }
        finally
        {
            _closeChoiceOpen = false;
        }
    }

    private static string AuthenticationLabelFor(string authentication) =>
        authentication switch
        {
            "every-connection" => "Fresh PIN for every connection",
            "pair-once" => "Pair once",
            "open" => "Open access — no PIN",
            _ => "Authentication unavailable"
        };

    private static SolidColorBrush Brush(string colour) =>
        new((System.Windows.Media.Color)
            System.Windows.Media.ColorConverter.ConvertFromString(colour));

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        nint window,
        int attribute,
        ref int value,
        int size);
}
