#!/usr/bin/env bash
# lib/state.sh — token generation & state file helpers
# Source this file; do not execute directly.

generate_token() {
    # 32-byte hex token derived from urandom + timestamp
    echo "$(date +%s%N)$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)" \
        | sha256sum | awk '{print $1}'
}

save_pending_token() {
    local token="$1"
    local pkg_count="$2"
    mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/token_${token}.json" <<JSON
{
  "token":      "$token",
  "pkg_count":  $pkg_count,
  "created_at": "$(date -Iseconds)"
}
JSON
    # Restrict access — token files contain privileged action links
    chmod 600 "$STATE_DIR/token_${token}.json"
}

# Purge token files older than 48 hours
purge_old_tokens() {
    find "$STATE_DIR" -name "token_*.json" -mmin +2880 -delete 2>/dev/null || true
}
