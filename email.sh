#!/usr/bin/env bash
# lib/email.sh — shared email-sending helper (uses Python + smtplib)
# Source this file; do not execute directly.

send_email() {
    local to="$1"
    local subject="$2"
    local html_body="$3"

    python3 - <<PYEOF
import smtplib, ssl, sys
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

msg = MIMEMultipart("alternative")
msg["Subject"] = """$subject"""
msg["From"]    = """${FROM_NAME} <${SMTP_USER}>"""
msg["To"]      = """$to"""
msg.attach(MIMEText("""$html_body""", "html"))

ctx = ssl.create_default_context()
try:
    with smtplib.SMTP("${SMTP_HOST}", int("${SMTP_PORT}")) as s:
        s.ehlo(); s.starttls(context=ctx)
        s.login("${SMTP_USER}", "${SMTP_PASS}")
        s.sendmail("${SMTP_USER}", "$to", msg.as_string())
    print("Email sent OK")
except Exception as e:
    print(f"Email error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}
