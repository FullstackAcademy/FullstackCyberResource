#!/usr/bin/env bash
set -euo pipefail

BANK_DIR_NAME="secureish-bank"
PORT="8000"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is required, but it was not found on this system."
    exit 1
fi

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
else
    TARGET_USER="$(id -un)"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" ]]; then
    echo "Could not determine the home directory for user: $TARGET_USER"
    exit 1
fi

APP_DIR="$TARGET_HOME/$BANK_DIR_NAME"
mkdir -p "$APP_DIR"

cat > "$APP_DIR/app.py" <<'PYTHON'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse, quote
from http.cookies import SimpleCookie
from pathlib import Path
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import datetime as dt
import hashlib
import html
import os
import re
import secrets
import sqlite3

HOST = "127.0.0.1"
PORT = 8000
APP_DIR = Path(__file__).resolve().parent
DB_PATH = APP_DIR / "bank.db"
SESSIONS = {}

BANK_NAME = "Secure-ish Savings & Loan"
TAGLINE = "Banking with confidence-ish."

SEED_ACCOUNTS = [
    (18427, "Eleanor Price", "Retired Teacher", "Personal Savings", 842117),
    (52791, "Marcus Chen", "Software Engineer", "Personal Checking", 3482042),
    (31648, "Olivia Bennett", "Small Business Owner", "Business Checking", 11250388),
    (74216, "Samuel Ortiz", "Hospital Administrator", "Personal Checking", 7124003),
    (90341, "Priya Desai", "Payroll Manager", "Payroll Reserve", 24682119),
    (45823, "Henry Wallace", "College Student", "Personal Checking", 68215),
    (67109, "Monica Reyes", "Nonprofit Treasurer", "Organization Account", 5340922),
    (23854, "Arthur Sterling", "Chief Financial Officer", "Executive Savings", 148722164),
    (81936, "Nadia Brooks", "Emergency Room Nurse", "Personal Checking", 1890462),
    (56412, "Caleb Morgan", "Restaurant Owner", "Business Checking", 3999145),
    (29573, "Tessa Nguyen", "Social Worker", "Personal Savings", 564210),
    (73064, "Jordan Kim", "City Clerk", "Personal Checking", 1203477),
    (41285, "Amara Patel", "Independent Contractor", "Personal Checking", 911803),
    (68531, "Wesley Grant", "School Principal", "Personal Savings", 2754261),
    (35790, "Lucia Romero", "Firefighter", "Personal Checking", 1408755),
    (94618, "Derek Shaw", "Dental Hygienist", "Personal Savings", 2110633),
    (17362, "Maya Thompson", "Property Manager", "Personal Checking", 6533820),
    (60847, "Noah Sinclair", "Freelance Artist", "Personal Checking", 390281),
    (82495, "Keira Foster", "IT Support Specialist", "Personal Savings", 1764007),
    (26914, "Andre Lewis", "Logistics Coordinator", "Personal Checking", 2900412),
    (75183, "Sophia Haddad", "Pharmacist", "Personal Savings", 7612984),
    (49307, "Gavin Cole", "Military Veteran", "Personal Checking", 1170246),
    (88241, "Renee Alvarez", "Daycare Director", "Business Checking", 2488095),
    (34176, "Dr. Isaac Monroe", "Research Scientist", "Personal Savings", 8924120),
    (61725, "Camille Johnson", "Community Organizer", "Organization Account", 733276),
]

