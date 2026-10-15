"""Test stand-in for the control plane's playout endpoint (#63).

GET /playout  the desired state in $STUB_STATE_FILE, behind the node
              credentials, with an ETag from its content.
GET /tracks/<name>  files in $STUB_TRACKS_DIR, standing in for presigned
              object storage URLs (no credentials).
"""

import base64
import hashlib
import hmac
import os
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = Path(os.environ["STUB_STATE_FILE"])
TRACKS = Path(os.environ["STUB_TRACKS_DIR"])
EXPECTED_AUTH = "Basic " + base64.b64encode(
    f"{os.environ['STUB_PLAYOUT_USER']}:{os.environ['STUB_PLAYOUT_PASSWORD']}".encode()
).decode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/playout":
            if not hmac.compare_digest(self.headers.get("Authorization", ""), EXPECTED_AUTH):
                return self.reply(401)
            body = STATE.read_bytes()
            etag = '"' + hashlib.sha256(body).hexdigest()[:16] + '"'
            if self.headers.get("If-None-Match") == etag:
                return self.reply(304)
            return self.reply(200, body, {"Content-Type": "application/json", "ETag": etag})
        if self.path.startswith("/tracks/"):
            path = TRACKS / Path(self.path).name
            if path.is_file():
                return self.reply(200, path.read_bytes(), {"Content-Type": "application/octet-stream"})
        self.reply(404)

    def reply(self, code, body=b"", headers=None):
        self.send_response(code)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9001), Handler).serve_forever()
