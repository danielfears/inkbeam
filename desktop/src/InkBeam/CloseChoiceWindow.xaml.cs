using System.Windows;
using System.Windows.Interop;
using System.Runtime.InteropServices;

namespace InkBeam;

public enum CloseChoice
{
    Cancel,
    MinimiseToTray,
    ExitAndStop
}

public partial class CloseChoiceWindow : Window
{
    private CloseChoice _choice;

    public CloseChoiceWindow()
    {
        InitializeComponent();
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

    public CloseChoice ShowChoice()
    {
        ShowDialog();
        return _choice;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        _choice = CloseChoice.Cancel;
        Close();
    }

    private void Tray_Click(object sender, RoutedEventArgs e)
    {
        _choice = CloseChoice.MinimiseToTray;
        Close();
    }

    private void Exit_Click(object sender, RoutedEventArgs e)
    {
        _choice = CloseChoice.ExitAndStop;
        Close();
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        nint window,
        int attribute,
        ref int value,
        int size);
}