CSS = r"""
:root {
  --ink: #182430;
  --muted: #5e6a73;
  --paper: #f5f7f8;
  --card: #ffffff;
  --navy: #0d3b4c;
  --teal: #0c7b77;
  --teal-dark: #075f5c;
  --gold: #d9a441;
  --danger: #a12e2e;
  --line: #d8e0e4;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: Arial, Helvetica, sans-serif;
  color: var(--ink);
  background: var(--paper);
}
header {
  background: var(--navy);
  color: white;
  padding: 18px 0;
  border-bottom: 5px solid var(--gold);
}
.header-inner, main { width: min(1000px, calc(100% - 36px)); margin: 0 auto; }
.brand { font-size: 1.55rem; font-weight: 700; letter-spacing: .2px; }
.tagline { opacity: .82; margin-top: 3px; font-size: .95rem; }
main { padding: 28px 0 48px; }
.card {
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 22px;
  margin-bottom: 20px;
  box-shadow: 0 2px 8px rgba(0,0,0,.05);
}
.grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 20px; }
@media (max-width: 720px) { .grid { grid-template-columns: 1fr; } }
h1, h2, h3 { margin-top: 0; }
h1 { font-size: 1.8rem; }
h2 { font-size: 1.25rem; }
label { display: block; font-weight: 700; margin: 14px 0 6px; }
input, select {
  width: 100%;
  padding: 10px 11px;
  border: 1px solid #aebbc2;
  border-radius: 5px;
  background: white;
  font-size: 1rem;
}
button, .button {
  display: inline-block;
  margin-top: 16px;
  padding: 10px 16px;
  border: 0;
  border-radius: 5px;
  background: var(--teal);
  color: white;
  font-size: .98rem;
  font-weight: 700;
  text-decoration: none;
  cursor: pointer;
}
button:hover, .button:hover { background: var(--teal-dark); }
.muted { color: var(--muted); }
.notice {
  padding: 12px 14px;
  border-left: 4px solid var(--teal);
  background: #eaf7f6;
  margin-bottom: 18px;
}
.error { border-left-color: var(--danger); background: #faecec; }
.session-bar {
  display: flex;
  justify-content: space-between;
  gap: 15px;
  align-items: center;
  background: #e8eef1;
  border: 1px solid var(--line);
  padding: 11px 14px;
  border-radius: 6px;
  margin-bottom: 20px;
}
.session-bar a { color: var(--navy); font-weight: 700; }
.account-number { font-family: "Courier New", monospace; font-weight: 700; }
.balance { font-size: 2rem; font-weight: 700; color: var(--navy); margin: 8px 0 18px; }
.details { display: grid; grid-template-columns: 170px 1fr; gap: 8px 14px; }
.details div:nth-child(odd) { color: var(--muted); font-weight: 700; }
table { width: 100%; border-collapse: collapse; }
th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid var(--line); }
th { color: var(--muted); font-size: .9rem; }
.amount-in { color: #176b3a; font-weight: 700; }
.amount-out { color: var(--danger); font-weight: 700; }
.small { font-size: .9rem; }
.hero { padding: 14px 0 4px; }
.cheeky { font-size: .92rem; color: var(--muted); }
"""


def db_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db():
    fresh = not DB_PATH.exists()
    with db_conn() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS accounts (
                account_number INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                role TEXT NOT NULL,
                account_type TEXT NOT NULL,
                balance_cents INTEGER NOT NULL,
                pin_salt TEXT,
                pin_hash TEXT,
                student_created INTEGER NOT NULL DEFAULT 0
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS transactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                from_account INTEGER NOT NULL,
                to_account INTEGER NOT NULL,
                amount_cents INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY(from_account) REFERENCES accounts(account_number),
                FOREIGN KEY(to_account) REFERENCES accounts(account_number)
            )
        """)
        if fresh or conn.execute("SELECT COUNT(*) FROM accounts").fetchone()[0] == 0:
            conn.executemany(
                """INSERT INTO accounts
                   (account_number, name, role, account_type, balance_cents, pin_salt, pin_hash, student_created)
                   VALUES (?, ?, ?, ?, ?, NULL, NULL, 0)""",
                SEED_ACCOUNTS,
            )


def money(cents):
    return f"${cents / 100:,.2f}"


def hash_pin(pin, salt_hex=None):
    salt = bytes.fromhex(salt_hex) if salt_hex else os.urandom(16)
    digest = hashlib.pbkdf2_hmac("sha256", pin.encode("utf-8"), salt, 120_000)
    return salt.hex(), digest.hex()


def verify_pin(pin, salt_hex, expected_hash):
    _, calculated = hash_pin(pin, salt_hex)
    return secrets.compare_digest(calculated, expected_hash)


def unique_account_number(conn):
    while True:
        number = secrets.randbelow(90000) + 10000
        exists = conn.execute(
            "SELECT 1 FROM accounts WHERE account_number = ?", (number,)
        ).fetchone()
        if not exists:
            return number


def page(title, body):
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)} | {BANK_NAME}</title>
  <style>{CSS}</style>
</head>
<body>
<header>
  <div class="header-inner">
    <div class="brand">{BANK_NAME}</div>
    <div class="tagline">{TAGLINE}</div>
  </div>
</header>
<main>{body}</main>
</body>
</html>"""


