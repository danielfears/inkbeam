# Security

## Supported versions

Security fixes are applied to the latest published release.

## Reporting a vulnerability

Please use GitHub's private **Report a vulnerability** feature rather than
opening a public issue. Do not include credentials, pairing keys, personal
data, or active PINs in a report.

## Security model

- The receiver runs locally; it has no account, telemetry, cloud relay, or
  payment integration.
- Runtime downloads are pinned by version and SHA-256 digest.
- Inbound firewall rules are restricted to the receiver executables, fixed
  ports, and `LocalSubnet`.
- A fresh PIN is required for each connection by default.
- The active PIN is held in memory and exposed to the current user's widget
  over a current-user-only named pipe. It is not logged or stored on disk.
