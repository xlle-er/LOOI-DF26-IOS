#!/usr/bin/env python3
"""Exercise production URLSession callbacks against a local streaming server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os, subprocess, tempfile, threading, time
root = Path(__file__).resolve().parents[1]
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '1048576')
        self.end_headers()
        try:
            for _ in range(64):
                self.wfile.write(b'x' * 16384)
                self.wfile.flush()
                time.sleep(.01)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"accepted":true}')
    def log_message(self, *args): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='looi-transfer-tests-') as directory:
        output = str(Path(directory) / 'transfers')
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(Path(directory) / 'cache'), str(root / 'Native/Sources/LooiNative/LooiFirmwareTransfer.swift'), str(root / 'Tests/device/FirmwareTransferTests.swift'), '-o', output], check=True)
        subprocess.run([output], check=True, env={**os.environ, 'LOOI_TRANSFER_TEST_URL': f'http://127.0.0.1:{server.server_port}'})
finally:
    server.shutdown()
    server.server_close()
