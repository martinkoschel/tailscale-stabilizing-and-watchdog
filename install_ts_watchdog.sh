#!/usr/bin/env bash
set -euo pipefail

#--- sanity: make sure tailscale package exists (no-op if already present)
sudo apt-get update -qq
sudo apt-get install -y tailscale >/dev/null

#--- tailscaled override: force TCP/DERP (disable UDP), restart policy, path-agnostic up flags
sudo install -d -m 0755 /etc/systemd/system/tailscaled.service.d
sudo tee /etc/systemd/system/tailscaled.service.d/override.conf >/dev/null <<'EOF'
[Unit]
# Allow frequent restarts if needed (place in [Unit], not [Service])
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Environment="TS_DEBUG_DISABLE_UDP=true"
Restart=always
RestartSec=10

# Re-assert runtime flags each start; be path-agnostic & tolerant of transient failures
ExecStartPost=/bin/sh -c 'TS=$$(command -v tailscale || echo /usr/bin/tailscale); \
  "$$TS" up --accept-dns --netfilter-mode=off || { sleep 2; "$$TS" up --accept-dns --netfilter-mode=off; } || true'
EOF

sudo systemctl daemon-reload
sudo systemctl restart tailscaled

#--- watchdog script (quiet on success; logs only FAIL + single "Recovered")
sudo tee /usr/local/bin/tailscale-watchdog.sh >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

LOGF=/var/log/tailscale-watchdog.log
STATE_DIR=/run/tailscale-watchdog
STATE_FAILCOUNT="$STATE_DIR/failcount"
STATE_LAST="$STATE_DIR/last"      # "healthy" or "unhealthy"
DERP_CHECK=${DERP_CHECK:-0}        # set DERP_CHECK=1 to also ICMP 100.100.100.100

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
  if [[ -f "$STATE_LAST" ]] && grep -qx unhealthy "$STATE_LAST"; then
    log "Recovered: Tailscale healthy"
  fi
  : > "$STATE_FAILCOUNT" || true
  echo "healthy" > "$STATE_LAST"
  exit 0
}

# ---- Gates (keep cheap → expensive) ----
pgrep -x tailscaled >/dev/null                          || fail "G1: tailscaled not running"

TSBIN=$(command -v tailscale || true)
[[ -n "$TSBIN" ]]                                       || fail "G2: tailscale CLI missing"

ts4="$("$TSBIN" ip -4 2>/dev/null | head -n1 || true)"
[[ -n "$ts4" ]]                                         || fail "G3: tailscale ip -4 empty"

ip -4 addr show dev tailscale0 | grep -q 'inet '        || fail "G4: no IPv4 on tailscale0"

if [[ "$DERP_CHECK" == "1" ]]; then
  ping -c1 -W2 100.100.100.100 >/dev/null 2>&1         || fail "G5: DERP ICMP 100.100.100.100 failed"
fi

recover
EOF
sudo chmod 0755 /usr/local/bin/tailscale-watchdog.sh

#--- watchdog units
sudo tee /etc/systemd/system/tailscale-watchdog.service >/dev/null <<'EOF'
[Unit]
Description=Tailscale Watchdog (health check & auto-restart)
Wants=network-online.target
After=network-online.target tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tailscale-watchdog.sh
EOF

sudo tee /etc/systemd/system/tailscale-watchdog.timer >/dev/null <<'EOF'
[Unit]
Description=Run Tailscale Watchdog every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
Persistent=true
Unit=tailscale-watchdog.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now tailscale-watchdog.timer tailscaled

#--- verify
echo "CLI: $(command -v tailscale || echo 'MISSING')"
systemctl is-enabled tailscaled >/dev/null && echo "tailscaled enabled"
systemctl is-enabled tailscale-watchdog.timer >/dev/null && echo "watchdog timer enabled"
