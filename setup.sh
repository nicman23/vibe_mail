#!/bin/sh
# On the host: `./setup.sh` asks for the settings, writes .env, sets up weekly updates (cron) and starts the stack.
# In the setup container (`setup.sh apply`, run by compose on every `up`, idempotent):
# creates the mailbox + DKIM keys, publishes A/MX/SPF/DKIM/DMARC to Cloudflare, writes openwrt-firewall.conf.
set -eu

if [ "${1:-}" != apply ]; then
  cd "$(dirname "$0")"
  get() { sed -n "s/^$1=//p" .env 2>/dev/null | tr -d "'"; }
  ask() { # VAR QUESTION [DEFAULT] [secret]
    def=$(get "$1"); def=${def:-${3:-}}
    if [ -n "${4:-}" ]; then
      printf '%s%s: ' "$2" "${def:+ [Enter keeps current]}"; stty -echo; read -r v; stty echo; echo
      case $v in *\'*) echo "Can't contain a single quote (')" >&2; exit 1 ;; esac
    else
      printf '%s%s: ' "$2" "${def:+ [$def]}"; read -r v
    fi
    v=${v:-$def}
    [ -n "$v" ] || { echo "$1 is required" >&2; exit 1; }
    eval "$1=\$v"
  }
  ask MAIL_USER     "Your email address (first mailbox)"
  ask MAIL_PASSWORD "Its password" "" secret
  ask MAIL_HOST     "Mail server name" "mx.${MAIL_USER#*@}"
  ask CF_API_TOKEN  "Cloudflare API token (Zone:Read + DNS:Edit)" "" secret
  ask ACME_EMAIL    "Let's Encrypt account email" "$MAIL_USER"
  def=Y; grep -q '^COMPOSE_PROFILES=$' .env 2>/dev/null && def=n
  printf 'Include Roundcube webmail? (y/n) [%s]: ' "$def"; read -r v
  case ${v:-$def} in [Nn]*) PROFILES= ;; *) PROFILES=webmail ;; esac
  def=Y; [ "$(get AUTO_UPDATE)" = no ] && def=n
  printf 'Update images automatically every Monday 04:00? (y/n) [%s]: ' "$def"; read -r v
  case ${v:-$def} in [Nn]*) AUTO_UPDATE=no ;; *) AUTO_UPDATE=yes ;; esac
  (umask 077; cat > .env <<EOF
# Written by ./setup.sh (re-run it to change), or edit by hand and run: docker compose up -d
MAIL_HOST=$MAIL_HOST
MAIL_USER=$MAIL_USER
MAIL_PASSWORD='$MAIL_PASSWORD'
CF_API_TOKEN='$CF_API_TOKEN'
ACME_EMAIL=$ACME_EMAIL
# Optional services: "webmail" = Roundcube + Caddy, empty = mail server only
COMPOSE_PROFILES=$PROFILES
# Weekly cron job: pull newer images and recreate changed containers (log: docker-data/update.log)
AUTO_UPDATE=$AUTO_UPDATE
EOF
  )
  echo "Wrote .env"

  # Add/remove this project's weekly update job in the current user's crontab
  TAG="# vibe_mail auto-update $PWD"
  if command -v crontab >/dev/null; then
    { crontab -l 2>/dev/null | grep -vF "$TAG" || true
      [ "$AUTO_UPDATE" = no ] || echo "0 4 * * 1 cd '$PWD' && { docker compose pull -q && docker compose up -d && docker image prune -f; } >> docker-data/update.log 2>&1 $TAG"
    } | crontab -
    echo "Weekly updates: $AUTO_UPDATE"
  elif [ "$AUTO_UPDATE" = yes ]; then
    echo "crontab not found: install cron (e.g. apt install cron) and re-run to enable weekly updates" >&2
  fi
  echo "Starting the stack..."
  # Turning webmail off doesn't stop already-running webmail containers by itself
  [ -n "$PROFILES" ] || docker compose rm -sf roundcube caddy
  exec docker compose up -d
