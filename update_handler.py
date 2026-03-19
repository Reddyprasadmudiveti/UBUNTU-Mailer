#!/usr/bin/env python3
"""
update_handler.py
─────────────────
Lightweight HTTP server that receives "Update Now" or "Later"
button clicks from the notification email, then:
  • now   → runs apt-get upgrade, sends confirmation email
  • later → postpones for N days, sends acknowledgement email
"""

import http.server
import urllib.parse
import subprocess
import json
import os
import sys
import logging
import hashlib
import smtplib
import ssl
from datetime import datetime, timedelta
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path

# ── Load config ──────────────────────────────────────────────────
CONFIG_PATH = Path(__file__).parent / "config.env"

def load_config(path):
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, _, v = line.partition("=")
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg

CFG = load_config(CONFIG_PATH)

STATE_DIR   = Path(CFG.get("STATE_DIR", "/var/lib/update-notifier"))
LOG_FILE    = CFG.get("LOG_FILE",  "/var/log/update-notifier.log")
PORT        = int(CFG.get("SERVER_PORT", "8765"))
POSTPONE_DAYS = int(CFG.get("POSTPONE_DAYS", "1"))

STATE_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout),
    ]
)
log = logging.getLogger("update-handler")

# ─────────────────────────────────────────────────────────────────
#  Email helpers
# ─────────────────────────────────────────────────────────────────

def send_email(subject: str, html_body: str):
    """Send an HTML email via SMTP using settings from config.env."""
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"]    = f'{CFG["FROM_NAME"]} <{CFG["SMTP_USER"]}>'
    msg["To"]      = CFG["NOTIFY_EMAIL"]
    msg.attach(MIMEText(html_body, "html"))

    ctx = ssl.create_default_context()
    try:
        with smtplib.SMTP(CFG["SMTP_HOST"], int(CFG["SMTP_PORT"])) as s:
            s.ehlo()
            s.starttls(context=ctx)
            s.login(CFG["SMTP_USER"], CFG["SMTP_PASS"])
            s.sendmail(CFG["SMTP_USER"], CFG["NOTIFY_EMAIL"], msg.as_string())
        log.info(f"Email sent: {subject}")
    except Exception as e:
        log.error(f"Failed to send email: {e}")


