# InkBeam

[![CI](https://github.com/danielfears/inkbeam/actions/workflows/ci.yml/badge.svg)](https://github.com/danielfears/inkbeam/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/danielfears/inkbeam)](https://github.com/danielfears/inkbeam/releases/latest)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A local-only AirPlay screen-mirroring receiver for using an iPad as a
whiteboard in Teams, Zoom, or another screen-sharing application. It requires
no account, subscription, card details, or cloud service.

The project wraps the open-source
[UxPlay](https://github.com/FDH2/UxPlay) receiver in a reproducible Windows
setup. It deliberately uses a native Windows runtime rather than WSL so that
Bonjour multicast discovery works reliably on the laptop's real network.

## Install on Windows

1. Download
   **[InkBeam](https://github.com/danielfears/inkbeam/releases/latest)**
   from the latest GitHub release.
2. Extract the ZIP.
3. Double-click **`Install.cmd`**.
4. Approve the single administrator prompt used to install local discovery
   and scoped firewall rules.

No WSL, developer tools, account, or package manager is required. The first
installation downloads about 115 MB of open-source runtime files from GitHub.
Windows 10/11 x64 is supported; Windows 11 ARM64 uses built-in x64 emulation.

The installer:

- validates its own package before changing the machine;
- copies an updateable application snapshot into
  `%LOCALAPPDATA%\iPadWhiteboardReceiver\app`;
- downloads the pinned `uxplay-windows` 2.0.0.1736 x64 bundle from GitHub;
- verifies its published SHA-256 checksum before extracting anything;
- checks the expected application, codec, and renderer files in the bundle;
- requests one Windows administrator approval to install the local Bonjour
  service and tightly scoped firewall rules;
- allows the receiver on all Windows network profiles, but only for its fixed
  ports, executable paths, and the directly connected local subnet;
- creates an **InkBeam Receiver** Start menu shortcut; and
- installs the desktop widget and starts it automatically at sign-in.

Re-running `Install.cmd` upgrades the application in place and preserves the
receiver identity, settings, and trusted-client register.

To remove it, use **Uninstall InkBeam** from the Start menu or
double-click `Uninstall.cmd` in the extracted release.

## Use

1. Ensure the iPad and laptop are on the same trusted Wi-Fi network.
2. On the iPad, open **Control Centre → Screen Mirroring**.
3. Select **InkBeam**.
4. Enter the fresh PIN shown directly on the **InkBeam** widget.
5. In Teams or Zoom, share the **AirPlay Video Stream** window.

The stream window remains available between brief disconnects, but clears the
last frame to avoid accidentally sharing stale content. Use `Alt+Enter` to
toggle full screen when the D3D11 renderer is active.

UxPlay generates a new PIN only after the iPad requests a connection. The
pinned Windows tray app renders that PIN as console glyphs rather than exposing
it through its GUI. A hidden local host decodes those glyphs in memory and
sends the four digits to the widget through a current-user-only named pipe.
The PIN is not stored on disk or written to a log.

## Commands

From Windows PowerShell:

```powershell
$controller = "$env:LOCALAPPDATA\iPadWhiteboardReceiver\app\WhiteboardReceiver.ps1"
& $controller start
& $controller stop
& $controller restart
& $controller status
& $controller doctor
```

## Desktop widget

The **InkBeam** Windows widget is installed on the desktop and starts
at sign-in. It sits at the top-right, or directly below an existing Azure
Context widget when one is present. It provides:

- an **Enable/Disable** button for the receiver;
- grey **Disabled**, green **Ready to cast**, and blue **Casting now** states;
- setup, discovery, or network warnings instead of a false ready state; and
- the current AirPlay name and the active four-digit PIN when requested.

The widget is the primary control and information view; no terminal is needed.

Change the visible name or presentation settings:

```powershell
$controller = "$env:LOCALAPPDATA\iPadWhiteboardReceiver\app\WhiteboardReceiver.ps1"
& $controller configure -ReceiverName "Workshop-Whiteboard"
& $controller configure -Fullscreen on
& $controller configure -Audio on
```

Authentication modes:

```powershell
# Recommended: a fresh random PIN for every connection
& $controller configure -Authentication every-connection

# Trust an iPad after its first PIN pairing
& $controller configure -Authentication pair-once

# No authentication; not recommended
& $controller configure -Authentication open
```

Configuration and generated pairing material stay under
`%LOCALAPPDATA%\iPadWhiteboardReceiver`. The private key and optional
trusted-client register are relative to the pinned runtime folder because this
release's argument parser does not support quoted paths. The UxPlay argument
file is stored at `%APPDATA%\leapbtw\uxplay-windows\arguments.txt`.

## Privacy and security defaults

- No telemetry, account, payment, cloud relay, or update checker is added.
- A new random PIN is required for every connection.
- Bluetooth discovery is disabled; discovery uses local Bonjour/mDNS only.
- Audio is disabled to avoid meeting echo and accidental audio sharing.
- No recording flags are enabled.
- AirPlay data ports are fixed to TCP/UDP `7100-7102`.
- Windows Firewall permits those ports and mDNS `5353/UDP` only from
  `LocalSubnet`. The rules apply on Domain, Private, and Public profiles so
  changing Wi-Fi does not require an adapter-specific setup.
- The receiver accepts one active client at a time.

On a Public network, the controller's `doctor` command warns that nearby
devices on the same subnet can reach the receiver. The fresh per-connection
PIN remains mandatory; disable the receiver from the widget when it is not
needed.

## What AirServer is and why this design differs

[AirServer](https://www.airserver.com/WindowsDesktop) is a commercial,
closed-source receiver application. It makes a Windows or macOS device appear
like a receiving display for AirPlay, Google Cast, and Miracast. Its vendor
states that receiver sessions remain local rather than being transmitted over
the Internet, but it does not publish the receiver implementation or a
wire-level technical specification.

AirServer does not bind itself to a named network adapter. Its Windows app
package installs inbound and outbound firewall capabilities for Domain,
Private, and Public profiles, and its support guidance explicitly enables both
Private and Public. This receiver now follows that profile-independent model
with narrower rules: only the UxPlay and mDNS executables, fixed ports, and
`LocalSubnet` are allowed, with a fresh PIN required for every connection.

AirPlay mirroring is not simply a web video stream. It combines:

1. Bonjour/mDNS (`_airplay._tcp`) for discovery;
2. an Apple-specific RTSP/HTTP-style control and pairing exchange;
3. encrypted session setup and key negotiation;
4. H.264 video in Apple's mirroring packet format, with optional AAC/ALAC
   audio; and
5. timing channels for synchronisation.

Apple does not publish the complete receiver protocol outside its licensing
program. Reimplementing it from scratch would duplicate years of
reverse-engineering and risk drifting into FairPlay/DRM handling. This tool
therefore reuses UxPlay's mature GPLv3 implementation for ordinary,
unprotected screen mirroring. It does not attempt to decrypt DRM-protected
video from services such as Apple TV.

## Sources

Research checked on 28/07/2026:

- [AirServer for Windows](https://www.airserver.com/WindowsDesktop)
- [AirServer Connect 3 privacy statement](https://www.airserver.com/connect-3)
- [AirServer privacy policy](https://www.airserver.com/privacy)
- [AirServer Windows firewall guidance](https://support.airserver.com/support/solutions/articles/43000533861-how-can-i-add-an-exception-to-windows-security-for-airserver-windows-desktop-edition-firewall-confi)
- [AirServer Windows ports and Bonjour services](https://support.airserver.com/support/solutions/articles/43000534713-what-ports-bonjour-services-are-used-by-airserver-windows-desktop-edition-)
- [Apple: stream video or mirror an iPad screen with AirPlay](https://support.apple.com/guide/ipad/stream-video-or-mirror-the-screen-ipadf27a8cb7/ipados)
- [Unofficial AirPlay service discovery specification](https://github.com/openairplay/airplay-spec/blob/master/src/service_discovery.md)
- [Unofficial AirPlay screen-mirroring transport](https://github.com/openairplay/airplay-spec/tree/master/src/screen_mirroring)
- [UxPlay upstream project](https://github.com/FDH2/UxPlay)
- [uxplay-windows 2.0.0.1736 release](https://github.com/leapbtw/uxplay-windows/releases/tag/2.0.0.1736)
- [Microsoft WSL networking modes](https://learn.microsoft.com/windows/wsl/networking)

## Limitations

- This receives iPad screen mirroring; it is not a true extended desktop.
- DRM-protected video is unsupported.
- Guest Wi-Fi, VPNs, client isolation, and enterprise VLANs may block
  peer-to-peer discovery even when both devices have Internet access.
- AirPlay is undocumented and Apple may change compatibility in a future
  iPadOS release.

## Development

Clone the repository and validate it without installing:

```powershell
git clone https://github.com/danielfears/inkbeam.git
cd inkbeam
.\install.ps1 -ValidateOnly
.\tests\WhiteboardReceiver.Tests.ps1
```

WSL users can also use the `./inkbeam` convenience wrapper. Tagged releases
are assembled and published by GitHub Actions.

See [CHANGELOG.md](CHANGELOG.md) for release history.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
