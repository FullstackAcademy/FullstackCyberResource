#!/usr/bin/env bash
set -e

PORT=8080
LAB_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
if [ -z "${LAB_IP:-}" ]; then
  LAB_IP=$(hostname -I | awk '{print $1}')
fi

cat <<BANNER

============================================================
 Cryptographic Failures Lab - Insecure Login Server
============================================================

The intentionally insecure web application is starting.

Open Burp Suite's browser and visit:

  http://${LAB_IP}:${PORT}

Use these fake credentials when instructed by the lab:

  Email:    student@example.com
  Password: Password123!

Keep this terminal open while completing the lab.
Press Ctrl+C when you are finished.

============================================================

BANNER

python3 - "$PORT" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs
import sys

PORT = int(sys.argv[1])

LOGIN_PAGE = b'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Employee Portal</title>
<style>
    * { box-sizing: border-box; }
    body {
        margin: 0;
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        background: #eef1f5;
        font-family: Arial, Helvetica, sans-serif;
        color: #1f2937;
    }
    .card {
        width: 390px;
        background: #fff;
        border: 1px solid #d6dbe3;
        border-radius: 10px;
        box-shadow: 0 8px 28px rgba(0,0,0,.10);
        padding: 34px;
    }
    .brand {
        font-size: 13px;
        font-weight: 700;
        letter-spacing: .08em;
        color: #4b5563;
        text-transform: uppercase;
        margin-bottom: 8px;
    }
    h1 {
        font-size: 27px;
        margin: 0 0 8px;
    }
    .subtitle {
        margin: 0 0 26px;
        color: #6b7280;
        font-size: 14px;
        line-height: 1.45;
    }
    label {
        display: block;
        margin: 0 0 6px;
        font-size: 14px;
        font-weight: 700;
    }
    input {
        width: 100%;
        padding: 11px 12px;
        margin-bottom: 18px;
        border: 1px solid #b9c0ca;
        border-radius: 6px;
        font-size: 15px;
        background: #fff;
    }
    input:focus {
        outline: 2px solid #9ca3af;
        outline-offset: 1px;
    }
    button {
        width: 100%;
        border: 0;
        border-radius: 6px;
        height: 42px;
        padding: 0;
        line-height: 42px;
        background: #27364a;
        color: #fff;
        font-size: 15px;
        font-weight: 700;
        cursor: pointer;
    }
    .notice {
        margin-top: 20px;
        padding-top: 18px;
        border-top: 1px solid #e5e7eb;
        font-size: 12px;
        color: #737b87;
        line-height: 1.45;
    }
</style>
</head>
<body>
<div class="card">
    <div class="brand">Northstar Systems</div>
    <h1>Employee Portal</h1>
    <p class="subtitle">Sign in to access internal employee resources.</p>
    <form method="POST" action="/login">
        <label for="email">Email Address</label>
        <input id="email" name="email" type="email" autocomplete="off" required>
        <label for="password">Password</label>
        <input id="password" name="password" type="password" autocomplete="off" required>
        <button type="submit">Log In</button>
    </form>
    <div class="notice">Training environment. Use only the sample credentials provided in the lab instructions.</div>
</div>
</body>
</html>'''

RESULT_PAGE = b'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Login Request Received</title>
<style>
    body {
        margin: 0;
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        background: #eef1f5;
        font-family: Arial, Helvetica, sans-serif;
        color: #1f2937;
    }
    .card {
        width: 500px;
        background: #fff;
        border: 1px solid #d6dbe3;
        border-radius: 10px;
        box-shadow: 0 8px 28px rgba(0,0,0,.10);
        padding: 36px;
        text-align: center;
    }
    h1 { margin-top: 0; font-size: 26px; }
    p { line-height: 1.55; color: #4b5563; }
    code {
        display: inline-block;
        margin-top: 8px;
        padding: 7px 10px;
        background: #f3f4f6;
        border-radius: 5px;
        color: #111827;
    }
</style>
</head>
<body>
<div class="card">
    <h1>Login Request Received</h1>
    <p>Return to Burp Suite and examine the intercepted HTTP request.</p>
    <p>Look for the submitted <code>email</code> and <code>password</code> parameters.</p>
</div>
</body>
</html>'''

class LabHandler(BaseHTTPRequestHandler):
    def send_html(self, content, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            self.send_html(LOGIN_PAGE)
        else:
            self.send_html(b"<h1>404</h1>", 404)

    def do_POST(self):
        if self.path != "/login":
            self.send_html(b"<h1>404</h1>", 404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        # Parse the form only so the request is consumed normally. Nothing is stored.
        parse_qs(body.decode("utf-8", errors="replace"), keep_blank_values=True)
        self.send_html(RESULT_PAGE)

    def log_message(self, format, *args):
        # Keep terminal output clean for students.
        pass

server = ThreadingHTTPServer(("0.0.0.0", PORT), LabHandler)
try:
    server.serve_forever()
except KeyboardInterrupt:
    print("\nLab server stopped.")
finally:
    server.server_close()
PY