fi

apk add --no-cache -q curl jq openssl iproute2

cd /project
CONF=docker-data/dms/config
DOMAINS=$(echo "${DOMAINS:-${MAIL_USER#*@}}" | tr , ' ') # optional; defaults to MAIL_USER's domain

cf() { # METHOD PATH [JSON]
  r=$(curl -sS -X "$1" -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' \
    "https://api.cloudflare.com/client/v4$2" ${3:+--data "$3"})
  echo "$r" | jq -e .success >/dev/null || { echo "Cloudflare $1 $2 failed: $(echo "$r" | jq -c .errors)" >&2; return 1; }
  echo "$r"
}

zone_id() { # walk up the name until a Cloudflare zone matches
  n=$1
  while case $n in *.*) true ;; *) false ;; esac; do
    id=$(cf GET "/zones?name=$n" | jq -r '.result[0].id // empty')
    [ -n "$id" ] && { echo "$id"; return; }
    n=${n#*.}
  done
  echo "No Cloudflare zone for $1 (token needs Zone:Read + DNS:Edit on it)" >&2
  return 1
}

upsert() { # TYPE NAME CONTENT MATCH_PREFIX [MX_PRIORITY] — replaces the record starting with MATCH_PREFIX, else creates
  z=$(zone_id "$2")
  id=$(cf GET "/zones/$z/dns_records?type=$1&name=$2" | jq -r --arg p "$4" \
    '[.result[] | select(.content | ltrimstr("\"") | startswith($p))][0].id // empty')
  body=$(jq -nc --arg t "$1" --arg n "$2" --arg c "$3" --arg prio "${5:-}" \
    '{type:$t, name:$n, content:$c, ttl:300, comment:"managed by mail compose setup"}
     + (if $t == "A" or $t == "AAAA" then {proxied:false} else {} end)
     + (if $prio != "" then {priority:($prio|tonumber)} else {} end)')
  if [ -n "$id" ]; then cf PUT "/zones/$z/dns_records/$id" "$body" >/dev/null
  else cf POST "/zones/$z/dns_records" "$body" >/dev/null; fi
  echo "  $1 $2 -> $(echo "$3" | cut -c1-60)"
}

# --- certbot's Cloudflare credentials (kept out of the mail server's volumes)
mkdir -p docker-data/certbot
(umask 077; echo "dns_cloudflare_api_token = $CF_API_TOKEN" > docker-data/certbot/cf.ini)

# --- mailbox (password in .env always wins, so changing it there + `up` updates it)
mkdir -p $CONF
touch $CONF/postfix-accounts.cf
grep -v "^$MAIL_USER|" $CONF/postfix-accounts.cf > $CONF/accounts.tmp || true
echo "$MAIL_USER|{SHA512-CRYPT}$(openssl passwd -6 "$MAIL_PASSWORD")" >> $CONF/accounts.tmp
mv $CONF/accounts.tmp $CONF/postfix-accounts.cf
echo "Mailbox $MAIL_USER ready"

# --- DKIM: one key per domain, signing config picks the key by domain
mkdir -p $CONF/rspamd/dkim $CONF/rspamd/override.d
cat > $CONF/rspamd/override.d/dkim_signing.conf <<'EOF'
enabled = true;
sign_authenticated = true;
sign_local = false;
try_fallback = false;
use_domain = "header";
use_redis = false;
use_esld = true;
allow_username_mismatch = true;
check_pubkey = true;
selector = "mail";
path = "/tmp/docker-mailserver/rspamd/dkim/$domain.private.txt";
EOF

# --- DNS
IP=$(curl -4sS ipconfig.io)
IP6=$(curl -6sS --max-time 5 ipconfig.io || true)
echo "Publishing DNS (server IP $IP ${IP6:-no IPv6})"
upsert A "$MAIL_HOST" "$IP" ""
[ -z "$IP6" ] || upsert AAAA "$MAIL_HOST" "$IP6" ""
for d in $DOMAINS; do
  key=$CONF/rspamd/dkim/$d.private.txt
  [ -f "$key" ] || openssl genrsa -out "$key" 2048 2>/dev/null
  chmod 644 "$key" # ponytail: world-readable so rspamd's in-container user can read it; chown to its uid if the host is shared
  pub=$(openssl rsa -in "$key" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')
  upsert MX  "$d"                  "$MAIL_HOST"               ""         10
  upsert TXT "$d"                  "v=spf1 mx -all"           "v=spf1"
  upsert TXT "mail._domainkey.$d"  "v=DKIM1; k=rsa; p=$pub"   "v=DKIM1"
  upsert TXT "_dmarc.$d"           "v=DMARC1; p=quarantine"   "v=DMARC1"
done

# --- OpenWrt firewall rules for this host: SMTP (25) + submission (587) from wan, and LAN DNS so MAIL_HOST reaches webmail locally
src() { ip "$@" | sed -n 's/.* src \([^ ]*\).*/\1/p'; }
LAN4=$(src -4 route get 1.1.1.1)
LAN6=$(src -6 route get 2606:4700:4700::1111 2>/dev/null || true)
[ -n "$LAN4" ] || { echo "Can't find this host's LAN IPv4" >&2; exit 1; }
# Last 64 bits of an IPv6 address as "::a:b:c:d" (fw4 suffix match must not include the prefix)
suffix6() {
  echo "$1" | awk -F'::' '{
    nl = ($1 == "") ? 0 : split($1, a, ":"); nr = (NF < 2 || $2 == "") ? 0 : split($2, b, ":")
    for (i = 1; i <= 8; i++) g[i] = 0
    for (i = 1; i <= nl; i++) g[i] = a[i]
    for (i = 1; i <= nr; i++) g[8 - nr + i] = b[i]
    printf "::%s:%s:%s:%s\n", g[5], g[6], g[7], g[8] }'
}

cat > openwrt-firewall.conf <<EOF
# Generated by setup.sh for $MAIL_HOST ($LAN4${LAN6:+ / $LAN6}) on every \`docker compose up\` — don't edit.
# Install on the router (remove any previous mail-smtp sections from /etc/config/firewall first):
#   cat openwrt-firewall.conf >> /etc/config/firewall && fw4 check && service firewall reload
# Make $MAIL_HOST resolve to this host on the LAN (webmail is LAN only):
#   uci add_list dhcp.@dnsmasq[0].address='/$MAIL_HOST/$LAN4' && uci commit dhcp && service dnsmasq restart

config redirect
	option name 'mail-smtp'
	option family 'ipv4'
	option proto 'tcp'
	option src 'wan'
	option src_dport '25'
	option dest 'lan'
	option dest_ip '$LAN4'
	option dest_port '25'
	option target 'DNAT'

config redirect
	option name 'mail-submission'
	option family 'ipv4'
	option proto 'tcp'
	option src 'wan'
	option src_dport '587'
	option dest 'lan'
	option dest_ip '$LAN4'
	option dest_port '587'
	option target 'DNAT'
EOF

# IPv6: no NAT, just allow through. Suffix match (/-64) survives ISP prefix changes.
[ -z "$LAN6" ] || cat >> openwrt-firewall.conf <<EOF

config rule
	option name 'mail-smtp-v6'
	option family 'ipv6'
	option proto 'tcp'
	option src 'wan'
	option dest 'lan'
	option dest_ip '$(suffix6 "$LAN6")/-64'
	option dest_port '25 587'
	option target 'ACCEPT'
EOF
echo "Wrote openwrt-firewall.conf"

echo "Done. Set reverse DNS (PTR) for $IP ${IP6} -> $MAIL_HOST at your hosting provider; Cloudflare can't."
