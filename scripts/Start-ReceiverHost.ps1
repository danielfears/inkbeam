#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ReceiverExecutable,
    [string]$WorkingDirectory,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace IpadWhiteboard
{
    public sealed class ReceiverHost : IDisposable
    {
        private const int SwHide = 0;
        private const int GlyphMargin = 10;
        private const int GlyphWidth = 10;
        private const int GlyphGap = 3;
        private const int GlyphRows = 8;
        private const string PixelMap = " 8dbPYo\".";

        private static readonly string[][] DigitCodes =
        {
            new[] { "0821111380", "2114005113", "1110000111", "1110000111", "1110000111", "1110000111", "5113002114", "0751111470" },
            new[] { "0002111000", "0021111000", "0000111000", "0000111000", "0000111000", "0000111000", "0000111000", "0011111110" },
            new[] { "0811112800", "2114005113", "0000000111", "0000082114", "0862111470", "2114700000", "1117000000", "1111111111" },
            new[] { "0821111380", "2114005113", "0000082114", "0000111170", "0000075130", "1110000111", "5113002114", "0751111470" },
            new[] { "0000211110", "0001401110", "0021401110", "0214001110", "2110001110", "1111111111", "0000001110", "0000001110" },
            new[] { "1111111110", "1110000000", "1110000000", "1112111380", "0000075113", "0000000111", "5113002114", "0711114700" },
            new[] { "0821111380", "2114005113", "1110000000", "1112111380", "1114075113", "1110000111", "5113002114", "0751111470" },
            new[] { "1111111111", "0000002114", "0000021140", "0000211400", "0002114000", "0021140000", "0211400000", "2114000000" },
            new[] { "0831111280", "2114002114", "5113802114", "0751111170", "8214775138", "1110000111", "5113002114", "0751111470" },
            new[] { "0821111380", "2114005113", "1110000111", "5113802111", "0751114111", "0000000111", "5113002114", "0751111470" }
        };

        private readonly string executable;
        private readonly string workingDirectory;
        private readonly string pipeName;
        private readonly object pinLock = new object();
        private volatile bool stopping;
        private Process receiver;
        private Thread monitorThread;
        private Thread pipeThread;
        private volatile NamedPipeServerStream activePipe;
        private string currentPin = String.Empty;

        public ReceiverHost(string executable, string workingDirectory, string pipeName)
        {
            this.executable = executable;
            this.workingDirectory = workingDirectory;
            this.pipeName = pipeName;
        }

        public int Run()
        {
            IntPtr consoleWindow = GetConsoleWindow();
            if (consoleWindow != IntPtr.Zero)
            {
                ShowWindow(consoleWindow, SwHide);
            }

            StartPipeServer();

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = executable;
            startInfo.WorkingDirectory = workingDirectory;
            startInfo.UseShellExecute = false;

            receiver = Process.Start(startInfo);
            if (receiver == null)
            {
                throw new InvalidOperationException("Unable to start the receiver process.");
            }

            monitorThread = new Thread(MonitorConsole);
            monitorThread.IsBackground = true;
            monitorThread.Name = "InkBeam PIN monitor";
            monitorThread.Start();

            receiver.WaitForExit();
            return receiver.ExitCode;
        }

        public static string DecodeFixtureForTest()
        {
            string[] rows =
            {
                "             d888       .8888d.      .d8888b.        d8888    ",
                "            d8888      d88P  Y88b   d88P  Y88b      8P 888    ",
                "              888             888        .d88P     d8P 888    ",
                "              888           .d88P       8888\"     d8P  888    ",
                "              888       .od888P\"         \"Y8b    d88   888    ",
                "              888      d88P\"        888    888   8888888888   ",
                "              888      888\"         Y88b  d88P         888    ",
                "            8888888    8888888888    \"Y8888P\"          888    "
            };
            return DecodeRows(rows, 0);
        }

        private void StartPipeServer()
        {
            pipeThread = new Thread(PipeLoop);
            pipeThread.IsBackground = true;
            pipeThread.Name = "InkBeam PIN pipe";
            pipeThread.Start();
        }

        private void PipeLoop()
        {
            while (!stopping)
            {
                try
                {
                    PipeSecurity security = new PipeSecurity();
                    SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
                    security.AddAccessRule(new PipeAccessRule(
                        user,
                        PipeAccessRights.ReadWrite,
                        AccessControlType.Allow
                    ));

                    using (NamedPipeServerStream pipe = new NamedPipeServerStream(
                        pipeName,
                        PipeDirection.Out,
                        1,
                        PipeTransmissionMode.Byte,
                        PipeOptions.None,
                        256,
                        256,
                        security
                    ))
                    {
                        activePipe = pipe;
                        pipe.WaitForConnection();
                        if (stopping)
                        {
                            return;
                        }

                        string pin;
                        lock (pinLock)
                        {
                            pin = currentPin;
                        }
                        using (StreamWriter writer = new StreamWriter(
                            pipe,
                            new UTF8Encoding(false),
                            256,
                            true
                        ))
                        {
                            writer.WriteLine(pin);
                            writer.Flush();
                        }
                    }
                }
                catch (ObjectDisposedException)
                {
                    if (!stopping)
                    {
                        throw;
                    }
                }
                catch (IOException)
                {
                    if (!stopping)
                    {
                        Thread.Sleep(100);
                    }
                }
                finally
                {
                    activePipe = null;
                }
            }
        }

        private void MonitorConsole()
        {
            while (!stopping && receiver != null && !receiver.HasExited)
            {
                List<string> rows = ReadConsoleRows();
                for (int index = 0; index <= rows.Count - GlyphRows; index++)
                {
                    string pin = DecodeRows(rows, index);
                    if (pin != null)
                    {
                        lock (pinLock)
                        {
                            currentPin = pin;
                        }
                    }
                }
                Thread.Sleep(150);
            }
        }

        private static List<string> ReadConsoleRows()
        {
            List<string> rows = new List<string>();
            IntPtr output = CreateFile(
                "CONOUT$",
                GenericRead,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                0,
                IntPtr.Zero
            );
            if (output == IntPtr.Zero || output == new IntPtr(-1))
            {
                return rows;
            }

            try
            {
                ConsoleScreenBufferInfo information;
                if (!GetConsoleScreenBufferInfo(output, out information))
                {
                    return rows;
                }

                int width = information.Size.X;
                int endRow = information.CursorPosition.Y;
                int startRow = Math.Max(0, endRow - 48);
                for (int row = startRow; row <= endRow; row++)
                {
                    StringBuilder line = new StringBuilder(width);
                    uint charactersRead;
                    if (ReadConsoleOutputCharacter(
                            output,
                            line,
                            (uint)width,
                            new Coord(0, (short)row),
                            out charactersRead
                        ))
                    {
                        rows.Add(line.ToString());
                    }
                }
                return rows;
            }
            finally
            {
                CloseHandle(output);
            }
        }

        private static string DecodeRows(IList<string> rows, int startIndex)
        {
            if (rows.Count - startIndex < GlyphRows)
            {
                return null;
            }

            int requiredLength = GlyphMargin + 4 * (GlyphWidth + GlyphGap) - GlyphGap;
            for (int row = 0; row < GlyphRows; row++)
            {
                if (rows[startIndex + row].Length < requiredLength)
                {
                    return null;
                }
            }

            StringBuilder pin = new StringBuilder(4);
            for (int position = 0; position < 4; position++)
            {
                int offset = GlyphMargin + position * (GlyphWidth + GlyphGap);
                int matchedDigit = -1;
                for (int digit = 0; digit < 10; digit++)
                {
                    bool matches = true;
                    for (int row = 0; row < GlyphRows; row++)
                    {
                        string actual = rows[startIndex + row].Substring(
                            offset,
                            GlyphWidth
                        );
                        string expected = RenderCode(DigitCodes[digit][row]);
                        if (!String.Equals(actual, expected, StringComparison.Ordinal))
                        {
                            matches = false;
                            break;
                        }
                    }
                    if (matches)
                    {
                        matchedDigit = digit;
                        break;
                    }
                }
                if (matchedDigit < 0)
                {
                    return null;
                }
                pin.Append((char)('0' + matchedDigit));
            }
            return pin.ToString();
        }

        private static string RenderCode(string code)
        {
            StringBuilder rendered = new StringBuilder(code.Length);
            foreach (char value in code)
            {
                rendered.Append(PixelMap[value - '0']);
            }
            return rendered.ToString();
        }

        public void Dispose()
        {
            stopping = true;

            NamedPipeServerStream pipe = activePipe;
            if (pipe != null)
            {
                pipe.Dispose();
            }

            if (receiver != null && !receiver.HasExited)
            {
                receiver.Kill();
                receiver.WaitForExit();
            }
            if (monitorThread != null && monitorThread.IsAlive)
            {
                monitorThread.Join(1000);
            }
            if (pipeThread != null && pipeThread.IsAlive)
            {
                pipeThread.Join(1000);
            }
            if (receiver != null)
            {
                receiver.Dispose();
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Coord
        {
            public short X;
            public short Y;

            public Coord(short x, short y)
            {
                X = x;
                Y = y;
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SmallRect
        {
            public short Left;
            public short Top;
            public short Right;
            public short Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ConsoleScreenBufferInfo
        {
            public Coord Size;
            public Coord CursorPosition;
            public short Attributes;
            public SmallRect Window;
            public Coord MaximumWindowSize;
        }

        private const uint GenericRead = 0x80000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenExisting = 3;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleScreenBufferInfo(
            IntPtr consoleOutput,
            out ConsoleScreenBufferInfo information
        );

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ReadConsoleOutputCharacter(
            IntPtr consoleOutput,
            [Out] StringBuilder characters,
            uint length,
            Coord readCoordinate,
            out uint charactersRead
        );

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr window, int command);
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp

if ($SelfTest) {
    $decoded = [IpadWhiteboard.ReceiverHost]::DecodeFixtureForTest()
    if ($decoded -ne '1234') {
        throw "PIN decoder self-test failed."
    }
    Write-Output 'PIN decoder self-test passed.'
    return
}

if (-not (Test-Path -LiteralPath $ReceiverExecutable -PathType Leaf)) {
    throw "Receiver executable not found: $ReceiverExecutable"
}
if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    throw "Receiver working directory not found: $WorkingDirectory"
}

$createdNew = $false
$mutex = [Threading.Mutex]::new(
    $true,
    'Local\iPadWhiteboardReceiverHost',
    [ref]$createdNew
)
if (-not $createdNew) {
    $mutex.Dispose()
    return
}

$hostProcess = [IpadWhiteboard.ReceiverHost]::new(
    $ReceiverExecutable,
    $WorkingDirectory,
    'iPadWhiteboardPin'
)

try {
    exit $hostProcess.Run()
}
finally {
    $hostProcess.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
