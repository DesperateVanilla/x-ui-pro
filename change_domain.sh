#!/bin/bash
# change_domain.sh - Reissue certs and update domains in 3x-ui-pro

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[1;41m Please run as root (sudo) \e[0m"
  exit 1
fi

echo -e "\e[32m=== X-UI-PRO Domain Changer ===\e[0m"

new_domain=""
new_reality_domain=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -subdomain) new_domain="$2"; shift 2;;
    -reality_domain) new_reality_domain="$2"; shift 2;;
    *) 
      if [[ -z "$new_domain" ]]; then
        new_domain="$1"
      elif [[ -z "$new_reality_domain" ]]; then
        new_reality_domain="$1"
      fi
      shift 1;;
  esac
done

while [[ -z "$new_domain" ]]; do
    echo -en "Enter NEW available subdomain (sub.domain.tld): " && read -r new_domain || exit 1
done
new_domain=$(echo "$new_domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
new_domain=${new_domain%.}

while [[ -z "$new_reality_domain" ]]; do
    echo -en "Enter NEW available subdomain for REALITY (sub.domain.tld): " && read -r new_reality_domain || exit 1
done
new_reality_domain=$(echo "$new_reality_domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
new_reality_domain=${new_reality_domain%.}


for dependency in curl dig python3; do
    command -v "$dependency" >/dev/null 2>&1 || {
        echo "$dependency is required. Install curl, dnsutils and python3 first." >&2
        exit 1
    }
done

# DNS helpers
validate_domains() {
    python3 - "$@" <<'PY'
import re
import sys

domains = sys.argv[1:]
if len(domains) != 2 or domains[0] == domains[1]:
    sys.exit("Panel and REALITY domains must be different.")
for domain in domains:
    labels = domain.split(".")
    if len(domain) > 253 or len(labels) < 2 or not all(
        re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in labels
    ) or all(label.isdigit() for label in labels):
        sys.exit("Invalid domain: " + domain + ". Use an ASCII/punycode hostname without a URL or path.")
PY
}

discover_public_ips() {
    IP4=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org) ||
        IP4=$(curl -4fsS --connect-timeout 5 --max-time 10 https://ipv4.icanhazip.com) || {
            echo "Cannot determine the public IPv4 address. Check network access." >&2
            return 1
        }
    if ! python3 -c 'import ipaddress, sys; ipaddress.IPv4Address(sys.argv[1])' "$IP4" 2>/dev/null; then
        echo "Invalid public IPv4 address: $IP4" >&2
        return 1
    fi
    IP6=$(curl -6fsS --connect-timeout 5 --max-time 10 https://api6.ipify.org 2>/dev/null) || IP6=""
    python3 -c 'import ipaddress, sys; ipaddress.IPv6Address(sys.argv[1])' "$IP6" 2>/dev/null || IP6=""
}

dns_records_match() {
    python3 - "$IP4" "${IP6:-}" "$1" "$2" <<'PY'
import ipaddress
import sys

ipv4, ipv6, a, aaaa = sys.argv[1:]
expected4 = ipaddress.IPv4Address(ipv4)
expected6 = ipaddress.IPv6Address(ipv6) if ipv6 else None
records4 = [line.split()[4] for line in a.splitlines() if len(line.split()) >= 5 and line.split()[3] == "A"]
records6 = [line.split()[4] for line in aaaa.splitlines() if len(line.split()) >= 5 and line.split()[3] == "AAAA"]
try:
    ready = "status: NOERROR," in a and "status: NOERROR," in aaaa and bool(records4)
    ready = ready and all(ipaddress.IPv4Address(value) == expected4 for value in records4)
    ready = ready and all(ipaddress.IPv6Address(value) == expected6 for value in records6)
except ValueError:
    ready = False
sys.exit(0 if ready else 1)
PY
}

wait_for_dns() {
    validate_domains "$@" || return 1
    local host resolver a aaaa ready
    local -a resolver_args
    echo "Waiting for DNS: A -> $IP4; AAAA -> ${IP6:-remove AAAA records}."
    echo "Checking system DNS, 1.1.1.1 and 8.8.8.8 every 15 seconds. Ctrl+C to cancel."
    echo "For Cloudflare, use DNS Only (grey cloud)."
    while true; do
        ready=true
        for host in "$@"; do
            for resolver in system 1.1.1.1 8.8.8.8; do
                resolver_args=()
                [[ "$resolver" == system ]] || resolver_args=("@$resolver")
                if ! a=$(dig -r "${resolver_args[@]}" +time=2 +tries=1 +noall +answer +comments "$host" A 2>/dev/null) ||
                   ! aaaa=$(dig -r "${resolver_args[@]}" +time=2 +tries=1 +noall +answer +comments "$host" AAAA 2>/dev/null) ||
                   ! dns_records_match "$a" "$aaaa"; then
                    echo "DNS pending: $host ($resolver). Check A/AAAA records and DNS propagation."
                    ready=false
                    break
                fi
            done
        done
        if [[ "$ready" == true ]]; then
            echo "DNS ready for all domains."
            return 0
        fi
        sleep 15 || return 1
    done
}
# End DNS helpers

STREAM_CONF="/etc/nginx/stream-enabled/stream.conf"
if [[ ! -f "$STREAM_CONF" ]]; then
    echo -e "\e[1;41m $STREAM_CONF not found! Are you sure x-ui-pro is installed? \e[0m"
    exit 1
fi

old_reality_domain=$(grep -E "\s+xray;" "$STREAM_CONF" | grep -v "default" | awk '{print $1}' | head -n 1 | tr -d '[:space:]')
old_domain=$(grep -E "\s+www;" "$STREAM_CONF" | awk '{print $1}' | head -n 1 | tr -d '[:space:]')

if [[ -z "$old_domain" || -z "$old_reality_domain" ]]; then
    echo -e "\e[1;41m Could not find old domains in Nginx config ($STREAM_CONF)! \e[0m"
    exit 1
fi

discover_public_ips || exit 1
wait_for_dns "$new_domain" "$new_reality_domain" || exit 1

export LC_ALL=C
export LANG=C

echo "Old Domain: $old_domain -> New Domain: $new_domain"
echo "Old Reality Domain: $old_reality_domain -> New Reality Domain: $new_reality_domain"

# Direct iptables rule to ensure port 80 and 443 are open
iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp >/dev/null 2>&1 || true
command -v ufw >/dev/null 2>&1 && ufw allow 443/tcp >/dev/null 2>&1 || true

# Prepare ACME challenge directory
mkdir -p /var/www/html/.well-known/acme-challenge
chmod -R 755 /var/www/html

# Configure 80.conf to serve ACME challenges locally without redirecting to HTTPS
cat > "/etc/nginx/sites-available/80.conf" << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
ln -sf "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/80.conf" 2>/dev/null
systemctl restart nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true

generate_self_signed() {
    local dom="$1"
    mkdir -p "/etc/letsencrypt/live/${dom}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "/etc/letsencrypt/live/${dom}/privkey.pem" \
        -out "/etc/letsencrypt/live/${dom}/fullchain.pem" \
        -subj "/CN=${dom}" >/dev/null 2>&1
}

echo "Requesting SSL certificate for $new_domain via webroot..."
certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos --register-unsafely-without-email -d "$new_domain"

if [[ ! -f "/etc/letsencrypt/live/${new_domain}/fullchain.pem" ]]; then
    echo "Webroot challenge failed, attempting standalone fallback..."
    systemctl stop nginx 2>/dev/null || true
    systemctl mask nginx 2>/dev/null || true
    pkill -9 -f nginx 2>/dev/null || true
    fuser -k 80/tcp 2>/dev/null || true
    for attempt in 1 2; do
        echo "Standalone attempt $attempt for $new_domain..."
        certbot certonly --standalone --http-01-address 0.0.0.0 --non-interactive --agree-tos --register-unsafely-without-email -d "$new_domain" && break
        sleep 4
    done
    systemctl unmask nginx 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true
fi

if [[ ! -f "/etc/letsencrypt/live/${new_domain}/fullchain.pem" ]]; then
    echo -e "\e[33mWarning: ACME verification timed out from remote network. Generating self-signed certificate fallback...\e[0m"
    generate_self_signed "$new_domain"
fi

echo "Requesting SSL certificate for $new_reality_domain via webroot..."
certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos --register-unsafely-without-email -d "$new_reality_domain"

if [[ ! -f "/etc/letsencrypt/live/${new_reality_domain}/fullchain.pem" ]]; then
    echo "Webroot challenge failed for reality domain, attempting standalone fallback..."
    systemctl stop nginx 2>/dev/null || true
    systemctl mask nginx 2>/dev/null || true
    pkill -9 -f nginx 2>/dev/null || true
    fuser -k 80/tcp 2>/dev/null || true
    for attempt in 1 2; do
        echo "Standalone attempt $attempt for $new_reality_domain..."
        certbot certonly --standalone --http-01-address 0.0.0.0 --non-interactive --agree-tos --register-unsafely-without-email -d "$new_reality_domain" && break
        sleep 4
    done
    systemctl unmask nginx 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true
fi

if [[ ! -f "/etc/letsencrypt/live/${new_reality_domain}/fullchain.pem" ]]; then
    echo -e "\e[33mWarning: ACME verification timed out for reality domain. Generating self-signed certificate fallback...\e[0m"
    generate_self_signed "$new_reality_domain"
fi

mkdir -p /root/cert/${new_domain} /root/cert/${new_reality_domain}
chmod 755 /root/cert/*
ln -sf /etc/letsencrypt/live/${new_domain}/fullchain.pem /root/cert/${new_domain}/fullchain.pem
ln -sf /etc/letsencrypt/live/${new_domain}/privkey.pem /root/cert/${new_domain}/privkey.pem
ln -sf /etc/letsencrypt/live/${new_reality_domain}/fullchain.pem /root/cert/${new_reality_domain}/fullchain.pem
ln -sf /etc/letsencrypt/live/${new_reality_domain}/privkey.pem /root/cert/${new_reality_domain}/privkey.pem

# Replace domains in nginx stream.conf
sed -i -E "s/^[[:space:]]*${old_reality_domain}[[:space:]]+xray;/${new_reality_domain}      xray;/g" "$STREAM_CONF"
sed -i -E "s/^[[:space:]]*${old_domain}[[:space:]]+www;/${new_domain}           www;/g" "$STREAM_CONF"

if [[ -f "/etc/nginx/sites-available/$old_domain" && "$old_domain" != "$new_domain" ]]; then
    mv -f "/etc/nginx/sites-available/$old_domain" "/etc/nginx/sites-available/$new_domain"
fi
if [[ -f "/etc/nginx/sites-available/$old_reality_domain" && "$old_reality_domain" != "$new_reality_domain" ]]; then
    mv -f "/etc/nginx/sites-available/$old_reality_domain" "/etc/nginx/sites-available/$new_reality_domain"
fi

if [[ -f "/etc/nginx/sites-available/$new_domain" ]]; then
    sed -i "s/$old_reality_domain/$new_reality_domain/g" "/etc/nginx/sites-available/$new_domain"
    sed -i "s/$old_domain/$new_domain/g" "/etc/nginx/sites-available/$new_domain"
fi

if [[ -f "/etc/nginx/sites-available/$new_reality_domain" ]]; then
    sed -i "s/$old_reality_domain/$new_reality_domain/g" "/etc/nginx/sites-available/$new_reality_domain"
    sed -i "s/$old_domain/$new_domain/g" "/etc/nginx/sites-available/$new_reality_domain"
fi

# Re-link nginx
rm -f "/etc/nginx/sites-enabled/$old_domain" "/etc/nginx/sites-enabled/$old_reality_domain" "/etc/nginx/sites-enabled/default"
ln -sf "/etc/nginx/sites-available/${new_domain}" "/etc/nginx/sites-enabled/${new_domain}"
ln -sf "/etc/nginx/sites-available/${new_reality_domain}" "/etc/nginx/sites-enabled/${new_reality_domain}"
ln -sf "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/80.conf"

# Update SQLite Database stream_settings JSON blobs & settings
XUIDB="/etc/x-ui/x-ui.db"
if [[ -f "$XUIDB" ]]; then
    sqlite3 $XUIDB "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '$old_reality_domain', '$new_reality_domain');"
    sqlite3 $XUIDB "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '$old_domain', '$new_domain');"
    sqlite3 $XUIDB "UPDATE inbounds SET settings = REPLACE(settings, '$old_reality_domain', '$new_reality_domain');" 2>/dev/null || true
    sqlite3 $XUIDB "UPDATE inbounds SET settings = REPLACE(settings, '$old_domain', '$new_domain');" 2>/dev/null || true
    sqlite3 $XUIDB "UPDATE settings SET value = REPLACE(value, '$old_reality_domain', '$new_reality_domain');" 2>/dev/null || true
    sqlite3 $XUIDB "UPDATE settings SET value = REPLACE(value, '$old_domain', '$new_domain');" 2>/dev/null || true
    sqlite3 $XUIDB "UPDATE settings SET value = '' WHERE key IN ('webCertFile', 'webKeyFile');"
    sqlite3 $XUIDB "UPDATE hosts SET address = REPLACE(address, '$old_domain', '$new_domain'), sni = REPLACE(sni, '$old_domain', '$new_domain'), host_header = REPLACE(host_header, '$old_domain', '$new_domain');" 2>/dev/null || true
fi

# Restart services
if nginx -t 2>&1 | grep -q 'successful'; then
    systemctl restart nginx
else
    echo -e "\e[1;41m Warning: Nginx test reported errors! Check /etc/nginx configs. \e[0m"
    nginx -t
    systemctl restart nginx
fi

x-ui restart

echo -e "\e[1;42m Domains updated successfully! \e[0m"
echo -e "\e[1;34m Check your panel at: https://${new_domain}/ \e[0m"
