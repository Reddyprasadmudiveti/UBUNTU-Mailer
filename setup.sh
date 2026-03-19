#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  setup.sh — One-command installer for Ubuntu Update Notifier
#  Run as root: sudo bash setup.sh
# ════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▶${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
die()     { echo -e "${RED}✘ ERROR:${RESET} $*" >&2; exit 1; }

[[ "$EUID" -ne 0 ]] && die "Please run as root: sudo bash setup.sh"

INSTALL_DIR="/opt/update-notifier"
SERVICE_NAME="update-notifier"

echo ""
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo -e "${BOLD}   Ubuntu Update Notifier — Setup         ${RESET}"
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo ""

# ── 1. Preflight checks ─────────────────────────────────────────
info "Checking prerequisites..."
command -v python3 >/dev/null 2>&1 || die "python3 not found. Install with: apt install python3"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found — this script requires Ubuntu/Debian."
success "Prerequisites OK"

# ── 2. Validate config ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.env"
[[ -f "$CONFIG" ]] || die "config.env not found at $CONFIG"

source "$CONFIG"

[[ -z "${SMTP_USER:-}"    ]] && die "SMTP_USER is not set in config.env"
[[ -z "${SMTP_PASS:-}"    ]] && die "SMTP_PASS is not set in config.env"
[[ -z "${NOTIFY_EMAIL:-}" ]] && die "NOTIFY_EMAIL is not set in config.env"
[[ -z "${SERVER_HOST:-}"  ]] && die "SERVER_HOST is not set in config.env"

success "Configuration validated"

# ── 3. Install files ────────────────────────────────────────────
info "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/lib"
cp "$SCRIPT_DIR/config.env"          "$INSTALL_DIR/"
cp "$SCRIPT_DIR/check_updates.sh"    "$INSTALL_DIR/"
cp "$SCRIPT_DIR/update_handler.py"   "$INSTALL_DIR/"
cp "$SCRIPT_DIR/lib/email.sh"        "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/lib/state.sh"        "$INSTALL_DIR/lib/"
chmod +x "$INSTALL_DIR/check_updates.sh"
chmod 640 "$INSTALL_DIR/config.env"   # protect credentials
success "Files installed"

# ── 4. Create state / log directories ──────────────────────────
STATE_DIR="${STATE_DIR:-/var/lib/update-notifier}"
LOG_FILE="${LOG_FILE:-/var/log/update-notifier.log}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"
success "State and log directories ready"

# ── 5. Install systemd service ──────────────────────────────────
info "Installing systemd service..."
cp "$SCRIPT_DIR/update_handler.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    success "Service '${SERVICE_NAME}' is running"
else
    warn "Service failed to start — check: journalctl -u ${SERVICE_NAME} -n 30"
fi

# ── 6. Install cron job (runs at 08:00 daily) ───────────────────
info "Installing cron job..."
CRON_CMD="0 8 * * * root $INSTALL_DIR/check_updates.sh >> $LOG_FILE 2>&1"
CRON_FILE="/etc/cron.d/update-notifier"
echo "$CRON_CMD" > "$CRON_FILE"
chmod 644 "$CRON_FILE"
success "Cron job installed: $CRON_FILE"

# ── 7. Send a test email ────────────────────────────────────────
info "Sending test email to $NOTIFY_EMAIL..."
python3 - <<PYEOF
import smtplib, ssl
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
import socket

msg = MIMEMultipart("alternative")
msg["Subject"] = "✅ Update Notifier is configured correctly"
msg["From"]    = f"${FROM_NAME} <${SMTP_USER}>"
msg["To"]      = "${NOTIFY_EMAIL}"
msg.attach(MIMEText("""
<p style="font-family:sans-serif;font-size:15px;color:#333;">
  <strong>Ubuntu Update Notifier</strong> has been installed and configured successfully on
  <code style="background:#f4f4f4;padding:2px 6px;border-radius:4px;">${SERVER_HOST}</code>.<br><br>
  Daily update checks are scheduled for <strong>08:00</strong>.<br>
  Buttons in future emails will link to
  <code style="background:#f4f4f4;padding:2px 6px;border-radius:4px;">http://${SERVER_HOST}:${SERVER_PORT}</code>.
</p>
""", "html"))

ctx = ssl.create_default_context()
try:
    with smtplib.SMTP("${SMTP_HOST}", ${SMTP_PORT}) as s:
        s.ehlo(); s.starttls(context=ctx)
        s.login("${SMTP_USER}", "${SMTP_PASS}")
        s.sendmail("${SMTP_USER}", "${NOTIFY_EMAIL}", msg.as_string())
    print("Test email sent successfully.")
except Exception as e:
    print(f"Warning: could not send test email: {e}")
PYEOF

# ── 8. Summary ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Cron schedule:${RESET}    Daily at 08:00"
echo -e "  ${BOLD}Action handler:${RESET}   http://${SERVER_HOST}:${SERVER_PORT}"
echo -e "  ${BOLD}Log file:${RESET}         $LOG_FILE"
echo -e "  ${BOLD}State directory:${RESET}  $STATE_DIR"
echo ""
echo -e "  ${CYAN}Useful commands:${RESET}"
echo -e "    sudo systemctl status $SERVICE_NAME"
echo -e "    sudo journalctl -u $SERVICE_NAME -f"
echo -e "    sudo bash $INSTALL_DIR/check_updates.sh   # test run"
echo ""
