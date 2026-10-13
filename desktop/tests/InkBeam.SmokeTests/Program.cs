using System.IO.Pipes;
using System.Text;
using InkBeam.Core;

namespace InkBeam.SmokeTests;

internal static class Program
{
    private static readonly List<(string Name, Func<Task> Test)> Tests =
    [
        ("valid state protocol", TestValidStateProtocolAsync),
        ("starting state protocol", TestStartingStateProtocolAsync),
        ("invalid state protocol", TestInvalidStateProtocolAsync),
        ("bounded state pipe", TestStatePipeAsync),
        ("activation pipe", TestActivationPipeAsync),
        ("single-instance lifecycle", TestSingleInstanceLifecycleAsync),
        ("argument validation", TestArgumentValidationAsync),
        ("receiver-name validation", TestReceiverNameValidationAsync),
        ("startup command", TestStartupCommandAsync)
    ];

    public static async Task<int> Main()
    {
        int failures = 0;
        foreach ((string name, Func<Task> test) in Tests)
        {
            try
            {
                await test();
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception exception)
            {
                failures++;
                Console.Error.WriteLine($"FAIL {name}: {exception.Message}");
            }
        }

        Console.WriteLine(
            failures == 0
                ? $"All {Tests.Count} InkBeam smoke tests passed."
                : $"{failures} of {Tests.Count} InkBeam smoke tests failed.");
        return failures == 0 ? 0 : 1;
    }

    private static Task TestValidStateProtocolAsync()
    {
        const string json =
            """{"version":1,"state":"Pairing","pin":"0427","revision":9,"receiverPid":321,"message":"Approve this connection."}""";
        Assert(
            ReceiverStateProtocol.TryParse(
                json,
                out ReceiverStateMessage? state,
                out string error),
            error);
        Assert(state is not null, "A valid state message was not returned.");
        ReceiverStateMessage parsed = state!;
        Assert(parsed.State == ReceiverDisplayState.Pairing, "State did not parse.");
        Assert(parsed.Pin == "0427", "The four-digit PIN did not parse.");
        Assert(parsed.Revision == 9, "Revision did not parse.");
        Assert(parsed.ReceiverPid == 321, "Receiver PID did not parse.");
        return Task.CompletedTask;
    }

    private static Task TestStartingStateProtocolAsync()
    {
        const string json =
            """{"version":1,"state":"Starting","pin":null,"revision":1,"receiverPid":320,"message":"Preparing listener."}""";
        Assert(
            ReceiverStateProtocol.TryParse(json, out ReceiverStateMessage? state, out string error),
            error);
        Assert(
            state?.State == ReceiverDisplayState.Starting,
            "The authoritative Starting state did not parse.");
        Assert(state!.Pin is null, "Starting retained a PIN.");
        return Task.CompletedTask;
    }

    private static Task TestInvalidStateProtocolAsync()
    {
        string[] invalidMessages =
        [
            """{"version":2,"state":"Ready","pin":null,"revision":1,"receiverPid":1,"message":"ready"}""",
            """{"version":1,"state":"Connected","pin":null,"revision":1,"receiverPid":1,"message":"bad state"}""",
            """{"version":1,"state":"Pairing","pin":"12A4","revision":1,"receiverPid":1,"message":"bad PIN"}""",
            """{"version":1,"state":"Ready","pin":"1234","revision":1,"receiverPid":1,"message":"PIN outside pairing"}""",
            """{"version":1,"state":"Ready","pin":null,"revision":-1,"receiverPid":1,"message":"bad revision"}""",
            """{"version":1,"state":"Ready","pin":null,"revision":1,"receiverPid":0,"message":"bad PID"}"""
        ];

        foreach (string json in invalidMessages)
        {
            Assert(
                !ReceiverStateProtocol.TryParse(json, out _, out _),
                "An invalid receiver state message was accepted.");
        }

        return Task.CompletedTask;
    }

