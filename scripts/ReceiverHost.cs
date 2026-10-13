using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace IpadWhiteboard
{
    public sealed class ConsoleTranscript
    {
        private List<string> previous = new List<string>();
        public bool HistoryLost { get; private set; }

        public IList<string> ReadNewLines(IList<string> snapshot)
        {
            int overlap = Math.Min(previous.Count, snapshot.Count);
            while (overlap > 0)
            {
                bool matches = true;
                for (int index = 0; index < overlap; index++)
                {
                    if (previous[previous.Count - overlap + index] != snapshot[index])
                    {
                        matches = false;
                        break;
                    }
                }
                if (matches) { break; }
                overlap--;
            }
            HistoryLost = previous.Count > 0 && overlap == 0;
            List<string> fresh = new List<string>();
            for (int index = overlap; index < snapshot.Count; index++)
            {
                fresh.Add(snapshot[index]);
            }
            previous = new List<string>(snapshot);
            return fresh;
        }
    }

    public sealed class ReceiverHost : IDisposable
    {
        private readonly string executable;
        private readonly string workingDirectory;
        private readonly ReceiverSession session = new ReceiverSession();
        private readonly object pipeGate = new object();
        private readonly List<NamedPipeServerStream> pipes = new List<NamedPipeServerStream>();
        private readonly List<Thread> threads = new List<Thread>();
        private volatile bool stopping;
        private Process receiver;
        private IntPtr consoleOutput = new IntPtr(-1);
        private IntPtr job;

        public ReceiverHost(string executable, string workingDirectory)
        {
            this.executable = executable;
            this.workingDirectory = workingDirectory;
        }

        public int Run()
        {
            // UxPlay reopens CONOUT$, so redirected stdout cannot capture its pairing events.
            FreeConsole();
            if (!AllocConsole()) { throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create the receiver console."); }
            ShowWindow(GetConsoleWindow(), 0);
            consoleOutput = CreateFile("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (consoleOutput == new IntPtr(-1)) { throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open the receiver console."); }
            if (!SetConsoleScreenBufferSize(consoleOutput, new Coord(512, 4000)))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot prepare the receiver status buffer.");
            }

            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create receiver lifetime ownership."); }
            JobLimits limits = new JobLimits();
            limits.Basic.LimitFlags = 0x2000;
            int size = Marshal.SizeOf(typeof(JobLimits));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, buffer, false);
                if (!SetInformationJobObject(job, 9, buffer, (uint)size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot bind receiver lifetime.");
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }

            receiver = Process.Start(new ProcessStartInfo
            {
                FileName = executable,
                WorkingDirectory = workingDirectory,
                UseShellExecute = false
            });
            if (receiver == null) { throw new InvalidOperationException("Unable to start the receiver."); }
            if (!AssignProcessToJobObject(job, receiver.Handle))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot own the receiver process.");
            }
            session.SetReceiverPid(receiver.Id);
            StartThread(delegate { PipeLoop("InkBeamReceiverState", false); }, "InkBeam receiver state");
            StartThread(delegate { PipeLoop("iPadWhiteboardPin", true); }, "InkBeam legacy PIN");
            StartThread(Monitor, "InkBeam pairing events");
            receiver.WaitForExit();
            return receiver.ExitCode;
        }

        private void StartThread(ThreadStart action, string name)
        {
            Thread thread = new Thread(action);
            thread.IsBackground = true;
            thread.Name = name;
            threads.Add(thread);
            thread.Start();
        }

        private void PipeLoop(string name, bool legacyPin)
        {
            while (!stopping)
            {
                NamedPipeServerStream pipe = null;
                try
                {
                    PipeSecurity security = new PipeSecurity();
                    security.SetAccessRuleProtection(true, false);
                    security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User,
                        PipeAccessRights.FullControl, AccessControlType.Allow));
                    pipe = new NamedPipeServerStream(name, PipeDirection.Out, 1,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 4096, security);
                    lock (pipeGate) { pipes.Add(pipe); }
                    IAsyncResult pending = pipe.BeginWaitForConnection(null, null);
                    using (WaitHandle wait = pending.AsyncWaitHandle)
                    {
                        while (!stopping && !wait.WaitOne(200)) { }
                        if (stopping) { return; }
                        pipe.EndWaitForConnection(pending);
                    }
                    ReceiverSnapshot snapshot = session.Snapshot();
                    string text = legacyPin ? (snapshot.pin ?? String.Empty) :
                        new JavaScriptSerializer().Serialize(snapshot);
                    byte[] bytes = new UTF8Encoding(false).GetBytes(text + "\n");
                    var write = pipe.WriteAsync(bytes, 0, bytes.Length);
                    if (!write.Wait(1000)) { throw new IOException("Status client did not read its response."); }
                    write.GetAwaiter().GetResult();
                }
                catch (ObjectDisposedException)
                {
                    if (!stopping) { session.HostFailed("The receiver status pipe was interrupted."); }
                }
                catch (IOException)
                {
                    // A client may disconnect while a snapshot is being written.
                    if (!stopping) { Thread.Sleep(50); }
                }
                catch (UnauthorizedAccessException)
                {
                    session.HostFailed("Another process owns the receiver status pipe. Disable and enable InkBeam.");
                    return;
                }
                catch (AggregateException)
                {
                    if (!stopping) { Thread.Sleep(50); }
                }
                finally
                {
                    if (pipe != null)
                    {
                        lock (pipeGate) { pipes.Remove(pipe); }
                        pipe.Dispose();
                    }
                }
            }
        }

        private void Monitor()
        {
            ConsoleTranscript transcript = new ConsoleTranscript();
            try
            {
                while (!stopping && !receiver.HasExited)
                {
                    IList<string> fresh = transcript.ReadNewLines(ReadCompletedRows());
                    if (transcript.HistoryLost) { session.ConsoleHistoryLost(); }
                    else
                    {
                        foreach (string line in fresh) { session.ProcessLine(line, DateTime.UtcNow); }
                    }
                    Transport transport = ReadTransport(receiver.Id);
                    session.UpdateTransport(transport.Listening, transport.Control,
                        transport.Mirror, DateTime.UtcNow);
                    Thread.Sleep(75);
                }
            }
            catch (Win32Exception)
            {
                session.HostFailed("Windows could not read receiver status. Disable and enable the receiver.");
            }
            catch (InvalidOperationException)
            {
                if (!stopping) { session.HostFailed("The receiver stopped responding."); }
            }
        }

        private IList<string> ReadCompletedRows()
        {
            ConsoleInfo information;
            if (!GetConsoleScreenBufferInfo(consoleOutput, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            List<string> rows = new List<string>();
            int last = information.Cursor.Y;
            for (int row = Math.Max(0, last - 128); row < last; row++)
            {
                char[] text = new char[information.Size.X];
                uint read;
                if (!ReadConsoleOutputCharacter(consoleOutput, text,
                    (uint)information.Size.X, new Coord(0, (short)row), out read))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                rows.Add(new String(text, 0, checked((int)read)).TrimEnd());
            }
            return rows;
        }

        private static Transport ReadTransport(int pid)
        {
            Transport result = new Transport();
            foreach (uint family in new uint[] { 2, 23 })
            {
                int size = 0;
                uint code = GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 5, 0);
                if (code != 122 && code != 0) { throw new Win32Exception((int)code); }
                IntPtr table = Marshal.AllocHGlobal(size);
                try
                {
                    code = GetExtendedTcpTable(table, ref size, false, family, 5, 0);
                    if (code != 0) { throw new Win32Exception((int)code); }
                    int count = Marshal.ReadInt32(table);
                    int rowSize = family == 2 ? 24 : 56;
                    for (int index = 0; index < count; index++)
                    {
                        IntPtr row = new IntPtr(table.ToInt64() + 4 + index * rowSize);
                        int owner = Marshal.ReadInt32(row, family == 2 ? 20 : 52);
                        if (owner != pid) { continue; }
                        int state = Marshal.ReadInt32(row, family == 2 ? 0 : 48);
                        int encoded = Marshal.ReadInt32(row, family == 2 ? 8 : 20);
                        int port = ((encoded & 255) << 8) | ((encoded >> 8) & 255);
                        if (port == 7101 && state == 2) { result.Listening = true; }
                        if (port == 7101 && state == 5) { result.Control = true; }
                        if (port == 7100 && state == 5) { result.Mirror = true; }
                    }
                }
                finally { Marshal.FreeHGlobal(table); }
            }
            return result;
        }

        public void Dispose()
        {
            stopping = true;
            lock (pipeGate)
            {
                foreach (NamedPipeServerStream pipe in pipes) { pipe.Dispose(); }
            }
            if (receiver != null && !receiver.HasExited)
            {
                receiver.Kill();
                receiver.WaitForExit(5000);
            }
            foreach (Thread thread in threads)
            {
                if (thread.IsAlive) { thread.Join(1500); }
            }
            if (receiver != null) { receiver.Dispose(); }
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (consoleOutput != new IntPtr(-1)) { CloseHandle(consoleOutput); consoleOutput = new IntPtr(-1); }
        }

        private struct Transport { public bool Listening; public bool Control; public bool Mirror; }
        [StructLayout(LayoutKind.Sequential)]
        private struct Coord
        {
            public short X, Y;
            public Coord(short x, short y) { X = x; Y = y; }
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Rect { public short Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ConsoleInfo
        {
            public Coord Size, Cursor;
            public short Attributes;
            public Rect Window;
            public Coord Maximum;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimits
        {
            public long ProcessTime, JobTime;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)]
        private struct JobLimits
        {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AllocConsole();
        [DllImport("kernel32.dll")] private static extern bool FreeConsole();
        [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleScreenBufferSize(IntPtr output, Coord size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetConsoleScreenBufferInfo(IntPtr output, out ConsoleInfo info);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ReadConsoleOutputCharacter(IntPtr output, [Out] char[] text, uint count, Coord start, out uint read);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int type, IntPtr information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("iphlpapi.dll")] private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool ordered, uint family, int type, uint reserved);
    }
}
