#!/bin/bash
# Firewall for the mail VPS with ufw (the VPS counterpart of openwrt-firewall.conf). Run as root: sudo ./ufw.sh
# Public: SSH, SMTP (25), submission (587). Webmail + IMAP + 465 only over Tailscale.
# Docker-published ports bypass ufw's normal rules, so this hooks ufw into Docker's DOCKER-USER chain:
# from the internet, a published port is reachable only if allowed with `ufw route allow`. Safe to re-run.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }
command -v ufw >/dev/null || apt-get install -y ufw

EXT=$(ip route get 1.1.1.1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
SSH_PORT=${SSH_PORT:-22}
echo "Public interface: $EXT, SSH port: $SSH_PORT"

# Replace our block at the end of ufw's after.rules / after6.rules
for f in /etc/ufw/after.rules /etc/ufw/after6.rules; do
	sed -i '/^# BEGIN mail-docker/,/^# END mail-docker/d' "$f"
	cat >> "$f" <<EOF
# BEGIN mail-docker (added by ufw.sh): Docker-published ports obey 'ufw route' rules
*filter
:ufw-user-forward - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i $EXT -j ufw-user-forward
-A DOCKER-USER -i $EXT -j DROP
COMMIT
# END mail-docker
EOF
done

ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment ssh   # before enabling, so the current session survives
ufw route allow proto tcp from any to any port 25 comment 'mail smtp'
ufw route allow proto tcp from any to any port 587 comment 'mail submission'
ufw allow in on tailscale0 comment tailscale
ufw --force enable
ufw reload
ufw status verbose