    private static async Task TestStatePipeAsync()
    {
        string pipeName = $"InkBeamStateTest-{Guid.NewGuid():N}";
        const string json =
            """{"version":1,"state":"Ready","pin":null,"revision":2,"receiverPid":456,"message":"Listening."}""";
        Task server = Task.Run(async () =>
        {
            await using NamedPipeServerStream pipe = new(
                pipeName,
                PipeDirection.Out,
                1,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.WaitForConnectionAsync();
            byte[] payload = Encoding.UTF8.GetBytes(json + "\n");
            await pipe.WriteAsync(payload);
            await pipe.FlushAsync();
        });

        ReceiverStatePipeClient client = new(
            pipeName,
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));
        ReceiverStateMessage? state =
            await client.TryReadAsync(CancellationToken.None);
        await server;

        Assert(state?.State == ReceiverDisplayState.Ready, "Pipe state was not read.");
        Assert(state!.Pin is null, "A null PIN was not preserved.");
    }

    private static async Task TestActivationPipeAsync()
    {
        string pipeName = $"InkBeamActivationTest-{Guid.NewGuid():N}";
        TaskCompletionSource<bool> activated = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        await using ActivationPipeServer server = new(
            pipeName,
            () =>
            {
                activated.TrySetResult(true);
                return Task.CompletedTask;
            });
        server.Start();

        bool sent = await ActivationPipeClient.TryActivateAsync(
            pipeName,
            TimeSpan.FromSeconds(2));
        await activated.Task.WaitAsync(TimeSpan.FromSeconds(2));

        Assert(sent, "The activation command was not sent.");
        Assert(activated.Task.IsCompletedSuccessfully, "Activation was not received.");
    }

    private static Task TestSingleInstanceLifecycleAsync()
    {
        string mutexName = $@"Local\InkBeam.SmokeTest.{Guid.NewGuid():N}";
        using (SingleInstanceGate first = new(mutexName))
        {
            Assert(first.IsPrimary, "The first instance was not primary.");
            using SingleInstanceGate second = new(mutexName);
            Assert(!second.IsPrimary, "A second instance became primary.");
        }

        using SingleInstanceGate replacement = new(mutexName);
        Assert(replacement.IsPrimary, "The mutex was not released on disposal.");
        return Task.CompletedTask;
    }

    private static Task TestArgumentValidationAsync()
    {
        ArgumentParseResult foreground = ArgumentParseResult.Parse([]);
        ArgumentParseResult background =
            ArgumentParseResult.Parse(["--background"]);
        ArgumentParseResult selfTest =
            ArgumentParseResult.Parse(["--self-test"]);
        ArgumentParseResult smokeTest =
            ArgumentParseResult.Parse(["--smoke-test"]);
        ArgumentParseResult unknown =
            ArgumentParseResult.Parse(["--receiver"]);
        ArgumentParseResult duplicate =
            ArgumentParseResult.Parse(["--background", "--background"]);
        ArgumentParseResult conflicting =
            ArgumentParseResult.Parse(["--background", "--self-test"]);

        Assert(
            foreground.IsValid &&
            !foreground.Options.Background &&
            !foreground.Options.SelfTest,
            "Foreground arguments were not accepted.");
        Assert(background.IsValid && background.Options.Background,
            "Background arguments were not accepted.");
        Assert(selfTest.IsValid && selfTest.Options.SelfTest,
            "The self-test argument was not accepted.");
        Assert(smokeTest.IsValid && smokeTest.Options.SelfTest,
            "The smoke-test alias was not accepted.");
        Assert(!unknown.IsValid, "An unknown argument was accepted.");
        Assert(!duplicate.IsValid, "A duplicate argument was accepted.");
        Assert(!conflicting.IsValid, "Conflicting arguments were accepted.");
        return Task.CompletedTask;
    }

    private static Task TestReceiverNameValidationAsync()
    {
        Assert(ReceiverNameValidator.IsValid("InkBeam"), "A valid name failed.");
        Assert(!ReceiverNameValidator.IsValid("Ink Beam"), "Whitespace was accepted.");
        Assert(!ReceiverNameValidator.IsValid("-InkBeam"), "A leading hyphen was accepted.");
        Assert(!ReceiverNameValidator.IsValid("Ink%Beam"), "A percent sign was accepted.");
        Assert(!ReceiverNameValidator.IsValid(string.Empty), "An empty name was accepted.");
        return Task.CompletedTask;
    }

    private static Task TestStartupCommandAsync()
    {
        const string executable =
            @"C:\Users\test\AppData\Local\iPadWhiteboardReceiver\app\desktop\InkBeam.exe";
        string command = StartupManager.BuildRunValue(executable);
        Assert(
            command == $"\"{executable}\" --background",
            "The sign-in command is not quoted correctly.");
        return Task.CompletedTask;
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
