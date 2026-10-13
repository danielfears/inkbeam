using System;
using System.Text.RegularExpressions;

namespace IpadWhiteboard
{
    public sealed class ReceiverSnapshot
    {
        public int version { get; set; }
        public string state { get; set; }
        public string pin { get; set; }
        public long revision { get; set; }
        public int receiverPid { get; set; }
        public string message { get; set; }
    }

    public sealed class ReceiverSession
    {
        private static readonly Regex PinEvent = new Regex(
            @"\*\*\* CLIENT MUST NOW ENTER PIN = ""([0-9]{4})"" AS AIRPLAY PASSWORD",
            RegexOptions.CultureInvariant);
        private readonly object gate = new object();
        private string state = "Starting";
        private string pin;
        private string message = "Starting the local AirPlay receiver.";
        private long revision;
        private int receiverPid;
        private bool listening;
        private bool observedControl;
        private bool authenticationAccepted;
        private bool videoStarted;
        private DateTime challengeAt;

        public void SetReceiverPid(int pid)
        {
            lock (gate) { receiverPid = pid; }
        }

        public ReceiverSnapshot Snapshot()
        {
            lock (gate)
            {
                return new ReceiverSnapshot
                {
                    version = 1,
                    state = state,
                    pin = state == "Pairing" ? pin : null,
                    revision = revision,
                    receiverPid = receiverPid,
                    message = message
                };
            }
        }

        public void ProcessLine(string line, DateTime now)
        {
            lock (gate)
            {
                Match challenge = PinEvent.Match(line);
                if (challenge.Success)
                {
                    pin = challenge.Groups[1].Value;
                    authenticationAccepted = false;
                    challengeAt = now;
                    videoStarted = false;
                    Change("Pairing", "Enter this PIN on the iPad.");
                }
                else if (line.Contains("Client authentication success") ||
                    line.Contains("pair-pin-setup success"))
                {
                    pin = null;
                    authenticationAccepted = true;
                    Change("Pairing", "PIN accepted. Waiting for the video stream.");
                }
                else if (line.Contains("nonce mismatch"))
                {
                    Fail("The pairing challenge changed. Cancel mirroring on the iPad and reconnect.");
                }
                else if (line.Contains("Client authentication failure") ||
                    line.Contains("*** authentication failure:"))
                {
                    authenticationAccepted = false;
                    Change("Pairing", "The PIN was not accepted. Use the current PIN shown here.");
                }
                else if (line.Contains("Too many authentication failures"))
                {
                    pin = null;
                    authenticationAccepted = false;
                    Change("Pairing", "Waiting for a fresh PIN from the receiver.");
                }
                else if (line.Contains("raop_rtp_mirror h264 SPS+PPS header:") ||
                    line.Contains("raop_rtp_mirror h265") ||
                    line.Contains("raop_rtp_mirror: SPS+PPS header size ="))
                {
                    videoStarted = true;
                    pin = null;
                    Change("Casting", "The iPad video stream is connected.");
                }
                else if (line.Contains("tcp socket was closed by client"))
                {
                    // AirPlay can close its control socket while the PIN dialogue remains open.
                    if (pin == null) { ClearConnection(); }
                }
                else if (line.Contains("raop_rtp_mirror->running is no longer true") ||
                    line.Contains("lost connection with client"))
                {
                    ClearConnection();
                }
                else if (line.Contains("Failed to generate random pin"))
                {
                    Fail("The receiver could not generate a secure PIN. Disable and enable it before reconnecting.");
                }
                else if (line.Contains("dnssd_register_airplay failed") ||
                    line.Contains("dnssd_register_raop failed") ||
                    line.Contains("Could not initialize dnssd") ||
                    line.Contains("Error initializing raop") ||
                    line.Contains("raop_rtp_mirror initializing socket failed"))
                {
                    Fail("AirPlay discovery or a receiver port could not start. Check setup and competing receivers.");
                }
                else if (line.Contains("Stopping RAOP Server"))
                {
                    pin = null;
                    videoStarted = false;
                    listening = false;
                    observedControl = false;
                    Change("Starting", "The receiver is restarting.");
                }
            }
        }

        public void UpdateTransport(bool isListening, bool controlConnected,
            bool mirrorConnected, DateTime now)
        {
            lock (gate)
            {
                listening = isListening;
                if (controlConnected) { observedControl = true; }
                if (observedControl && !controlConnected && !mirrorConnected &&
                    !(state == "Pairing" && pin != null))
                {
                    ClearConnection();
                }
                if (state == "Pairing" && challengeAt != default(DateTime) &&
                    now - challengeAt > TimeSpan.FromMinutes(2) && !controlConnected)
                {
                    ClearConnection();
                }
                if (state == "Starting" && listening)
                {
                    Change("Ready", "Choose this receiver in iPad Screen Mirroring.");
                }
                if (authenticationAccepted && mirrorConnected)
                {
                    videoStarted = true;
                    pin = null;
                    Change("Casting", "The iPad video stream is connected.");
                }
                if (videoStarted && !mirrorConnected)
                {
                    ClearConnection();
                }
            }
        }

        public void ConsoleHistoryLost()
        {
            lock (gate)
            {
                if (pin != null)
                {
                    Fail("The receiver status stream was interrupted. Disable and enable the receiver before pairing.");
                }
            }
        }

        public void HostFailed(string safeMessage)
        {
            lock (gate) { Fail(safeMessage); }
        }

        private void ClearConnection()
        {
            pin = null;
            videoStarted = false;
            authenticationAccepted = false;
            observedControl = false;
            challengeAt = default(DateTime);
            Change(listening ? "Ready" : "Starting",
                listening ? "Disconnected. Choose this receiver to reconnect." : "Starting the local AirPlay receiver.");
        }

        private void Fail(string safeMessage)
        {
            pin = null;
            videoStarted = false;
            authenticationAccepted = false;
            Change("Error", safeMessage);
        }

        private void Change(string nextState, string nextMessage)
        {
            state = nextState;
            message = nextMessage;
            revision++;
        }
    }
}
