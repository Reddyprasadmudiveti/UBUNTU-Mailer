#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  check_updates.sh — Checks for apt updates, sends HTML email
#  Scheduled via cron; reads state from STATE_DIR.
# ════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/lib/email.sh"
source "$SCRIPT_DIR/lib/state.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── 1. Check for pending postponement ──────────────────────────
POSTPONE_FILE="$STATE_DIR/postponed_until"
if [[ -f "$POSTPONE_FILE" ]]; then
    POSTPONE_UNTIL=$(cat "$POSTPONE_FILE")
    TODAY=$(date '+%Y-%m-%d')
    if [[ "$TODAY" < "$POSTPONE_UNTIL" ]]; then
        log "Updates postponed until $POSTPONE_UNTIL — skipping today."
        exit 0
    else
        log "Postponement period over — checking for updates."
        rm -f "$POSTPONE_FILE"
    fi
fi

# ── 2. Refresh package list ─────────────────────────────────────
log "Running apt-get update..."
apt-get update -qq 2>>"$LOG_FILE"

# ── 3. Count available upgrades ─────────────────────────────────
UPGRADES=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" | grep -v "^$" || true)
UPDATE_COUNT=$(echo "$UPGRADES" | grep -c "/" || true)

if [[ "$UPDATE_COUNT" -eq 0 ]]; then
    log "System is up to date. No email sent."
    exit 0
fi

log "Found $UPDATE_COUNT update(s) — preparing notification email."

# ── 4. Build package table rows ─────────────────────────────────
PKG_ROWS=""
while IFS= read -r line; do
    [[ -z "$line" || "$line" == Listing* ]] && continue
    PKG_NAME=$(echo "$line" | awk '{print $1}' | cut -d'/' -f1)
    PKG_VER=$(echo "$line"  | grep -oP '\[.*?\]' | tr -d '[]' || echo "—")
    PKG_ROWS+="<tr><td style='padding:6px 12px;border-bottom:1px solid #e8e8e8;font-family:monospace;font-size:13px;color:#1a1a2e;'>$PKG_NAME</td><td style='padding:6px 12px;border-bottom:1px solid #e8e8e8;font-size:13px;color:#555;text-align:right;'>$PKG_VER</td></tr>"
done <<< "$UPGRADES"

# ── 5. Generate a one-time security token ──────────────────────
TOKEN=$(generate_token)
save_pending_token "$TOKEN" "$UPDATE_COUNT"

ACTION_BASE="http://${SERVER_HOST}:${SERVER_PORT}/action"
URL_NOW="$ACTION_BASE?token=$TOKEN&choice=now"
URL_LATER="$ACTION_BASE?token=$TOKEN&choice=later"

# ── 6. Build and send the notification email ────────────────────
HOSTNAME_LABEL=$(hostname)
DATE_LABEL=$(date '+%A, %B %-d %Y')

SUBJECT="🔔 [$HOSTNAME_LABEL] $UPDATE_COUNT Update(s) Available — $DATE_LABEL"

HTML_BODY=$(cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Updates Available</title>
</head>
<body style="margin:0;padding:0;background:#f4f6fb;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,sans-serif;">

  <!-- Wrapper -->
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6fb;padding:40px 0;">
    <tr><td align="center">

      <!-- Card -->
      <table width="600" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,0.08);">

        <!-- Header -->
        <tr>
          <td style="background:linear-gradient(135deg,#0f2027,#203a43,#2c5364);padding:36px 40px;">
            <p style="margin:0;font-size:11px;letter-spacing:3px;text-transform:uppercase;color:#7ecfff;font-weight:600;">SYSTEM NOTIFICATION</p>
            <h1 style="margin:8px 0 0;font-size:26px;font-weight:700;color:#ffffff;line-height:1.2;">
              $UPDATE_COUNT Package Update$([ "$UPDATE_COUNT" -gt 1 ] && echo "s" || echo "") Available
            </h1>
            <p style="margin:10px 0 0;font-size:14px;color:#a8c8e8;">
              🖥️ &nbsp;<strong style="color:#ffffff;">$HOSTNAME_LABEL</strong> &nbsp;·&nbsp; $DATE_LABEL
            </p>
          </td>
        </tr>

        <!-- Body -->
        <tr>
          <td style="padding:36px 40px 24px;">
            <p style="margin:0 0 20px;font-size:15px;color:#444;line-height:1.6;">
              Your Ubuntu system has <strong>$UPDATE_COUNT package$([ "$UPDATE_COUNT" -gt 1 ] && echo "s" || echo "")</strong> ready to be upgraded.
              Keeping your system up to date ensures the latest security patches and bug fixes are applied.
            </p>

            <!-- Package Table -->
            <table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e8e8e8;border-radius:8px;overflow:hidden;margin-bottom:28px;">
              <thead>
                <tr style="background:#f8f9fc;">
                  <th style="padding:10px 12px;text-align:left;font-size:11px;letter-spacing:1px;text-transform:uppercase;color:#888;font-weight:600;border-bottom:1px solid #e8e8e8;">Package</th>
                  <th style="padding:10px 12px;text-align:right;font-size:11px;letter-spacing:1px;text-transform:uppercase;color:#888;font-weight:600;border-bottom:1px solid #e8e8e8;">New Version</th>
                </tr>
              </thead>
              <tbody>$PKG_ROWS</tbody>
            </table>

            <p style="margin:0 0 8px;font-size:14px;color:#555;font-weight:600;">What would you like to do?</p>
          </td>
        </tr>

        <!-- Action Buttons -->
        <tr>
          <td style="padding:0 40px 36px;">
            <table cellpadding="0" cellspacing="0">
              <tr>
                <td style="padding-right:12px;">
                  <a href="$URL_NOW"
                     style="display:inline-block;padding:14px 28px;background:linear-gradient(135deg,#11998e,#38ef7d);color:#fff;font-size:15px;font-weight:700;text-decoration:none;border-radius:8px;letter-spacing:0.3px;">
                    ✅ &nbsp;Update Now
                  </a>
                </td>
                <td>
                  <a href="$URL_LATER"
                     style="display:inline-block;padding:14px 28px;background:#f1f3f8;color:#444;font-size:15px;font-weight:600;text-decoration:none;border-radius:8px;border:1px solid #dde0ea;letter-spacing:0.3px;">
                    ⏰ &nbsp;Remind Me Tomorrow
                  </a>
                </td>
              </tr>
            </table>
            <p style="margin:16px 0 0;font-size:12px;color:#aaa;">
              Clicking a button above will open a brief confirmation page in your browser.<br>
              These links are single-use and expire after 48 hours.
            </p>
          </td>
        </tr>

        <!-- Footer -->
        <tr>
          <td style="background:#f8f9fc;border-top:1px solid #eee;padding:18px 40px;">
            <p style="margin:0;font-size:12px;color:#aaa;line-height:1.5;">
              Sent by <strong>Ubuntu Update Notifier</strong> running on <em>$HOSTNAME_LABEL</em>.<br>
              To disable notifications, remove the cron entry: <code>sudo crontab -e</code>
            </p>
          </td>
        </tr>

      </table>
    </td></tr>
  </table>

</body>
</html>
HTML
)

send_email "$NOTIFY_EMAIL" "$SUBJECT" "$HTML_BODY"
log "Notification email sent to $NOTIFY_EMAIL (token: ${TOKEN:0:8}…)"
