#!/usr/bin/env bash
# install_ts_watchdog.sh — one-shot, idempotent setup matching ADSB-02/03 working config

set -euo pipefail

# Self-elevate if not root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

stamp() { date +%Y%m%d-%H%M%S; }
bk() { [ -e "$1" ] && cp -a "$1" "$1.bak.$(stamp)" || true; }

echo "== Backing up any existing files =="
mkdir -p /etc/systemd/system/tailscaled.service.d
bk /usr/local/bin/tailscale-watchdog.sh
bk /etc/systemd/system/tailscale-watchdog.service
bk /etc/systemd/system/tailscale-watchdog.timer
bk /etc/systemd/system/tailscaled.service.d/override.conf

echo "== Installing watchdog script =="
install -m 0755 /dev/stdin /usr/local/bin/tailscale-watchdog.sh <<'EOF'
#!/bin/bash
# tailscale-watchdog.sh  — aggressive Tailscale health check (matches ADSB-02/03)

set -e

restart_tailscale() {
    echo "$(date -Is) - Watchdog: restarting tailscaled" | tee -a /var/log/tailscale-watchdog.log
    systemctl restart tailscaled
}

# 1) tailscaled process
if ! pgrep -x tailscaled >/dev/null; then
    restart_tailscale
    exit 0
fi

# 2) CLI responds (keep --peers=false exactly as in working unit)
if ! tailscale status --peers=false >/dev/null 2>&1; then
    restart_tailscale
    exit 0
fi

# 3) tailscale0 has an IPv4
if ! ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
    restart_tailscale
    exit 0
fi

# 4) Control/DERP reachability via Tailscale resolver IP
DERP_IP="100.100.100.100"
if ! ping -c 1 -W 2 "$DERP_IP" >/dev/null 2>&1; then
    restart_tailscale
    exit 0
fi

echo "$(date -Is) — Tailscale healthy" | tee -a /var/log/tailscale-watchdog.log
exit 0
EOF

# Ensure log exists
touch /var/log/tailscale-watchdog.log
chmod 0644 /var/log/tailscale-watchdog.log

echo "== Writing watchdog service & timer =="
cat >/etc/systemd/system/tailscale-watchdog.service <<'EOF'
[Unit]
Description=Tailscale watchdog health check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tailscale-watchdog.sh
EOF

cat >/etc/systemd/system/tailscale-watchdog.timer <<'EOF'
[Unit]
Description=Run Tailscale watchdog every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
Persistent=true
Unit=tailscale-watchdog.service

[Install]
WantedBy=timers.target
EOF

echo "== Writing tailscaled override (prevents flapping; matches working units) =="
cat >/etc/systemd/system/tailscaled.service.d/override.conf <<'EOF'
[Unit]
# Disable start throttling so restarts aren’t rate-limited
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Environment="TS_DEBUG_DISABLE_UDP=true"
Restart=always
RestartSec=10
# Re-assert desired runtime flags on each start
ExecStartPost=/usr/bin/tailscale up --accept-dns --netfilter-mode=off
EOF

echo "== Reloading systemd & enabling units =="
systemctl daemon-reload
systemctl enable --now tailscaled >/dev/null 2>&1 || true
systemctl restart tailscaled
systemctl enable --now tailscale-watchdog.timer

echo "== Summary =="
echo "- tailscale version:"
tailscale version || true
echo
echo "- watchdog script hash:"
sha256sum /usr/local/bin/tailscale-watchdog.sh
echo
echo "- tailscaled status (should say Connected):"
systemctl status tailscaled --no-pager | sed -n '1,18p'
echo
echo "- watchdog timer:"
systemctl status tailscale-watchdog.timer --no-pager | sed -n '1,14p'
echo
echo "Test run watchdog once:"
/usr/local/bin/tailscale-watchdog.sh || true
tail -n 5 /var/log/tailscale-watchdog.log || true

echo
echo "Done. This host now matches the working configuration."
