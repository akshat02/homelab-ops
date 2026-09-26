#!/bin/sh
# ============================================================
# drift-check.sh — homelab-ops repo drift check
#
# Compares live server configs against the sanitized homelab-ops
# repo and reports anything that changed on the server but is not
# yet reflected in the repo. Intended to run from the OpenClaw
# drift-check cron (daily) or manually on the server.
#
#   Run:        sh drift-check.sh
#   Full diff:  sh drift-check.sh --verbose
#   Exit code:  0 = in sync, 1 = drift detected
# ============================================================

set -u

# ─── Config: edit these to match your environment ─────────────
# (server copy holds real values; repo copy keeps placeholders)
LIVE_USER="${LIVE_USER:-your_username}"   # OS username on the server
LIVE_AGENT="${LIVE_AGENT:-your_agent}"    # account name used in OpenClaw
                                          # service / token names
HOME_DIR="${HOME_DIR:-/home/${LIVE_USER}}"
REPO_DIR="${REPO_DIR:-${HOME_DIR}/homelab-ops}"
# --- END CONFIG ------------------------------------------------

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

# Live file -> repo file pairs, relative to HOME_DIR / REPO_DIR.
PAIRS="daily_backup.sh|scripts/daily_backup.sh
shutdown-server.sh|scripts/shutdown-server.sh
startup-data-drives.sh|scripts/startup-data-drives.sh
shutdown-data-drives.sh|scripts/shutdown-data-drives.sh
openclaw/docker-compose.yml|configs/openclaw/docker-compose.yml
nextcloud/docker-compose.yml|configs/nextcloud/docker-compose.yml
immich-app/docker-compose.yml|configs/immich-app/docker-compose.yml
drift-check.sh|scripts/drift-check.sh"

# Map a LIVE file to the repo's placeholder conventions.
canon_live() {
    sed -e "s|/home/${LIVE_USER}|<HOME>|g" \
        -e 's|/home/${SERVER_USER}|<HOME>|g' \
        -e "s|~/|<HOME>/|g" \
        -e "s|openclaw-${LIVE_AGENT}|openclaw-agent|g" \
        -e "s|TELEGRAM_TOKEN_${LIVE_AGENT}|TELEGRAM_TOKEN_USER|gi" \
        -e "s|agents/${LIVE_AGENT}|agents/user|g" \
        -e "s|${LIVE_USER}|<USER>|g"
}

# Normalize a REPO file's own placeholder styles.
canon_repo() {
    sed -e 's|your_username|<USER>|g' \
        -e 's|/home/${SERVER_USER}|<HOME>|g'
}

# --- SELF-CHECK START ---
# (everything below is compared verbatim between the live and repo
# copies of this script; the config block above is intentionally
# different, and the canon functions are excluded to avoid
# self-referential rule matches)

TMP="${TMPDIR:-/tmp}"
REPORT="${TMP}/drift-report.$$"
DRIFTS="${TMP}/drift-diffs.$$"
: > "$REPORT"
: > "$DRIFTS"
trap 'rm -f "$REPORT" "$DRIFTS" "${TMP}/dc.live.$$" "${TMP}/dc.repo.$$" "${TMP}/dc.diff.$$"' EXIT HUP INT TERM

printf '🔭 homelab-ops drift check · %s\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')" >> "$REPORT"

ok_count=0
drift_count=0
ok_list=""

IFS='
'
for pair in $PAIRS; do
    live_rel="${pair%%|*}"
    repo_rel="${pair#*|}"
    live_file="${HOME_DIR}/${live_rel}"
    repo_file="${REPO_DIR}/${repo_rel}"

    if [ ! -f "$live_file" ]; then
        printf '  ⚠️  %s — live file missing: <HOME>/%s\n' "$repo_rel" "$live_rel" >> "$DRIFTS"
        drift_count=$((drift_count + 1))
        continue
    fi
    if [ ! -f "$repo_file" ]; then
        printf '  ⚠️  %s — MISSING in repo (live has it, repo not updated)\n' "$repo_rel" >> "$DRIFTS"
        drift_count=$((drift_count + 1))
        continue
    fi

    if [ "$live_rel" = "drift-check.sh" ]; then
        # self-check: compare the execution logic below the marker
        sed -n '/# --- SELF-CHECK START ---/,$p' "$live_file" > "${TMP}/dc.live.$$"
        sed -n '/# --- SELF-CHECK START ---/,$p' "$repo_file" > "${TMP}/dc.repo.$$"
    else
        canon_live < "$live_file" > "${TMP}/dc.live.$$"
        canon_repo < "$repo_file" > "${TMP}/dc.repo.$$"
    fi

    if diff -u "${TMP}/dc.repo.$$" "${TMP}/dc.live.$$" > "${TMP}/dc.diff.$$" 2>&1; then
        ok_count=$((ok_count + 1))
        ok_list="${ok_list}${live_rel} · "
    else
        drift_count=$((drift_count + 1))
        add=$(grep -c '^+[^+]' "${TMP}/dc.diff.$$")
        del=$(grep -c '^-[^-]' "${TMP}/dc.diff.$$")
        printf '  ⚠️  %s — differs from live (+%s/−%s lines)\n' "$repo_rel" "$add" "$del" >> "$DRIFTS"
        if [ "$VERBOSE" = "1" ]; then
            sed 's/^/       /' "${TMP}/dc.diff.$$" >> "$DRIFTS"
        fi
    fi
done
unset IFS

if [ "$drift_count" = "0" ]; then
    printf '✅ In sync — all %s tracked files match the repo template.\n' "$ok_count" >> "$REPORT"
else
    printf '⚠️  Drift (%s):\n' "$drift_count" >> "$REPORT"
    cat "$DRIFTS" >> "$REPORT"
    printf '\n✅ In sync (%s): %s\n' "$ok_count" "${ok_list% · }" >> "$REPORT"
    printf '\nHint: full diffs via `sh %s/drift-check.sh --verbose`\n' "$HOME_DIR" >> "$REPORT"
fi

cat "$REPORT"
[ "$drift_count" = "0" ]
