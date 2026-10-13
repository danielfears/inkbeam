using System.Runtime.InteropServices;
using System.Windows;
using InkBeam.Core;
using MessageBox = System.Windows.MessageBox;

namespace InkBeam;

public partial class App : System.Windows.Application
{
    internal const string ActivationPipeName = "InkBeamDesktopActivation";
    private const string MutexName = @"Local\InkBeam.Desktop.SingleInstance";
    private const string AppUserModelId = "InkBeam.Desktop";

    private SingleInstanceGate? _instanceGate;
    private ActivationPipeServer? _activationServer;
    private int _shutdownStarted;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        int appIdResult =
            SetCurrentProcessExplicitAppUserModelID(AppUserModelId);

        ArgumentParseResult arguments = ArgumentParseResult.Parse(e.Args);
        if (!arguments.IsValid)
        {
            MessageBox.Show(
                arguments.Error,
                "InkBeam",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(2);
            return;
        }

        if (arguments.Options.SelfTest)
        {
            DesktopSelfTestResult result =
                await DesktopSelfTest.RunAsync(AppUserModelId, appIdResult);
            SelfTestConsole.Write(result.Lines);
            Shutdown(result.ExitCode);
            return;
        }

        _instanceGate = new SingleInstanceGate(MutexName);
        if (!_instanceGate.IsPrimary)
        {
            bool activated = await ActivationPipeClient.TryActivateAsync(
                ActivationPipeName,
                TimeSpan.FromMilliseconds(1500));
            if (!activated)
            {
                MessageBox.Show(
                    "InkBeam is already running. Use its taskbar or notification-area icon to open it.",
                    "InkBeam",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }

            Shutdown();
            return;
        }

        AppPaths paths = new();
        MainWindow window = new(
            new ReceiverStatusService(paths, new ReceiverStatePipeClient()),
            new ControllerClient(paths),
            new StartupManager(paths));
        MainWindow = window;

        _activationServer = new ActivationPipeServer(
            ActivationPipeName,
            () => Dispatcher.InvokeAsync(window.ShowFromTray).Task);
        _activationServer.Start();
        await window.StartAsync(arguments.Options.Background);

        if (!arguments.Options.Background)
        {
            window.Show();
        }
    }

    internal async Task ShutdownApplicationAsync(int exitCode = 0)
    {
        if (Interlocked.Exchange(ref _shutdownStarted, 1) != 0)
        {
            return;
        }

        if (MainWindow is MainWindow window)
        {
            window.PrepareForShutdown();
        }

        if (_activationServer is not null)
        {
            await _activationServer.DisposeAsync();
            _activationServer = null;
        }

        _instanceGate?.Dispose();
        _instanceGate = null;
        Shutdown(exitCode);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _instanceGate?.Dispose();
        base.OnExit(e);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(
        string appId);
}
