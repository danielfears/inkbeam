$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path @(
    (Join-Path $PSScriptRoot '..\scripts\ReceiverSession.cs'),
    (Join-Path $PSScriptRoot '..\scripts\ReceiverHost.cs')
) -ReferencedAssemblies System.dll, System.Core.dll, System.Web.Extensions.dll

$script:checks = 0
function Assert-State {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
    Write-Output "PASS: $Message"
}

$now = [DateTime]::UtcNow
$session = [IpadWhiteboard.ReceiverSession]::new()
$session.SetReceiverPid(42)
Assert-State ($session.Snapshot().state -eq 'Starting') 'A process is not falsely reported ready.'
$session.UpdateTransport($true, $false, $false, $now)
Assert-State ($session.Snapshot().state -eq 'Ready') 'The owned control listener establishes readiness.'
$session.ConsoleHistoryLost()
Assert-State ($session.Snapshot().state -eq 'Ready') 'Benign startup console resets do not create a false receiver error.'
$session.UpdateTransport($true, $true, $false, $now)
Assert-State ($session.Snapshot().state -eq 'Ready') 'An unauthenticated control connection is not casting.'
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "0123" AS AIRPLAY PASSWORD', $now)
Assert-State ($session.Snapshot().pin -ceq '0123') 'The first challenge is captured without losing leading zeroes.'
Assert-State ($session.Snapshot().state -eq 'Pairing') 'A challenge is explicitly a pairing state.'
$revision = $session.Snapshot().revision
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "9876" AS AIRPLAY PASSWORD', $now)
Assert-State ($session.Snapshot().pin -ceq '9876') 'A replacement challenge supersedes the old PIN immediately.'
Assert-State ($session.Snapshot().revision -gt $revision) 'A replacement challenge advances the snapshot revision.'
$session.ProcessLine('Client authentication failure', $now)
Assert-State ($session.Snapshot().pin -ceq '9876') 'An ordinary wrong entry does not invent or rotate a PIN.'
$session.ProcessLine('Too many authentication failures: generate new random password', $now)
Assert-State ($null -eq $session.Snapshot().pin) 'A pending rotation never presents an obsolete PIN.'
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "0000" AS AIRPLAY PASSWORD', $now)
Assert-State ($session.Snapshot().pin -ceq '0000') 'All-zero PINs remain valid four-digit challenges.'
$session.ProcessLine('Client authentication success', $now)
Assert-State ($null -eq $session.Snapshot().pin) 'An accepted PIN is erased immediately.'
Assert-State ($session.Snapshot().state -eq 'Pairing') 'Successful authentication alone does not claim a video stream.'
$session.ProcessLine('raop_rtp_mirror: SPS+PPS header size = 40', $now)
$session.UpdateTransport($true, $true, $true, $now)
Assert-State ($session.Snapshot().state -eq 'Casting') 'Actual video events and the mirror transport establish casting.'
Assert-State ($null -eq $session.Snapshot().pin) 'Casting never re-exposes a used PIN.'
$session.UpdateTransport($true, $false, $false, $now)
Assert-State ($session.Snapshot().state -eq 'Ready') 'Disconnect returns to readiness without retaining the challenge.'
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "2468" AS AIRPLAY PASSWORD', $now)
$session.UpdateTransport($true, $true, $false, $now)
$session.UpdateTransport($true, $false, $false, $now.AddMilliseconds(75))
Assert-State ($session.Snapshot().pin -ceq '2468') 'A short control-socket gap does not erase the pending PIN.'
Assert-State ($session.Snapshot().state -eq 'Pairing') 'The iPad PIN dialogue remains a pairing state between control requests.'
$session.ProcessLine('tcp socket was closed by client', $now.AddSeconds(1))
Assert-State ($session.Snapshot().pin -ceq '2468') 'A control-socket close event is not mistaken for PIN cancellation.'
$session.UpdateTransport($true, $false, $false, $now.AddSeconds(30))
Assert-State ($session.Snapshot().pin -ceq '2468') 'The current PIN remains visible long enough to enter it.'
$session.UpdateTransport($true, $true, $false, $now.AddSeconds(31))
$session.ProcessLine('Client authentication success', $now.AddSeconds(32))
Assert-State ($null -eq $session.Snapshot().pin) 'A PIN accepted after a control reconnect is erased immediately.'
$session.UpdateTransport($true, $false, $false, $now.AddSeconds(33))
Assert-State ($session.Snapshot().state -eq 'Ready') 'An accepted challenge is not retained across a later disconnect.'
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "2468" AS AIRPLAY PASSWORD', $now)
$session.UpdateTransport($true, $true, $false, $now)
$session.UpdateTransport($true, $false, $false, $now.AddMinutes(3))
Assert-State ($null -eq $session.Snapshot().pin -and $session.Snapshot().state -eq 'Ready') 'An abandoned challenge expires even after a previously observed control connection.'
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "1357" AS AIRPLAY PASSWORD', $now)
$session.ProcessLine('authentication rejected (nonce mismatch)', $now)
Assert-State ($session.Snapshot().state -eq 'Error') 'A changed pairing challenge is reported explicitly.'
Assert-State ($null -eq $session.Snapshot().pin) 'Nonce errors do not retain a misleading PIN.'
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "12345" AS AIRPLAY PASSWORD', $now)
Assert-State ($null -eq $session.Snapshot().pin) 'Malformed challenge lengths are never accepted.'
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "2468" AS AIRPLAY PASSWORD', $now)
$session.UpdateTransport($true, $false, $false, $now.AddMinutes(3))
Assert-State ($null -eq $session.Snapshot().pin) 'An abandoned challenge expires without a live control connection.'
$session.ProcessLine('*** CLIENT MUST NOW ENTER PIN = "2468" AS AIRPLAY PASSWORD', $now)
$session.UpdateTransport($true, $true, $false, $now.AddMinutes(3))
Assert-State ($session.Snapshot().pin -ceq '2468') 'A still-connected pairing dialogue is not expired prematurely.'
$session.ConsoleHistoryLost()
Assert-State ($session.Snapshot().state -eq 'Error' -and $null -eq $session.Snapshot().pin) 'Missing console history fails closed.'
Assert-State ($session.Snapshot().receiverPid -eq 42) 'The state snapshot identifies the owned receiver process.'
$json = [System.Web.Script.Serialization.JavaScriptSerializer]::new().Serialize($session.Snapshot())
Assert-State (($json | ConvertFrom-Json).version -eq 1) 'The named-pipe payload has a versioned JSON shape.'

