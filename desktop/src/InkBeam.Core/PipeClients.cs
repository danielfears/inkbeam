using System.IO.Pipes;
using System.Text;

namespace InkBeam.Core;

internal static class BoundedPipeLine
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static async Task<string?> ReadAsync(
        Stream stream,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        byte[] data = new byte[maximumBytes + 1];
        int length = 0;

        while (length <= maximumBytes)
        {
            int read = await stream.ReadAsync(
                data.AsMemory(length, 1),
                cancellationToken);
            if (read == 0)
            {
                break;
            }

            if (data[length] == (byte)'\n')
            {
                int textLength = length;
                if (textLength > 0 && data[textLength - 1] == (byte)'\r')
                {
                    textLength--;
                }

                return StrictUtf8.GetString(data, 0, textLength);
            }

            length++;
        }

        if (length == 0)
        {
            return null;
        }

        if (length > maximumBytes)
        {
            throw new InvalidDataException("The named-pipe response was too large.");
        }

        return StrictUtf8.GetString(data, 0, length);
    }
}

public sealed class ReceiverStatePipeClient(
    string pipeName = "InkBeamReceiverState",
    TimeSpan? connectTimeout = null,
    TimeSpan? readTimeout = null)
{
    private readonly TimeSpan _connectTimeout =
        connectTimeout ?? TimeSpan.FromMilliseconds(180);
    private readonly TimeSpan _readTimeout =
        readTimeout ?? TimeSpan.FromMilliseconds(220);

    public async Task<ReceiverStateMessage?> TryReadAsync(
        CancellationToken cancellationToken)
    {
        try
        {
            using NamedPipeClientStream pipe = new(
                ".",
                pipeName,
                PipeDirection.In,
                PipeOptions.Asynchronous);

            using CancellationTokenSource connectDeadline =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connectDeadline.CancelAfter(_connectTimeout);
            await pipe.ConnectAsync(connectDeadline.Token);

            using CancellationTokenSource readDeadline =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            readDeadline.CancelAfter(_readTimeout);
            string? line = await BoundedPipeLine.ReadAsync(
                pipe,
                4096,
                readDeadline.Token);

            return line is not null &&
                ReceiverStateProtocol.TryParse(line, out ReceiverStateMessage? state, out _)
                    ? state
                    : null;
        }
        catch (Exception exception) when (
            exception is TimeoutException or
            OperationCanceledException or
            IOException or
            UnauthorizedAccessException or
            DecoderFallbackException)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                throw new OperationCanceledException(cancellationToken);
            }

            return null;
        }
    }
}

public sealed class SingleInstanceGate : IDisposable
{
    private readonly Mutex _mutex;
    private readonly bool _ownsMutex;

    public SingleInstanceGate(string mutexName)
    {
        _mutex = new Mutex(true, mutexName, out bool createdNew);
        _ownsMutex = createdNew;
        IsPrimary = createdNew;
    }

    public bool IsPrimary { get; }

    public void Dispose()
    {
        if (_ownsMutex)
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
            }
        }

        _mutex.Dispose();
    }
}

public sealed class ActivationPipeServer : IAsyncDisposable
{
    private readonly string _pipeName;
    private readonly Func<Task> _activate;
    private readonly CancellationTokenSource _shutdown = new();
    private Task? _listenTask;

    public ActivationPipeServer(string pipeName, Func<Task> activate)
    {
        _pipeName = pipeName;
        _activate = activate;
    }

    public void Start()
    {
        _listenTask ??= ListenAsync(_shutdown.Token);
    }

    private async Task ListenAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await using NamedPipeServerStream server = new(
                    _pipeName,
                    PipeDirection.In,
                    1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(cancellationToken);

                using CancellationTokenSource readDeadline =
                    CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                readDeadline.CancelAfter(TimeSpan.FromSeconds(1));
                string? command = await BoundedPipeLine.ReadAsync(
                    server,
                    64,
                    readDeadline.Token);
                if (string.Equals(command, "activate", StringComparison.Ordinal))
                {
                    await _activate();
                }
            }
            catch (OperationCanceledException) when (
                cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (IOException)
            {
                await Task.Delay(100, cancellationToken);
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        if (_listenTask is not null)
        {
            try
            {
                await _listenTask;
            }
            catch (OperationCanceledException)
            {
            }
        }

        _shutdown.Dispose();
    }
}

public static class ActivationPipeClient
{
    public static async Task<bool> TryActivateAsync(
        string pipeName,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        try
        {
            using NamedPipeClientStream client = new(
                ".",
                pipeName,
                PipeDirection.Out,
                PipeOptions.Asynchronous);
            using CancellationTokenSource deadline =
                CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(timeout);

            await client.ConnectAsync(deadline.Token);
            byte[] command = Encoding.UTF8.GetBytes("activate\n");
            await client.WriteAsync(command, deadline.Token);
            await client.FlushAsync(deadline.Token);
            return true;
        }
        catch (Exception exception) when (
            exception is TimeoutException or
            OperationCanceledException or
            IOException or
            UnauthorizedAccessException)
        {
            return false;
        }
    }
}

