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
    echo -en "Enter NEW available subdomain (sub.domain.tld): " && read new_domain
    new_domain=$(echo "$new_domain" | tr -d '[:space:]')
done

while [[ -z "$new_reality_domain" ]]; do
    echo -en "Enter NEW available subdomain for REALITY (sub.domain.tld): " && read new_reality_domain
    new_reality_domain=$(echo "$new_reality_domain" | tr -d '[:space:]')
done

IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')

resolve_to_ip () {
    local host="$1"
    local a
    a=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n "$a" ]] && [[ "$a" == "$IP4" ]]
}

echo "Checking DNS resolution for $new_domain..."
if ! resolve_to_ip "$new_domain"; then
    echo -e "\e[33mWarning: Domain $new_domain does not currently resolve to this server IP ($IP4).\e[0m"
    echo "If you recently updated DNS records, please ensure propagation or Let's Encrypt verification may fail."
fi

echo "Checking DNS resolution for $new_reality_domain..."
if ! resolve_to_ip "$new_reality_domain"; then
    echo -e "\e[33mWarning: Domain $new_reality_domain does not currently resolve to this server IP ($IP4).\e[0m"
fi

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

echo "Old Domain: $old_domain -> New Domain: $new_domain"
echo "Old Reality Domain: $old_reality_domain -> New Reality Domain: $new_reality_domain"

# Generate new SSL certs
systemctl stop nginx
fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null || true
killall -9 nginx 2>/dev/null || true
command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp >/dev/null 2>&1 || true
command -v ufw >/dev/null 2>&1 && ufw allow 443/tcp >/dev/null 2>&1 || true
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$new_domain"
if [[ ! -d "/etc/letsencrypt/live/${new_domain}/" ]]; then
 	systemctl start nginx >/dev/null 2>&1
	echo -e "\e[1;41m $new_domain SSL could not be generated! Check Domain/IP Or Enter new domain! \e[0m" && exit 1
fi

certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$new_reality_domain"
if [[ ! -d "/etc/letsencrypt/live/${new_reality_domain}/" ]]; then
 	systemctl start nginx >/dev/null 2>&1
	echo -e "\e[1;41m $new_reality_domain SSL could not be generated! Check Domain/IP Or Enter new domain! \e[0m" && exit 1
fi

mkdir -p /root/cert/${new_domain}
chmod 755 /root/cert/*
ln -sf /etc/letsencrypt/live/${new_domain}/fullchain.pem /root/cert/${new_domain}/fullchain.pem
ln -sf /etc/letsencrypt/live/${new_domain}/privkey.pem /root/cert/${new_domain}/privkey.pem

# Replace domains in nginx (reality first, then main domain to prevent substring collisions)
sed -i "s/$old_reality_domain/$new_reality_domain/g" "$STREAM_CONF"
sed -i "s/$old_domain/$new_domain/g" "$STREAM_CONF"

if [[ -f "/etc/nginx/sites-available/$old_domain" ]]; then
    mv "/etc/nginx/sites-available/$old_domain" "/etc/nginx/sites-available/$new_domain"
fi
if [[ -f "/etc/nginx/sites-available/$old_reality_domain" ]]; then
    mv "/etc/nginx/sites-available/$old_reality_domain" "/etc/nginx/sites-available/$new_reality_domain"
fi

if [[ -f "/etc/nginx/sites-available/80.conf" ]]; then
    sed -i "s/$old_reality_domain/$new_reality_domain/g" /etc/nginx/sites-available/80.conf
    sed -i "s/$old_domain/$new_domain/g" /etc/nginx/sites-available/80.conf
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
rm -f "/etc/nginx/sites-enabled/$old_domain" "/etc/nginx/sites-enabled/$old_reality_domain"
ln -sf "/etc/nginx/sites-available/${new_domain}" "/etc/nginx/sites-enabled/"
ln -sf "/etc/nginx/sites-available/${new_reality_domain}" "/etc/nginx/sites-enabled/"

# Update SQLite Database stream_settings JSON blobs & settings
XUIDB="/etc/x-ui/x-ui.db"
if [[ -f "$XUIDB" ]]; then
    sqlite3 $XUIDB "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '$old_reality_domain', '$new_reality_domain');"
    sqlite3 $XUIDB "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '$old_domain', '$new_domain');"
    sqlite3 $XUIDB "UPDATE settings SET value = '/root/cert/${new_domain}/fullchain.pem' WHERE key = 'webCertFile';"
    sqlite3 $XUIDB "UPDATE settings SET value = '/root/cert/${new_domain}/privkey.pem' WHERE key = 'webKeyFile';"
    sqlite3 $XUIDB "UPDATE settings SET value = '$new_domain' WHERE key IN ('webDomain', 'subDomain') AND value = '$old_domain';"
    sqlite3 $XUIDB "UPDATE hosts SET address = REPLACE(address, '$old_domain', '$new_domain'), sni = REPLACE(sni, '$old_domain', '$new_domain'), host_header = REPLACE(host_header, '$old_domain', '$new_domain');" 2>/dev/null
fi

if [[ -f "/usr/local/x-ui/x-ui" ]]; then
    /usr/local/x-ui/x-ui cert -webCert "/root/cert/${new_domain}/fullchain.pem" -webCertKey "/root/cert/${new_domain}/privkey.pem" >/dev/null 2>&1
fi

# Restart services
if nginx -t 2>&1 | grep -q 'successful'; then
    systemctl start nginx
else
    echo -e "\e[1;41m Warning: Nginx test reported errors! Check /etc/nginx configs. \e[0m"
    systemctl start nginx
fi

x-ui restart

echo -e "\e[1;42m Domains updated successfully! \e[0m"
echo -e "\e[1;34m Check your panel at: https://${new_domain}/ \e[0m"
