#!/usr/bin/env bash
# install_ts_watchdog.sh — final authoritative setup (matches ADSB-02/03)

set -euo pipefail

# Self-elevate if needed
if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi

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
# tailscale-watchdog.sh — aggressive health check (as deployed on ADSB-02/03)
set -e

restart_tailscale() {
  echo "$(date -Is) - Watchdog: restarting tailscaled" | tee -a /var/log/tailscale-watchdog.log
  systemctl restart tailscaled
}

# 1) tailscaled process up?
if ! pgrep -x tailscaled >/dev/null; then restart_tailscale; exit 0; fi

# 2) CLI responds (keep --peers=false as on working units)
if ! tailscale status --peers=false >/dev/null 2>&1; then restart_tailscale; exit 0; fi

# 3) tailscale0 has an IPv4?
if ! ip addr show tailscale0 2>/dev/null | grep -q "inet "; then restart_tailscale; exit 0; fi

# 4) Control/DERP reachability (OS ping to well-known TS resolver)
DERP_IP="100.100.100.100"
if ! ping -c 1 -W 2 "$DERP_IP" >/dev/null 2>&1; then restart_tailscale; exit 0; fi

echo "$(date -Is) — Tailscale healthy" | tee -a /var/log/tailscale-watchdog.log
EOF
touch /var/log/tailscale-watchdog.log && chmod 0644 /var/log/tailscale-watchdog.log

echo "== Watchdog service & timer =="
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

echo "== tailscaled override (includes --netfilter-mode=off via ExecStartPost) =="
cat >/etc/systemd/system/tailscaled.service.d/override.conf <<'EOF'
[Unit]
# Disable start-rate limiting
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Environment="TS_DEBUG_DISABLE_UDP=true"
Restart=always
RestartSec=10
# Re-assert desired flags each start (exactly as on working units)
ExecStartPost=/usr/bin/tailscale up --accept-dns --netfilter-mode=off
EOF

echo "== Reload & enable =="
systemctl daemon-reload
systemctl enable --now tailscaled >/dev/null 2>&1 || true
systemctl restart tailscaled
systemctl enable --now tailscale-watchdog.timer

echo "== Verify =="
echo "- tailscale version:"; tailscale version || true
echo "- watchdog hash:"; sha256sum /usr/local/bin/tailscale-watchdog.sh
echo "- tailscaled status (should show Connected):"
systemctl status tailscaled --no-pager | sed -n '1,18p'
echo "- watchdog timer:"
systemctl status tailscale-watchdog.timer --no-pager | sed -n '1,14p'
echo "- watchdog one-off run:"; /usr/local/bin/tailscale-watchdog.sh || true
tail -n 5 /var/log/tailscale-watchdog.log || true
echo "Done."
