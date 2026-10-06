"""Publish like a classic Icecast source client, for tests/gateway.sh.

Sends PUT (or SOURCE) with no Content-Length and no chunked encoding over
TLS, then streams stdin until it ends. Prints the server's first status
code, or "closed" if the connection ends before any response.

    ffmpeg ... -f mp3 - | python3 raw_source.py HOST PORT MOUNT USER:PASS [--method SOURCE] [--ca FILE]
        [--plain] [--bitrate KBPS]
"""

import argparse
import base64
import socket
import ssl
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("mount")
    parser.add_argument("credentials")
    parser.add_argument("--method", default="PUT")
    parser.add_argument("--ca")
    parser.add_argument("--connect", help="IP to connect to instead of resolving HOST")
    parser.add_argument("--plain", action="store_true", help="no TLS (straight to Icecast)")
    parser.add_argument("--bitrate", type=int, help="send Ice-Bitrate with this value")
    args = parser.parse_args()

    raw = socket.create_connection((args.connect or args.host, args.port), timeout=10)
    if args.plain:
        conn = raw
    else:
        context = ssl.create_default_context(cafile=args.ca)
        conn = context.wrap_socket(raw, server_hostname=args.host)
    auth = base64.b64encode(args.credentials.encode()).decode()
    expect = "Expect: 100-continue\r\n" if args.method == "PUT" else ""
    if args.bitrate:
        expect += f"Ice-Bitrate: {args.bitrate}\r\n"
    conn.sendall(
        f"{args.method} {args.mount} HTTP/1.1\r\nHost: {args.host}\r\n"
        f"Authorization: Basic {auth}\r\nContent-Type: audio/mpeg\r\n"
        f"Ice-Public: 0\r\n{expect}\r\n".encode()
    )
    try:
        head = conn.recv(4096).decode(errors="replace")
    except (ConnectionError, ssl.SSLError, TimeoutError):
        head = ""
    if not head:
        print("closed")
        return
    code = head.split(" ", 2)[1] if head.startswith("HTTP/") else "invalid"
    print(code, flush=True)
    if code not in ("100", "200"):
        return
    conn.settimeout(None)
    try:
        while chunk := sys.stdin.buffer.read(4096):
            conn.sendall(chunk)
    except (BrokenPipeError, ConnectionError, ssl.SSLError):
        pass


if __name__ == "__main__":
    main()