def read_form(handler):
    try:
        length = int(handler.headers.get("Content-Length", "0"))
    except ValueError:
        length = 0
    raw = handler.rfile.read(length).decode("utf-8", errors="replace")
    parsed = parse_qs(raw, keep_blank_values=True)
    return {k: v[0] for k, v in parsed.items()}


def current_session(handler):
    cookie_header = handler.headers.get("Cookie")
    if not cookie_header:
        return None, None
    cookie = SimpleCookie()
    try:
        cookie.load(cookie_header)
    except Exception:
        return None, None
    morsel = cookie.get("secureish_session")
    if not morsel:
        return None, None
    token = morsel.value
    account_number = SESSIONS.get(token)
    if not account_number:
        return None, None
    return token, account_number


class BankHandler(BaseHTTPRequestHandler):
    server_version = "SecureishBank/1.0"

    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {self.client_address[0]} - {fmt % args}")

    def send_html(self, body, status=200, extra_headers=None):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        if extra_headers:
            for key, value in extra_headers:
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location, headers=None):
        self.send_response(303)
        self.send_header("Location", location)
        if headers:
            for key, value in headers:
                self.send_header(key, value)
        self.end_headers()

    def require_login(self):
        token, account_number = current_session(self)
        if not account_number:
            self.redirect("/")
            return None
        return account_number

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return

        if path == "/logout":
            token, _ = current_session(self)
            if token:
                SESSIONS.pop(token, None)
            self.redirect(
                "/",
                headers=[("Set-Cookie", "secureish_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax")],
            )
            return

        if path == "/":
            _, account_number = current_session(self)
            if account_number:
                self.redirect(f"/account?account={account_number}")
                return
            self.show_landing()
            return

        if path == "/account":
            logged_in = self.require_login()
            if logged_in is None:
                return
            raw_account = query.get("account", [str(logged_in)])[0]
            try:
                viewed_account = int(raw_account)
            except ValueError:
                self.send_html(page("Invalid Account", "<div class='card'><h1>Invalid account number</h1></div>"), 400)
                return
            message = query.get("message", [""])[0]
            self.show_account(logged_in, viewed_account, message)
            return

        self.send_html(page("Not Found", "<div class='card'><h1>404</h1><p>Page not found.</p></div>"), 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/register":
            self.register()
            return
        if parsed.path == "/login":
            self.login()
            return
        if parsed.path == "/transfer":
            self.transfer()
            return
        self.send_html(page("Not Found", "<div class='card'><h1>404</h1><p>Page not found.</p></div>"), 404)

    def show_landing(self, error=""):
        error_html = f"<div class='notice error'>{html.escape(error)}</div>" if error else ""
        body = f"""
<div class="hero">
  <h1>Welcome to {BANK_NAME}</h1>
  <p class="muted">Open an account in seconds. Security paperwork takes much longer, so we skipped it.</p>
</div>
{error_html}
<div class="grid">
  <section class="card">
    <h2>Open a New Account</h2>
    <p class="cheeky">Protected by a state-of-the-art four-digit PIN.</p>
    <form method="post" action="/register">
      <label for="name">Full Name</label>
      <input id="name" name="name" maxlength="60" required autocomplete="name">
      <label for="pin">Choose a 4-Digit PIN</label>
      <input id="pin" name="pin" inputmode="numeric" pattern="[0-9]{{4}}" maxlength="4" required autocomplete="new-password">
      <button type="submit">Open Account</button>
    </form>
  </section>
  <section class="card">
    <h2>Existing Customer Login</h2>
    <form method="post" action="/login">
      <label for="account_number">Account Number</label>
      <input id="account_number" name="account_number" inputmode="numeric" pattern="[0-9]{{5}}" maxlength="5" required>
      <label for="login_pin">4-Digit PIN</label>
      <input id="login_pin" name="pin" inputmode="numeric" pattern="[0-9]{{4}}" maxlength="4" required autocomplete="current-password">
      <button type="submit">Log In</button>
    </form>
  </section>
</div>
"""
        self.send_html(page("Welcome", body))

    def register(self):
        form = read_form(self)
        name = " ".join(form.get("name", "").split())
        pin = form.get("pin", "")

        if len(name) < 2 or len(name) > 60:
            self.show_landing("Enter a name between 2 and 60 characters.")
            return
        if not re.fullmatch(r"\d{4}", pin):
            self.show_landing("PINs must contain exactly four digits.")
            return

        with db_conn() as conn:
            account_number = unique_account_number(conn)
            salt_hex, pin_hash = hash_pin(pin)
            conn.execute(
                """INSERT INTO accounts
                   (account_number, name, role, account_type, balance_cents, pin_salt, pin_hash, student_created)
                   VALUES (?, ?, ?, ?, 0, ?, ?, 1)""",
                (account_number, name, "New Customer", "Personal Checking", salt_hex, pin_hash),
            )

        token = secrets.token_urlsafe(32)
        SESSIONS[token] = account_number
        cookie = f"secureish_session={token}; Path=/; HttpOnly; SameSite=Lax"
        self.redirect(f"/account?account={account_number}", headers=[("Set-Cookie", cookie)])

    def login(self):
        form = read_form(self)
        raw_account = form.get("account_number", "")
        pin = form.get("pin", "")
        try:
            account_number = int(raw_account)
        except ValueError:
            self.show_landing("Invalid account number or PIN.")
            return

        with db_conn() as conn:
            row = conn.execute(
                "SELECT * FROM accounts WHERE account_number = ? AND student_created = 1",
                (account_number,),
            ).fetchone()

        if not row or not row["pin_hash"] or not re.fullmatch(r"\d{4}", pin):
            self.show_landing("Invalid account number or PIN.")
            return
        if not verify_pin(pin, row["pin_salt"], row["pin_hash"]):
            self.show_landing("Invalid account number or PIN.")
            return

        token = secrets.token_urlsafe(32)
        SESSIONS[token] = account_number
        cookie = f"secureish_session={token}; Path=/; HttpOnly; SameSite=Lax"
        self.redirect(f"/account?account={account_number}", headers=[("Set-Cookie", cookie)])

    def show_account(self, logged_in_account, viewed_account, message=""):
        with db_conn() as conn:
            viewer = conn.execute(
                "SELECT * FROM accounts WHERE account_number = ?", (logged_in_account,)
            ).fetchone()
            target = conn.execute(
                "SELECT * FROM accounts WHERE account_number = ?", (viewed_account,)
            ).fetchone()
            recipients = conn.execute(
                "SELECT account_number, name FROM accounts WHERE account_number != ? ORDER BY name",
                (viewed_account,),
            ).fetchall()
            transactions = conn.execute(
                """SELECT * FROM transactions
                   WHERE from_account = ? OR to_account = ?
                   ORDER BY id DESC LIMIT 10""",
                (viewed_account, viewed_account),
            ).fetchall()

        if not viewer:
            self.redirect("/logout")
            return
        if not target:
            body = f"""
{self.session_bar(viewer)}
<div class="card"><h1>Account Not Found</h1><p>No account exists with number <span class="account-number">{html.escape(str(viewed_account))}</span>.</p></div>
"""
            self.send_html(page("Account Not Found", body), 404)
            return

        message_html = f"<div class='notice'>{html.escape(message)}</div>" if message else ""
        recipient_options = "\n".join(
            f'<option value="{r["account_number"]}">{r["account_number"]} - {html.escape(r["name"])}</option>'
            for r in recipients
        )

        rows = []
        for tx in transactions:
            if tx["to_account"] == viewed_account:
                direction = "Deposit"
                amount_class = "amount-in"
                amount_text = f"+{money(tx['amount_cents'])}"
                other = f"From {tx['from_account']}"
            else:
                direction = "Transfer"
                amount_class = "amount-out"
                amount_text = f"-{money(tx['amount_cents'])}"
                other = f"To {tx['to_account']}"
            rows.append(
                f"<tr><td>{html.escape(tx['created_at'])}</td><td>{direction}</td><td>{other}</td><td class='{amount_class}'>{amount_text}</td></tr>"
            )
        tx_html = "".join(rows) if rows else "<tr><td colspan='4' class='muted'>No transactions yet.</td></tr>"

        body = f"""
{self.session_bar(viewer)}
{message_html}
<div class="grid">
  <section class="card">
    <h1>Account Overview</h1>
    <div class="details">
      <div>Viewing Account</div><div class="account-number">{target['account_number']}</div>
      <div>Account Holder</div><div>{html.escape(target['name'])}</div>
      <div>Role</div><div>{html.escape(target['role'])}</div>
      <div>Account Type</div><div>{html.escape(target['account_type'])}</div>
    </div>
    <p class="muted small" style="margin-top:20px;margin-bottom:3px;">Available Balance</p>
    <div class="balance">{money(target['balance_cents'])}</div>
  </section>

  <section class="card">
    <h2>Transfer Funds</h2>
    <p class="muted small">Choose a recipient and amount.</p>
    <form method="post" action="/transfer">
      <input type="hidden" name="from_account" value="{target['account_number']}">
      <label for="to_account">Transfer To</label>
      <select id="to_account" name="to_account" required>
        {recipient_options}
      </select>
      <label for="amount">Amount</label>
      <input id="amount" name="amount" type="number" min="0.01" step="0.01" placeholder="0.00" required>
      <button type="submit">Transfer Funds</button>
    </form>
  </section>
</div>

<section class="card">
  <h2>Recent Transactions</h2>
  <table>
    <thead><tr><th>Date/Time</th><th>Type</th><th>Other Account</th><th>Amount</th></tr></thead>
    <tbody>{tx_html}</tbody>
  </table>
</section>
"""
        self.send_html(page(f"Account {target['account_number']}", body))

    def session_bar(self, viewer):
        return f"""
<div class="session-bar">
  <div>
    Logged in as <strong>{html.escape(viewer['name'])}</strong>
    &nbsp;|&nbsp; Your Account: <span class="account-number">{viewer['account_number']}</span>
  </div>
  <div><a href="/account?account={viewer['account_number']}">My Account</a> &nbsp;|&nbsp; <a href="/logout">Log Out</a></div>
</div>
"""

    def transfer(self):
        logged_in = self.require_login()
        if logged_in is None:
            return

        form = read_form(self)
        try:
            from_account = int(form.get("from_account", ""))
            to_account = int(form.get("to_account", ""))
        except ValueError:
            self.send_html(page("Transfer Error", "<div class='card'><h1>Invalid transfer information.</h1></div>"), 400)
            return

        try:
            amount = Decimal(form.get("amount", "")).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        except (InvalidOperation, ValueError):
            self.redirect(f"/account?account={from_account}&message={quote('Enter a valid transfer amount.')}")
            return

        if amount <= 0:
            self.redirect(f"/account?account={from_account}&message={quote('Transfer amount must be greater than $0.00.')}")
            return
        amount_cents = int(amount * 100)
        if amount_cents > 100_000_000_00:
            self.redirect(f"/account?account={from_account}&message={quote('Transfer amount is too large.')}")
            return
        if from_account == to_account:
            self.redirect(f"/account?account={from_account}&message={quote('Choose a different destination account.')}")
            return

        # Intentionally vulnerable access-control logic for this training lab:
        # The application confirms that somebody is logged in, but it NEVER verifies
        # that the logged-in customer owns from_account before processing the transfer.
        with db_conn() as conn:
            try:
                conn.execute("BEGIN IMMEDIATE")
                source = conn.execute(
                    "SELECT * FROM accounts WHERE account_number = ?", (from_account,)
                ).fetchone()
                destination = conn.execute(
                    "SELECT * FROM accounts WHERE account_number = ?", (to_account,)
                ).fetchone()
                if not source or not destination:
                    conn.rollback()
                    self.redirect(f"/account?account={from_account}&message={quote('The selected account could not be found.')}")
                    return
                if source["balance_cents"] < amount_cents:
                    conn.rollback()
                    self.redirect(f"/account?account={from_account}&message={quote('Insufficient funds for this transfer.')}")
                    return

                conn.execute(
                    "UPDATE accounts SET balance_cents = balance_cents - ? WHERE account_number = ?",
                    (amount_cents, from_account),
                )
                conn.execute(
                    "UPDATE accounts SET balance_cents = balance_cents + ? WHERE account_number = ?",
                    (amount_cents, to_account),
                )
                timestamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                conn.execute(
                    "INSERT INTO transactions (from_account, to_account, amount_cents, created_at) VALUES (?, ?, ?, ?)",
                    (from_account, to_account, amount_cents, timestamp),
                )
                conn.commit()
            except Exception:
                conn.rollback()
                raise

        msg = f"Transfer complete: {money(amount_cents)} sent from account {from_account} to account {to_account}."
        self.redirect(f"/account?account={from_account}&message={quote(msg)}")


def main():
    init_db()
    print("=" * 58)
    print(f"  {BANK_NAME}")
    print(f"  {TAGLINE}")
    print("=" * 58)
    print()
    print(f"Application ready: http://{HOST}:{PORT}")
    print("Press Ctrl+C to stop the server.")
    print()
    server = ThreadingHTTPServer((HOST, PORT), BankHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nSecure-ish Savings & Loan has closed for the day.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
PYTHON

chmod 755 "$APP_DIR/app.py"
rm -f "$APP_DIR/bank.db"

if [[ "$(id -u)" -eq 0 ]]; then
    TARGET_GROUP="$(id -gn "$TARGET_USER")"
    chown -R "$TARGET_USER:$TARGET_GROUP" "$APP_DIR"
fi

echo
echo "=========================================================="
echo "  Secure-ish Savings & Loan"
echo "  Banking with confidence-ish."
echo "=========================================================="
echo
echo "Lab files created in: $APP_DIR"
echo "Starting the bank application..."
echo
echo "Open Firefox and visit: http://127.0.0.1:$PORT"
echo "Press Ctrl+C when finished."
echo

if [[ "${SECUREISH_NO_START:-0}" == "1" ]]; then
    echo "SECUREISH_NO_START=1 set; application files were created but the server was not started."
    exit 0
fi

if [[ "$(id -u)" -eq 0 && "$TARGET_USER" != "root" ]]; then
    exec sudo -u "$TARGET_USER" -H python3 "$APP_DIR/app.py"
else
    exec python3 "$APP_DIR/app.py"
fi
