#!/usr/bin/env python3
"""Exercise UxPlay's real RTSP PIN challenge and digest-authentication flow."""

import hashlib
import plistlib
import queue
import re
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path


PIN_EVENT = re.compile(r'CLIENT MUST NOW ENTER PIN = "([0-9]{4})"')
AUTH_CHALLENGE = re.compile(
    r'Digest realm="([^"]+)",\s*nonce="([^"]+)"',
    re.IGNORECASE,
)


def read_response(connection):
    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = connection.recv(4096)
        if not chunk:
            raise RuntimeError("UxPlay closed the RTSP connection before replying.")
        response.extend(chunk)

    header, body = response.split(b"\r\n\r\n", 1)
    lines = header.decode("latin-1").split("\r\n")
    status = int(lines[0].split()[1])
    content_length = 0
    for line in lines[1:]:
        name, separator, value = line.partition(":")
        if separator and name.lower() == "content-length":
            content_length = int(value.strip())

    while len(body) < content_length:
        chunk = connection.recv(4096)
        if not chunk:
            raise RuntimeError("UxPlay returned an incomplete RTSP response.")
        body += chunk

    return status, lines


def send_setup(connection, uri, sequence, body, authorization=None):
    headers = [
        f"SETUP {uri} RTSP/1.0",
        f"CSeq: {sequence}",
        "Content-Type: application/x-apple-binary-plist",
        f"Content-Length: {len(body)}",
    ]
    if authorization:
        headers.append(f"Authorization: {authorization}")
    request = ("\r\n".join(headers) + "\r\n\r\n").encode("ascii") + body
    connection.sendall(request)
    return read_response(connection)


def wait_for_pin(events, process):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            line = events.get(timeout=max(0.01, deadline - time.monotonic()))
        except queue.Empty as error:
            raise RuntimeError("UxPlay did not emit its PIN challenge.") from error
        match = PIN_EVENT.search(line)
        if match:
            return match.group(1)
        if process.poll() is not None:
            raise RuntimeError("UxPlay exited before emitting a PIN challenge.")
    raise RuntimeError("UxPlay did not emit its PIN challenge.")


def wait_for_authentication(events, process):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            line = events.get(timeout=max(0.01, deadline - time.monotonic()))
        except queue.Empty as error:
            raise RuntimeError("UxPlay did not finish PIN authentication.") from error
        if "Too many authentication failures" in line:
            raise RuntimeError("UxPlay rotated the displayed PIN before checking it.")
        if "Client authentication failure" in line:
            raise RuntimeError("UxPlay rejected the PIN displayed for this challenge.")
        if "Client authentication success" in line:
            return
        if process.poll() is not None:
            raise RuntimeError("UxPlay exited before confirming PIN authentication.")
    raise RuntimeError("UxPlay did not finish PIN authentication.")


def digest_authorization(method, uri, realm, nonce, password):
    username = "InkBeamAuthProbe"
    qop = "auth"
    nonce_count = "00000001"
    client_nonce = uuid.uuid4().hex
    hash1 = hashlib.md5(
        f"{username}:{realm}:{password}".encode("utf-8")
    ).hexdigest()
    hash2 = hashlib.md5(f"{method}:{uri}".encode("utf-8")).hexdigest()
    response = hashlib.md5(
        f"{hash1}:{nonce}:{nonce_count}:{client_nonce}:{qop}:{hash2}".encode("utf-8")
    ).hexdigest()
    return (
        f'Digest username="{username}", realm="{realm}", nonce="{nonce}", '
        f'uri="{uri}", qop={qop}, nc={nonce_count}, '
        f'cnonce="{client_nonce}", response="{response}"'
    )


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("Usage: uxplay_first_pin_integration.py <uxplay-executable>")

    executable = Path(sys.argv[1]).resolve()
    if not executable.is_file():
        raise RuntimeError("The UxPlay executable was not found.")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as port_probe:
        port_probe.bind(("127.0.0.1", 0))
        port = port_probe.getsockname()[1]

    runtime_directory = executable.parent
    key_path = runtime_directory / f"inkbeam-auth-test-{uuid.uuid4().hex}.pem"
    events = queue.Queue()
    process = None
    connection = None
    try:
        subprocess.run(
            ["openssl", "genrsa", "-out", str(key_path), "2048"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )

        process = subprocess.Popen(
            [
                str(executable),
                "-n",
                "InkBeamAuthProbe",
                "-nh",
                "-pw",
                "-key",
                str(key_path),
                "-nofreeze",
                "-nc",
                "-p",
                str(port),
            ],
            cwd=runtime_directory,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )

        def collect_output():
            for line in process.stdout:
                events.put(line.rstrip("\r\n"))

        threading.Thread(target=collect_output, daemon=True).start()

        deadline = time.monotonic() + 20
        while connection is None and time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("UxPlay exited before opening its RTSP listener.")
            try:
                connection = socket.create_connection(("127.0.0.1", port), timeout=2)
            except OSError:
                time.sleep(0.25)
        if connection is None:
            raise RuntimeError("UxPlay did not open its RTSP listener.")
        connection.settimeout(8)

        uri = f"rtsp://127.0.0.1:{port}/stream"
        body = plistlib.dumps(
            {
                "deviceID": "02:12:34:56:78:9A",
                "ekey": bytes(72),
                "eiv": bytes(16),
                "model": "iPad14,1",
                "name": "InkBeam authentication probe",
            },
            fmt=plistlib.FMT_BINARY,
        )

        pins = []
        nonce = None
        realm = None
        for sequence in range(1, 4):
            status, headers = send_setup(connection, uri, sequence, body)
            if status != 401:
                raise RuntimeError("UxPlay did not request a PIN for an unauthenticated client.")
            challenge = next(
                (
                    AUTH_CHALLENGE.search(value)
                    for value in headers
                    if value.lower().startswith("www-authenticate:")
                ),
                None,
            )
            if challenge is None:
                raise RuntimeError("UxPlay's PIN challenge omitted its digest nonce.")
            realm, nonce = challenge.groups()
            pins.append(wait_for_pin(events, process))

        if len(set(pins)) != 1:
            raise RuntimeError("Repeated challenges unexpectedly changed the displayed PIN.")

        authorization = digest_authorization("SETUP", uri, realm, nonce, pins[0])
        request = [
            "SETUP " + uri + " RTSP/1.0",
            "CSeq: 4",
            "Content-Type: application/x-apple-binary-plist",
            f"Content-Length: {len(body)}",
            f"Authorization: {authorization}",
        ]
        connection.sendall(
            ("\r\n".join(request) + "\r\n\r\n").encode("ascii") + body
        )
        wait_for_authentication(events, process)
        print("UxPlay accepted the displayed PIN after three repeated challenges.")
    finally:
        if connection is not None:
            connection.close()
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            if process.stdout is not None:
                process.stdout.close()
        try:
            key_path.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"UxPlay first-PIN integration test failed: {error}", file=sys.stderr)
        sys.exit(1)