$transcript = [IpadWhiteboard.ConsoleTranscript]::new()
$first = $transcript.ReadNewLines([string[]]@('startup', 'challenge A'))
Assert-State ($first.Count -eq 2) 'Initial completed events are read once.'
$again = $transcript.ReadNewLines([string[]]@('startup', 'challenge A'))
Assert-State ($again.Count -eq 0) 'Polling cannot replay an old PIN challenge.'
$next = $transcript.ReadNewLines([string[]]@('startup', 'challenge A', 'success'))
Assert-State ($next.Count -eq 1 -and $next[0] -eq 'success') 'Only newly completed output advances pairing.'
$scroll = $transcript.ReadNewLines([string[]]@('challenge A', 'success', 'challenge B'))
Assert-State ($scroll.Count -eq 1 -and $scroll[0] -eq 'challenge B') 'Console scrolling preserves the newest challenge.'
Assert-State (-not $transcript.HistoryLost) 'Overlapping console history is not falsely rejected.'
$lost = $transcript.ReadNewLines([string[]]@('unrelated new buffer'))
Assert-State ($transcript.HistoryLost) 'A cleared or overwritten console is detected instead of guessed.'

Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class InkBeamConsoleFixture : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Coord
    {
        public short X, Y;
        public Coord(short x, short y) { X = x; Y = y; }
    }
    private readonly bool allocated;
    public IntPtr Handle { get; private set; }
    public InkBeamConsoleFixture()
    {
        FreeConsole();
        if (!AllocConsole()) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
        allocated = true;
        ShowWindow(GetConsoleWindow(), 0);
        try
        {
            Handle = CreateConsoleScreenBuffer(0xC0000000, 3, IntPtr.Zero, 1, IntPtr.Zero);
            if (Handle == new IntPtr(-1)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            if (!SetConsoleScreenBufferSize(Handle, new Coord(512, 64)))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            WriteRow(0, new String('A', 512));
            WriteRow(1, "Unicode fixture \u03c0");
            if (!SetConsoleCursorPosition(Handle, new Coord(0, 2)))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        catch { Dispose(); throw; }
    }
    private void WriteRow(short row, string text)
    {
        uint written;
        if (!WriteConsoleOutputCharacter(Handle, text, (uint)text.Length,
            new Coord(0, row), out written) || written != text.Length)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
    public void Dispose()
    {
        if (Handle != IntPtr.Zero && Handle != new IntPtr(-1))
        {
            CloseHandle(Handle);
            Handle = IntPtr.Zero;
        }
        if (allocated) { FreeConsole(); }
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AllocConsole();
    [DllImport("kernel32.dll")] private static extern bool FreeConsole();
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateConsoleScreenBuffer(uint access, uint share, IntPtr security, uint flags, IntPtr data);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleScreenBufferSize(IntPtr output, Coord size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCursorPosition(IntPtr output, Coord position);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WriteConsoleOutputCharacter(IntPtr output, string text, uint count, Coord start, out uint written);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
'@
$fixture = [InkBeamConsoleFixture]::new()
$hostReader = [IpadWhiteboard.ReceiverHost]::new('unused', 'unused')
$flags = [Reflection.BindingFlags]'Instance,NonPublic'
$handleField = $hostReader.GetType().GetField('consoleOutput', $flags)
$readRows = $hostReader.GetType().GetMethod('ReadCompletedRows', $flags)
try {
    $handleField.SetValue($hostReader, $fixture.Handle)
    $nativeTranscript = [IpadWhiteboard.ConsoleTranscript]::new()
    foreach ($iteration in 1..20) {
        $rows = $readRows.Invoke($hostReader, @())
        Assert-State ($rows.Count -eq 2 -and $rows[0] -ceq ('A' * 512) -and
            $rows[1] -ceq ("Unicode fixture " + [char]0x03c0)) "Native console read $iteration preserves counted characters without a terminator."
        $fresh = $nativeTranscript.ReadNewLines($rows)
        Assert-State (-not $nativeTranscript.HistoryLost -and
            $fresh.Count -eq $(if ($iteration -eq 1) { 2 } else { 0 })) "Native console read $iteration does not invent lost history or replay output."
    }
}
finally {
    $handleField.SetValue($hostReader, [IntPtr]::new(-1))
    $hostReader.Dispose()
    $fixture.Dispose()
}

Write-Output "All $script:checks receiver-state checks passed."
