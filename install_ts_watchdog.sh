#!/bin/bash
set -euo pipefail

LOGF=/var/log/tailscale-watchdog.log
STATE_DIR=/run/tailscale-watchdog
STATE_FAILCOUNT="$STATE_DIR/failcount"
STATE_LAST="$STATE_DIR/last"
DERP_CHECK=${DERP_CHECK:-0}        # set to 1 to also ICMP 100.100.100.100
FAILS_TO_RESTART=${FAILS_TO_RESTART:-3}   # was 2; bump to 3 to reduce flaps
RETRY_DELAY=${RETRY_DELAY:-15}            # seconds to re-check before counting a FAIL

mkdir -p "$STATE_DIR"

log(){ echo "$(date -Is) - $*" >> "$LOGF"; }

restart(){
  log "Watchdog: restarting tailscaled"
  systemctl restart tailscaled || { sleep 2; systemctl restart tailscaled; } || true
}

# one-shot check helper with single retry after RETRY_DELAY
check_or_retry(){
  local desc="$1"; shift
  if "$@"; then return 0; fi
  sleep "$RETRY_DELAY"
  "$@" && return 0
  log "FAIL: $desc"
  return 1
}

record_fail_and_maybe_restart(){
  local n=0; [[ -f "$STATE_FAILCOUNT" ]] && n=$(cat "$STATE_FAILCOUNT" 2>/dev/null || echo 0)
  n=$((n+1)); echo "$n" > "$STATE_FAILCOUNT"
  echo "unhealthy" > "$STATE_LAST"
  if (( n >= FAILS_TO_RESTART )); then
    : > "$STATE_FAILCOUNT"
    restart
  fi
  exit 0
}

recover(){
  if [[ -f "$STATE_LAST" ]] && grep -qx unhealthy "$STATE_LAST"; then
    log "Recovered: Tailscale healthy"
  fi
  : > "$STATE_FAILCOUNT" || true
  echo "healthy" > "$STATE_LAST"
  exit 0
}

# ---- Gates (cheap → expensive) ----
check_or_retry "G1: tailscaled not running" pgrep -x tailscaled >/dev/null || record_fail_and_maybe_restart

TSBIN=$(command -v tailscale || true)
check_or_retry "G2: tailscale CLI missing" test -n "$TSBIN" || record_fail_and_maybe_restart

# Use Tailscale's own view first
ts4="$("$TSBIN" ip -4 2>/dev/null | head -n1 || true)"
check_or_retry "G2: tailscale ip -4 returned empty" test -n "$ts4" || record_fail_and_maybe_restart

# Cross-check OS interface only if the above succeeded
check_or_retry "G3: tailscale0 missing IPv4" bash -c "ip -4 addr show dev tailscale0 | grep -q 'inet '" || record_fail_and_maybe_restart

# Optional DERP reachability
if [[ "$DERP_CHECK" == "1" ]]; then
  check_or_retry "G5: DERP ICMP 100.100.100.100 failed" ping -c1 -W2 100.100.100.100 >/dev/null 2>&1 || record_fail_and_maybe_restart
fi

recover
EOF

sudo chmod 0755 /usr/local/bin/tailscale-watchdog.sh
sudo systemctl restart tailscale-watchdog.timer