def confirmation_email_html(pkg_count: int, duration_secs: float) -> str:
    host = subprocess.getoutput("hostname")
    now  = datetime.now().strftime("%A, %B %-d %Y at %-I:%M %p")
    mins = int(duration_secs // 60)
    secs = int(duration_secs % 60)
    dur  = f"{mins}m {secs}s" if mins else f"{secs}s"

    return f"""<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#f4f6fb;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6fb;padding:40px 0;">
    <tr><td align="center">
      <table width="600" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,0.08);">
        <tr>
          <td style="background:linear-gradient(135deg,#134e5e,#71b280);padding:36px 40px;">
            <p style="margin:0;font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#c8f0d8;font-weight:600;">UPDATE COMPLETE</p>
            <h1 style="margin:8px 0 0;font-size:26px;font-weight:700;color:#fff;">✅ System Updated Successfully</h1>
            <p style="margin:10px 0 0;font-size:14px;color:#c8f0d8;">🖥️ &nbsp;<strong style="color:#fff;">{host}</strong> &nbsp;·&nbsp; {now}</p>
          </td>
        </tr>
        <tr>
          <td style="padding:36px 40px;">
            <p style="margin:0 0 20px;font-size:15px;color:#444;line-height:1.6;">
              All <strong>{pkg_count} package{'' if pkg_count == 1 else 's'}</strong> have been upgraded successfully.
              Your system is now fully up to date.
            </p>
            <table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e8e8e8;border-radius:8px;overflow:hidden;">
              <tr style="background:#f8f9fc;">
                <td style="padding:14px 20px;font-size:13px;color:#888;">Packages upgraded</td>
                <td style="padding:14px 20px;font-size:15px;font-weight:700;color:#134e5e;text-align:right;">{pkg_count}</td>
              </tr>
              <tr>
                <td style="padding:14px 20px;font-size:13px;color:#888;border-top:1px solid #eee;">Duration</td>
                <td style="padding:14px 20px;font-size:15px;font-weight:700;color:#134e5e;text-align:right;border-top:1px solid #eee;">{dur}</td>
              </tr>
              <tr style="background:#f8f9fc;">
                <td style="padding:14px 20px;font-size:13px;color:#888;border-top:1px solid #eee;">Status</td>
                <td style="padding:14px 20px;font-size:15px;font-weight:700;color:#38a169;text-align:right;border-top:1px solid #eee;">SUCCESS ✔</td>
              </tr>
            </table>
          </td>
        </tr>
        <tr>
          <td style="background:#f8f9fc;border-top:1px solid #eee;padding:18px 40px;">
            <p style="margin:0;font-size:12px;color:#aaa;">Sent by <strong>Ubuntu Update Notifier</strong> on <em>{host}</em>.</p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body></html>"""


def postponed_email_html(until_date: str) -> str:
    host = subprocess.getoutput("hostname")
    return f"""<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#f4f6fb;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6fb;padding:40px 0;">
    <tr><td align="center">
      <table width="600" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,0.08);">
        <tr>
          <td style="background:linear-gradient(135deg,#373b44,#4286f4);padding:36px 40px;">
            <p style="margin:0;font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#bdd6ff;font-weight:600;">UPDATE POSTPONED</p>
            <h1 style="margin:8px 0 0;font-size:26px;font-weight:700;color:#fff;">⏰ Reminder Scheduled</h1>
            <p style="margin:10px 0 0;font-size:14px;color:#bdd6ff;">🖥️ &nbsp;<strong style="color:#fff;">{host}</strong></p>
          </td>
        </tr>
        <tr>
          <td style="padding:36px 40px;">
            <p style="margin:0 0 0;font-size:15px;color:#444;line-height:1.6;">
              No problem! The update has been postponed.<br>
              You will receive another notification on <strong style="color:#4286f4;">{until_date}</strong>.
            </p>
          </td>
        </tr>
        <tr>
          <td style="background:#f8f9fc;border-top:1px solid #eee;padding:18px 40px;">
            <p style="margin:0;font-size:12px;color:#aaa;">Sent by <strong>Ubuntu Update Notifier</strong> on <em>{host}</em>.</p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body></html>"""


# ─────────────────────────────────────────────────────────────────
#  Token / state helpers
# ─────────────────────────────────────────────────────────────────

def load_token_state(token: str) -> dict | None:
    token_file = STATE_DIR / f"token_{token}.json"
    if not token_file.exists():
        return None
    with open(token_file) as f:
        state = json.load(f)
    # Expire after 48 h
    created = datetime.fromisoformat(state["created_at"])
    if datetime.now() - created > timedelta(hours=48):
        token_file.unlink(missing_ok=True)
        return None
    return state


def consume_token(token: str):
    """Delete token file — each token is single-use."""
    (STATE_DIR / f"token_{token}.json").unlink(missing_ok=True)


def set_postpone(days: int):
    until = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
    (STATE_DIR / "postponed_until").write_text(until)
    return until


# ─────────────────────────────────────────────────────────────────
#  Update runner
# ─────────────────────────────────────────────────────────────────

def run_updates() -> tuple[int, float]:
    """Run apt-get upgrade -y. Returns (exit_code, duration_seconds)."""
    log.info("Starting apt-get upgrade...")
    start = datetime.now()
    result = subprocess.run(
        ["apt-get", "upgrade", "-y"],
        capture_output=True, text=True
    )
    duration = (datetime.now() - start).total_seconds()
    with open(LOG_FILE, "a") as lf:
        lf.write(result.stdout)
        if result.stderr:
            lf.write(result.stderr)
    log.info(f"apt-get upgrade finished in {duration:.1f}s (rc={result.returncode})")
    # Run autoremove as a bonus
    subprocess.run(["apt-get", "autoremove", "-y"], capture_output=True)
    return result.returncode, duration


# ─────────────────────────────────────────────────────────────────
#  HTTP handler
# ─────────────────────────────────────────────────────────────────

def page(title: str, icon: str, heading: str, body: str, color: str = "#0f2027") -> bytes:
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{title}</title>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      min-height: 100vh; display: flex; align-items: center; justify-content: center;
      background: #f4f6fb;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, sans-serif;
    }}
    .card {{
      background: #fff; border-radius: 16px; overflow: hidden;
      box-shadow: 0 8px 40px rgba(0,0,0,0.12); max-width: 480px; width: 90%;
    }}
    .header {{
      background: {color}; padding: 36px 40px; text-align: center;
    }}
    .icon {{ font-size: 52px; line-height: 1; margin-bottom: 12px; }}
    .header h1 {{ color: #fff; font-size: 22px; font-weight: 700; }}
    .content {{ padding: 32px 40px; font-size: 15px; color: #444; line-height: 1.7; }}
    .footer {{ background: #f8f9fc; border-top: 1px solid #eee; padding: 16px 40px;
               font-size: 12px; color: #aaa; text-align: center; }}
  </style>
</head>
<body>
  <div class="card">
    <div class="header">
      <div class="icon">{icon}</div>
      <h1>{heading}</h1>
    </div>
    <div class="content">{body}</div>
    <div class="footer">Ubuntu Update Notifier · {subprocess.getoutput("hostname")}</div>
  </div>
</body>
</html>"""
    return html.encode()


class UpdateHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        log.info(f"HTTP {fmt % args}")

    def send_page(self, code: int, body: bytes):
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed  = urllib.parse.urlparse(self.path)
        params  = urllib.parse.parse_qs(parsed.query)

        if parsed.path != "/action":
            self.send_page(404, page("Not Found", "🔍", "Not Found",
                                     "<p>This page does not exist.</p>"))
            return

        token  = params.get("token", [""])[0]
        choice = params.get("choice", [""])[0]

        if not token or choice not in ("now", "later"):
            self.send_page(400, page("Bad Request", "⚠️", "Invalid Request",
                                     "<p>Missing or invalid parameters.</p>",
                                     "#c0392b"))
            return

        state = load_token_state(token)
        if state is None:
            self.send_page(410, page("Expired", "⏱️", "Link Expired",
                                     "<p>This link has already been used or has expired (48 h limit).</p>",
                                     "#7f8c8d"))
            return

        consume_token(token)
        pkg_count = state.get("pkg_count", 0)

        # ── Update Now ───────────────────────────────────────────
        if choice == "now":
            self.send_page(200, page(
                "Updating…", "⚙️", "Update In Progress",
                "<p>Updates are running in the background. You will receive a confirmation email once complete.</p>"
                "<p style='margin-top:14px;font-size:13px;color:#888;'>You can close this tab.</p>",
                "linear-gradient(135deg,#134e5e,#71b280)"
            ))
            # Run update asynchronously so HTTP response is flushed first
            import threading
            def do_update():
                rc, duration = run_updates()
                if rc == 0:
                    send_email(
                        f"✅ [{subprocess.getoutput('hostname')}] System Updated Successfully",
                        confirmation_email_html(pkg_count, duration)
                    )
                else:
                    send_email(
                        f"❌ [{subprocess.getoutput('hostname')}] Update Failed",
                        f"<p>apt-get upgrade exited with code {rc}. Check <code>{LOG_FILE}</code> for details.</p>"
                    )
            threading.Thread(target=do_update, daemon=True).start()

        # ── Remind Later ─────────────────────────────────────────
        else:
            until = set_postpone(POSTPONE_DAYS)
            self.send_page(200, page(
                "Postponed", "⏰", "Update Postponed",
                f"<p>Understood! You will be reminded again on <strong>{until}</strong>.</p>"
                "<p style='margin-top:14px;font-size:13px;color:#888;'>You can close this tab.</p>",
                "linear-gradient(135deg,#373b44,#4286f4)"
            ))
            send_email(
                f"⏰ [{subprocess.getoutput('hostname')}] Update Postponed to {until}",
                postponed_email_html(until)
            )
            log.info(f"Updates postponed until {until}")


# ─────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    log.info(f"Update handler listening on 0.0.0.0:{PORT}")
    server = http.server.HTTPServer(("0.0.0.0", PORT), UpdateHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
