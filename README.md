# Ubuntu Update Notifier

A production-ready cron-based system that checks for `apt` updates daily,
notifies you by email, and lets you **Update Now** or **Remind Me Tomorrow**
directly from the email — no SSH required.

---

## How It Works

```
Daily Cron (08:00)
      │
      ▼
 check_updates.sh
      │
      ├── No updates → exit (no email)
      │
      └── Updates found
            │
            ▼
      📧 Email sent with two buttons
            │
            ├── [✅ Update Now]          → HTTP GET /action?token=…&choice=now
            │         │
            │         ▼
            │   update_handler.py runs apt-get upgrade
            │         │
            │         └── 📧 Confirmation email sent
            │
            └── [⏰ Remind Me Tomorrow] → HTTP GET /action?token=…&choice=later
                      │
                      ▼
                postponed_until file written
                      │
                      └── 📧 "Postponed" acknowledgement email sent
                            │
                      Next day: cron sees postpone is over
                            │
                            └── Loop restarts from top
```

---

## Files

```
ubuntu-update-notifier/
├── config.env                # ← Edit this first!
├── setup.sh                  # One-command installer
├── check_updates.sh          # Daily cron script
├── update_handler.py         # HTTP server for button clicks
├── update_handler.service    # systemd service definition
└── lib/
    ├── email.sh              # SMTP helper (bash)
    └── state.sh              # Token generation & state files
```

---

## Quick Start

### 1. Edit `config.env`

```bash
nano config.env
```

Fill in:

| Key            | Description                                        |
|----------------|----------------------------------------------------|
| `SMTP_HOST`    | Your SMTP server (e.g. `smtp.gmail.com`)           |
| `SMTP_PORT`    | Usually `587` (STARTTLS)                           |
| `SMTP_USER`    | Your email address / SMTP login                    |
| `SMTP_PASS`    | App password (see note below)                      |
| `NOTIFY_EMAIL` | Where notifications are delivered                  |
| `SERVER_HOST`  | LAN IP of this machine (e.g. `192.168.1.100`)      |
| `SERVER_PORT`  | Port for the action handler (default: `8765`)      |

> **Gmail users:** Go to Google Account → Security → App Passwords
> and generate a password for "Mail". Use that as `SMTP_PASS`.

### 2. Run the installer

```bash
sudo bash setup.sh
```

This will:
- Copy files to `/opt/update-notifier/`
- Create the systemd service and start it
- Install the daily cron job (`/etc/cron.d/update-notifier`)
- Send a test email to confirm everything works

### 3. Verify

```bash
# Check service is running
sudo systemctl status update-notifier

# Manually trigger a check
sudo bash /opt/update-notifier/check_updates.sh

# Watch logs
tail -f /var/log/update-notifier.log
```

---

## Security Notes

- Each notification email contains a **unique one-time token** (SHA-256).
- Tokens **expire after 48 hours** and are deleted after use.
- Token files in `/var/lib/update-notifier/` are `chmod 600`.
- `config.env` is `chmod 640` — keep it readable only by root.
- The action handler runs on a **local port** — make sure it is reachable
  from wherever you read email (LAN only is safest). Do **not** expose it
  to the public internet without adding authentication.

---

## Customisation

| Want to…                        | Edit…                                 |
|---------------------------------|---------------------------------------|
| Change cron schedule            | `/etc/cron.d/update-notifier`         |
| Change postpone duration        | `POSTPONE_DAYS` in `config.env`       |
| Change email appearance         | `check_updates.sh` (HTML template)    |
| Change confirmation email look  | `update_handler.py` (`*_email_html`)  |

---

## Uninstall

```bash
sudo systemctl stop update-notifier
sudo systemctl disable update-notifier
sudo rm /etc/systemd/system/update-notifier.service
sudo systemctl daemon-reload
sudo rm -rf /opt/update-notifier /etc/cron.d/update-notifier
sudo rm -rf /var/lib/update-notifier
sudo rm -f /var/log/update-notifier.log
```
