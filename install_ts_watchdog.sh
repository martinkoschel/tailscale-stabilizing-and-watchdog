#!/usr/bin/env bash
# install_ts_watchdog.sh — final authoritative + resilient

set -euo pipefail
[ "${EUID:-$(id -u)}" -ne 0 ] && exec sudo -E bash "$0" "$@"

stamp(){ date +%Y%m%d-%H%M%S; }
bk(){ [ -e "$1" ] && cp -a "$1" "$1.bak.$(stamp)" || true; }

echo "== Backups =="
mkdir -p /etc/systemd/system/tailscaled.service.d
bk /usr/local/bin/tailscale-watchdog.sh
bk /etc/systemd/system/tailscale-watchdog.service
bk /etc/systemd/system/tailscale-watchdog.timer
bk /etc/systemd/system/tailscaled.service.d/override.conf

echo "== Watchdog script =="
install -m 0755 /dev/stdin /usr/local/bin/tailscale-watchdog.sh <<'EOF'
#!/bin/bash
# tailscale-watchdog.sh — aggressive health check (resilient restart)
set -e

log(){ echo "$(date -Is) - $*"; }
restart_tailscale(){
  log "Watchdog: restarting tailscaled" | tee -a /var/log/tailscale-watchdog.log
  systemctl restart tailscaled || { sleep 2; systemctl restart tailscaled; } || true
}

# 1) daemon present?
pgrep -x tailscaled >/dev/null || { restart_tailscale; exit 0; }

# 2) CLI responsive?
tailscale status --peers=false >/dev/null 2>&1 || { restart_tailscale; exit 0; }

# 3) interface has IPv4?
ip addr show tailscale0 2>/dev/null | grep -q "inet " || { restart_tailscale; exit 0; }

# 4) control/DERP reachable?
ping -c 1 -W 2 100.100.100.100 >/dev/null 2>&1 || { restart_tailscale; exit 0; }

log "Tailscale healthy" | tee -a /var/log/tailscale-watchdog.log
EOF
touch /var/log/tailscale-watchdog.log && chmod 0644 /var/log/tailscale-watchdog.log

echo "== Watchdog service & timer =="
cat >/etc/systemd/system/tailscale-watchdog.service <<'EOF'
[Unit]
Description=Tailscale Watchdog (health check & auto-restart)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tailscale-watchdog.sh
EOF

cat >/etc/systemd/system/tailscale-watchdog.timer <<'EOF'
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

echo "== tailscaled override (resilient ExecStartPost) =="
cat >/etc/systemd/system/tailscaled.service.d/override.conf <<'EOF'
[Unit]
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Environment="TS_DEBUG_DISABLE_UDP=true"
Restart=always
RestartSec=10
# Retry once after 2s; ignore failure to avoid marking service failed
ExecStartPost=/bin/sh -c '/usr/bin/tailscale up --accept-dns --netfilter-mode=off || { sleep 2; /usr/bin/tailscale up --accept-dns --netfilter-mode=off; } || true'
EOF

echo "== Reload & enable =="
systemctl daemon-reload
systemctl enable --now tailscaled >/dev/null 2>&1 || true
systemctl restart tailscaled
systemctl enable --now tailscale-watchdog.timer

echo "== Verify =="
echo "- tailscale version:"; tailscale version || true
echo "- watchdog hash:"; sha256sum /usr/local/bin/tailscale-watchdog.sh
echo "- tailscaled status (expect Connected):"
systemctl status tailscaled --no-pager | sed -n '1,18p'
echo "- watchdog timer:"
systemctl status tailscale-watchdog.timer --no-pager | sed -n '1,14p'
echo "- watchdog one-off run:"; /usr/local/bin/tailscale-watchdog.sh || true
tail -n 5 /var/log/tailscale-watchdog.log || true
echo "Done."
