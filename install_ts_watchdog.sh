#!/bin/bash
# tailscale-watchdog.sh — debounced + quiet on success
set -euo pipefail

LOGF=/var/log/tailscale-watchdog.log
STATE_DIR=/run/tailscale-watchdog
STATE_FAILCOUNT="$STATE_DIR/failcount"
STATE_LAST="$STATE_DIR/last"           # "healthy" or "unhealthy"
DERP_CHECK=${DERP_CHECK:-0}             # 1 to enable DERP ICMP check

mkdir -p "$STATE_DIR"

log(){ echo "$(date -Is) - $*" >> "$LOGF"; }

restart(){
  log "Watchdog: restarting tailscaled"
  systemctl restart tailscaled || { sleep 2; systemctl restart tailscaled; } || true
}

fail(){
  local why="$1"
  log "FAIL: $why"
  local n=0; [[ -f "$STATE_FAILCOUNT" ]] && n=$(cat "$STATE_FAILCOUNT" 2>/dev/null || echo 0)
  n=$((n+1)); echo "$n" > "$STATE_FAILCOUNT"
  echo "unhealthy" > "$STATE_LAST"
  if (( n >= 2 )); then
    : > "$STATE_FAILCOUNT"
    restart
  fi
  exit 0
}

recover(){
  # Only log once when transitioning unhealthy -> healthy
  if [[ -f "$STATE_LAST" ]] && grep -qx unhealthy "$STATE_LAST"; then
    log "Recovered: Tailscale healthy"
  fi
  : > "$STATE_FAILCOUNT" || true
  echo "healthy" > "$STATE_LAST"
  exit 0
}

# ---- Gates ----
pgrep -x tailscaled >/dev/null                          || fail "G1: tailscaled process not running"

ts4="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
[[ -n "${ts4}" ]]                                       || fail "G2: tailscale ip -4 returned empty"

ip -4 addr show dev tailscale0 | grep -q 'inet '        || fail "G3: tailscale0 missing IPv4"

if [[ "$DERP_CHECK" == "1" ]]; then
  ping -c1 -W2 100.100.100.100 >/dev/null 2>&1         || fail "G4: DERP ICMP to 100.100.100.100 failed"
fi

recover
