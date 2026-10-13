# Changelog

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
