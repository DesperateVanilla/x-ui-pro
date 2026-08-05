#!/bin/bash
# change_domain.sh - Reissue certs and update domains in 3x-ui-pro

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

echo -e "\e[32m=== X-UI-PRO Domain Changer ===\e[0m"

echo -en "Enter NEW available subdomain (sub.domain.tld): " && read new_domain
new_domain=$(echo "$new_domain" | tr -d '[:space:]' )
echo -en "Enter NEW available subdomain for REALITY (sub.domain.tld): " && read new_reality_domain
new_reality_domain=$(echo "$new_reality_domain" | tr -d '[:space:]' )

if [[ -z "$new_domain" || -z "$new_reality_domain" ]]; then
    echo "Domains cannot be empty!"
    exit 1
fi

IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com);

resolve_to_ip () {
    local host="$1"
    local a
    a=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n "$a" ]] && [[ "$a" == "$IP4" ]]
}

echo "Checking DNS resolution for $new_domain..."
if ! resolve_to_ip "$new_domain"; then
    echo "Error: Domain $new_domain does not resolve to this server IP ($IP4)."
    exit 1
fi

echo "Checking DNS resolution for $new_reality_domain..."
if ! resolve_to_ip "$new_reality_domain"; then
    echo "Error: Domain $new_reality_domain does not resolve to this server IP ($IP4)."
    exit 1
fi

old_reality_domain=$(grep "xray;" /etc/nginx/stream-enabled/stream.conf | grep -v "default" | awk '{print $1}')
old_domain=$(grep "www;" /etc/nginx/stream-enabled/stream.conf | awk '{print $1}')

if [[ -z "$old_domain" || -z "$old_reality_domain" ]]; then
    echo "Could not find old domains in Nginx config! Are you sure x-ui-pro is installed?"
    exit 1
fi

echo "Old Domain: $old_domain -> New Domain: $new_domain"
echo "Old Reality Domain: $old_reality_domain -> New Reality Domain: $new_reality_domain"

# Generate new SSL certs
systemctl stop nginx
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$new_domain"
if [[ ! -d "/etc/letsencrypt/live/${new_domain}/" ]]; then
 	systemctl start nginx >/dev/null 2>&1
	echo "$new_domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi

certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$new_reality_domain"
if [[ ! -d "/etc/letsencrypt/live/${new_reality_domain}/" ]]; then
 	systemctl start nginx >/dev/null 2>&1
	echo "$new_reality_domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi

mkdir -p /root/cert/${new_domain}
chmod 755 /root/cert/*
ln -sf /etc/letsencrypt/live/${new_domain}/fullchain.pem /root/cert/${new_domain}/fullchain.pem
ln -sf /etc/letsencrypt/live/${new_domain}/privkey.pem /root/cert/${new_domain}/privkey.pem

# Replace domains in nginx
sed -i "s/$old_domain/$new_domain/g" /etc/nginx/stream-enabled/stream.conf
sed -i "s/$old_reality_domain/$new_reality_domain/g" /etc/nginx/stream-enabled/stream.conf

mv /etc/nginx/sites-available/$old_domain /etc/nginx/sites-available/$new_domain 2>/dev/null
mv /etc/nginx/sites-available/$old_reality_domain /etc/nginx/sites-available/$new_reality_domain 2>/dev/null

sed -i "s/$old_domain/$new_domain/g" /etc/nginx/sites-available/80.conf
sed -i "s/$old_reality_domain/$new_reality_domain/g" /etc/nginx/sites-available/80.conf
sed -i "s/$old_domain/$new_domain/g" /etc/nginx/sites-available/$new_domain
sed -i "s/$old_reality_domain/$new_reality_domain/g" /etc/nginx/sites-available/$new_reality_domain

# Re-link nginx
rm -f /etc/nginx/sites-enabled/$old_domain /etc/nginx/sites-enabled/$old_reality_domain
ln -sf "/etc/nginx/sites-available/${new_domain}" "/etc/nginx/sites-enabled/"
ln -sf "/etc/nginx/sites-available/${new_reality_domain}" "/etc/nginx/sites-enabled/"

# Update SQLite Database stream_settings JSON blobs
XUIDB="/etc/x-ui/x-ui.db"
sqlite3 $XUIDB "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '$old_domain', '$new_domain');"
sqlite3 $XUIDB "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '$old_reality_domain', '$new_reality_domain');"

# Restart services
systemctl start nginx
x-ui restart

echo -e "\e[32mDomains updated successfully!\e[0m"
