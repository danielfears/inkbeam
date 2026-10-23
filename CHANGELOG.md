# Changelog

## 0.2.4 - 23/10/2026

- Fix Enable failing with "The receiver did not establish a working AirPlay
  listener and status channel". The 0.2.3 runtime omitted the FFmpeg
  libraries that GStreamer's libav plugin imports, so UxPlay exited as soon
  as it started.
- Build the runtime by following each program's imports, so every library it
  needs is bundled, and fail the build when one cannot be found.
- Release a runtime only after its packaged receiver has started and reached
  a ready state.
- Verify the runtime's libraries when installing, in the doctor and after a
  failed start. An incomplete runtime is now reinstalled instead of being
  treated as installed, and the missing libraries are named.

## 0.2.3 - 14/10/2026

- Fix UxPlay random-PIN retry accounting so displaying repeated challenges
  does not consume failed-authentication attempts or rotate the PIN before
  it is verified.
- Install the patched, checksum-pinned native runtime while preserving the
  existing receiver identity and trusted-client register.

## 0.2.2 - 13/10/2026

- Transition to Casting when an authenticated iPad establishes the receiver's
  live mirror transport, even if UxPlay does not emit a recognised video-log
  marker.
- Keep authentication success alone in Pairing until the mirror transport is
  connected, and return to Ready when that transport is lost.

## 0.2.1 - 13/10/2026

- Use a counted character array for native console reads; the API does not
  terminate strings, so string-buffer marshalling could append invalid data,
  repeatedly flag lost history and discard every new PIN event.
- Keep the current PIN visible when the iPad closes a short-lived AirPlay
  control connection while waiting for PIN entry.
- Preserve immediate clearing on acceptance and replacement, and expire
  abandoned challenges after two minutes without a control connection.
- Add regression coverage for control disconnects, reconnection, acceptance
  and abandoned-challenge expiry.

## 0.2.0 - 13/10/2026

- Replace the PowerShell desktop widget with a compiled, single-instance
  Windows application with a taskbar window, notification-area controls,
  settings and start-at-sign-in support.
- Add one dual-architecture per-user Windows installer plus portable x64 and
  ARM64 packages.
- Read authoritative UxPlay PIN challenge events instead of repeatedly
  decoding historical console glyphs.
- Clear accepted, replaced, cancelled and expired PINs immediately, and fail
  closed if receiver status history is interrupted.
- Distinguish receiver startup, readiness, pairing and actual video casting;
  an unauthenticated AirPlay control connection is no longer labelled as a
  live cast.
- Bind the receiver process to its hidden host lifecycle and add bounded,
  current-user-only state and activation channels.

## 0.1.0 - 28/07/2026

- Add local AirPlay screen mirroring through a checksum-pinned UxPlay runtime.
- Add the InkBeam desktop widget with enable/disable, ready/casting state, and
  an in-widget ephemeral PIN.
- Add scoped local-subnet firewall configuration for every Windows profile.
- Add idempotent double-click Windows installation and uninstallation.
- Add Windows on ARM support through the tested x64 runtime and Windows
  emulation.
