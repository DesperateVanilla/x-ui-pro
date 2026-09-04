#!/bin/bash
# switch_to_ip.sh - Abandon domains and switch 3x-ui-pro to direct IP access

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[1;41m Please run as root (sudo) \e[0m"
  exit 1
fi

echo -e "\e[32m=== X-UI-PRO Switch to IP Mode ===\e[0m"

custom_ip=""
reality_sni=""
reality_target=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -ip) custom_ip="$2"; shift 2;;
    -reality_sni) reality_sni="$2"; shift 2;;
    -reality_target) reality_target="$2"; shift 2;;
    *) shift 1;;
  esac
done

# Detect Public IPv4
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
if [[ -n "$custom_ip" && "$custom_ip" =~ $IP4_REGEX ]]; then
    IP4="$custom_ip"
else
    IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
    [[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')
    [[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ifconfig.me | tr -d '[:space:]')
fi

if [[ ! $IP4 =~ $IP4_REGEX ]]; then
    echo -e "\e[1;41m Could not detect public IPv4. Please pass it via -ip <your_ip> \e[0m"
    exit 1
fi

echo -e "\e[34mDetected Server IPv4: $IP4\e[0m"

# Camouflage SNI for VLESS Reality (requires real external domain, unblocked by TSPU)
if [[ -z "$reality_sni" ]]; then
    if [ -t 0 ]; then
        read -p "Enter Reality camouflage SNI [default: gateway.icloud.com]: " user_sni
        reality_sni=$(echo "$user_sni" | tr -d '[:space:]')
    fi
fi
[[ -z "$reality_sni" ]] && reality_sni="gateway.icloud.com"

if [[ -z "$reality_target" ]]; then
    reality_target="${reality_sni}:443"
fi

echo -e "\e[34mReality Camouflage SNI: $reality_sni (target: $reality_target)\e[0m"

STREAM_CONF="/etc/nginx/stream-enabled/stream.conf"
XUIDB="/etc/x-ui/x-ui.db"

# Identify old domains from configs / database
old_reality_domain=""
old_domain=""

if [[ -f "$STREAM_CONF" ]]; then
    old_reality_domain=$(grep -E "\s+xray;" "$STREAM_CONF" | grep -v "default" | awk '{print $1}' | head -n 1 | tr -d '[:space:]')
    old_domain=$(grep -E "\s+www;" "$STREAM_CONF" | grep -v '""' | awk '{print $1}' | head -n 1 | tr -d '[:space:]')
fi

if [[ -z "$old_domain" && -f "$XUIDB" ]]; then
    old_domain=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subURI' LIMIT 1;" 2>/dev/null | sed -E 's#https?://([^/:]+).*#\1#')
fi

if [[ -z "$old_reality_domain" && -f "$XUIDB" ]]; then
    old_reality_domain=$(sqlite3 "$XUIDB" "SELECT stream_settings FROM inbounds WHERE protocol='vless' AND stream_settings LIKE '%reality%' LIMIT 1;" 2>/dev/null | grep -oP '"serverNames":\s*\[\s*"\K[^"]+')
fi

echo "Old Domain: ${old_domain:-<none>} -> New Host: $IP4"
echo "Old Reality Domain: ${old_reality_domain:-<none>} -> Reality SNI: $reality_sni"

# Ensure firewall allows essential ports
iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp >/dev/null 2>&1 || true
command -v ufw >/dev/null 2>&1 && ufw allow 443/tcp >/dev/null 2>&1 || true

# Extract panel and subscription details
panel_path=""
panel_port=""
sub_path=""
sub_port=""
web_path=""
sub2singbox_path=""

if [[ -f "$XUIDB" ]]; then
    panel_port=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null)
    panel_path=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;" 2>/dev/null | tr -d '/')
    sub_port=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null)
    sub_path=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subPath' LIMIT 1;" 2>/dev/null | tr -d '/')
    web_path=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subJsonPath' LIMIT 1;" 2>/dev/null | tr -d '/')
fi

# Fallbacks from existing Nginx configs if db is empty or missing
if [[ -z "$panel_path" ]]; then
    panel_path=$(grep -m1 -oP 'location /\K[a-zA-Z0-9_-]+(?=/\s*\{)' /etc/nginx/sites-available/* 2>/dev/null | grep -v 'well-known')
fi
if [[ -z "$panel_port" ]]; then
    panel_port=$(grep -m1 -oP 'proxy_pass http://127.0.0.1:\K\d+' /etc/nginx/sites-available/* 2>/dev/null)
fi
if [[ -z "$sub_path" ]]; then
    sub_path=$(grep -m1 -oP 'location /\K[a-zA-Z0-9_-]+' /etc/nginx/snippets/includes.conf 2>/dev/null | head -n 1)
fi
if [[ -z "$sub_port" ]]; then
    sub_port=$(grep -m1 -oP 'proxy_pass http://127.0.0.1:\K\d+' /etc/nginx/snippets/includes.conf 2>/dev/null | head -n 1)
fi

# Generate self-signed IP SSL certificate with IP SAN
echo "Generating self-signed SSL certificate for $IP4..."
mkdir -p "/etc/letsencrypt/live/${IP4}"
mkdir -p "/root/cert/${IP4}"

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "/etc/letsencrypt/live/${IP4}/privkey.pem" \
    -out "/etc/letsencrypt/live/${IP4}/fullchain.pem" \
    -subj "/CN=${IP4}" \
    -addext "subjectAltName=IP:${IP4}" >/dev/null 2>&1 || \
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "/etc/letsencrypt/live/${IP4}/privkey.pem" \
    -out "/etc/letsencrypt/live/${IP4}/fullchain.pem" \
    -subj "/CN=${IP4}" >/dev/null 2>&1

chmod 755 /root/cert/* 2>/dev/null || true
ln -sf "/etc/letsencrypt/live/${IP4}/fullchain.pem" "/root/cert/${IP4}/fullchain.pem"
ln -sf "/etc/letsencrypt/live/${IP4}/privkey.pem" "/root/cert/${IP4}/privkey.pem"

# Configure Nginx Stream multiplexer (port 443)
# Direct IP connections have empty SNI -> route to www (port 7443)
# Reality connections have SNI matching reality_sni (or default) -> route to xray (port 8443)
echo "Configuring Nginx Stream module for IP and Reality SNI routing..."
mkdir -p /etc/nginx/stream-enabled
cat > "$STREAM_CONF" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_sni}         xray;
    default                www;
}

upstream xray {
    server 127.0.0.1:8443;
}

upstream www {
    server 127.0.0.1:7443;
}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen          443;
    listen         [::]:443;
    proxy_pass      \$sni_name;
    ssl_preread     on;
}
EOF

# Configure Nginx HTTPS Web Server on port 7443 for IP
echo "Configuring Nginx port 7443 HTTPS for IP..."
cat > "/etc/nginx/sites-available/${IP4}" << EOF
server {
    server_tokens off;
    server_name _ ${IP4};
    listen 7443 ssl http2 proxy_protocol;
    listen [::]:7443 ssl http2 proxy_protocol;
    index index.html index.htm index.php index.nginx-debian.html;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate /root/cert/${IP4}/fullchain.pem;
    ssl_certificate_key /root/cert/${IP4}/privkey.pem;

    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

EOF

if [[ -n "$panel_path" && -n "$panel_port" ]]; then
cat >> "/etc/nginx/sites-available/${IP4}" << EOF
    # X-UI Admin Panel
    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Upgrade websocket;
        proxy_set_header Connection Upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_pass http://127.0.0.1:${panel_port};
        break;
    }

    location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Upgrade websocket;
        proxy_set_header Connection Upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        proxy_pass http://127.0.0.1:${panel_port};
        break;
    }
EOF
fi

cat >> "/etc/nginx/sites-available/${IP4}" << EOF
    include /etc/nginx/snippets/includes.conf;
}
EOF

# Local fallback on port 9443 for fake site
cat > "/etc/nginx/sites-available/9443.conf" << EOF
server {
    server_tokens off;
    server_name _;
    listen 9443 ssl http2 default_server;
    listen [::]:9443 ssl http2 default_server;
    index index.html index.htm;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /root/cert/${IP4}/fullchain.pem;
    ssl_certificate_key /root/cert/${IP4}/privkey.pem;
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    location / { try_files \$uri \$uri/ =404; }
}
EOF

# Configure Port 80 (allow HTTP subscriptions directly without SSL warnings)
echo "Configuring Port 80 HTTP access..."
cat > "/etc/nginx/sites-available/80.conf" << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type text/plain;
    }
EOF

if [[ -n "$sub_path" && -n "$sub_port" ]]; then
cat >> "/etc/nginx/sites-available/80.conf" << EOF
    # Direct HTTP subscription access (prevents SSL certificate issues on IP)
    location /${sub_path} {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
    }
    location /${sub_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
    }
EOF
fi

if [[ -n "$web_path" ]]; then
cat >> "/etc/nginx/sites-available/80.conf" << EOF
    # Web Sub Page over HTTP
    location ~ ^/${web_path} {
        root /var/www/subpage;
        index index.html;
        try_files \$uri \$uri/ /index.html =404;
    }
EOF
fi

cat >> "/etc/nginx/sites-available/80.conf" << EOF
    # Redirect admin panel and root to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# Update Nginx symlinks in sites-enabled
rm -f /etc/nginx/sites-enabled/*
ln -sf "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/80.conf"
ln -sf "/etc/nginx/sites-available/${IP4}" "/etc/nginx/sites-enabled/${IP4}"
ln -sf "/etc/nginx/sites-available/9443.conf" "/etc/nginx/sites-enabled/9443.conf"

# Update subpage files
if [[ -f "/var/www/subpage/index.html" ]]; then
    [[ -n "$old_domain" ]] && sed -i "s/$old_domain/$IP4/g" "/var/www/subpage/index.html" 2>/dev/null || true
    [[ -n "$old_reality_domain" ]] && sed -i "s/$old_reality_domain/$reality_sni/g" "/var/www/subpage/index.html" 2>/dev/null || true
fi
if [[ -f "/var/www/subpage/clash.yaml" ]]; then
    [[ -n "$old_domain" ]] && sed -i "s/$old_domain/$IP4/g" "/var/www/subpage/clash.yaml" 2>/dev/null || true
    [[ -n "$old_reality_domain" ]] && sed -i "s/$old_reality_domain/$reality_sni/g" "/var/www/subpage/clash.yaml" 2>/dev/null || true
fi

# Update 3X-UI SQLite Database
if [[ -f "$XUIDB" ]]; then
    echo "Updating X-UI SQLite database..."
    cp "$XUIDB" "${XUIDB}.bak.$(date +%s)"

    # Replace old domain with IP and old reality domain with reality SNI
    if [[ -n "$old_reality_domain" ]]; then
        sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '$old_reality_domain', '$reality_sni');" 2>/dev/null || true
        sqlite3 "$XUIDB" "UPDATE inbounds SET settings = REPLACE(settings, '$old_reality_domain', '$reality_sni');" 2>/dev/null || true
        sqlite3 "$XUIDB" "UPDATE settings SET value = REPLACE(value, '$old_reality_domain', '$reality_sni');" 2>/dev/null || true
    fi

    if [[ -n "$old_domain" ]]; then
        sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '$old_domain', '$IP4');" 2>/dev/null || true
        sqlite3 "$XUIDB" "UPDATE inbounds SET settings = REPLACE(settings, '$old_domain', '$IP4');" 2>/dev/null || true
        sqlite3 "$XUIDB" "UPDATE settings SET value = REPLACE(value, '$old_domain', '$IP4');" 2>/dev/null || true
        sqlite3 "$XUIDB" "UPDATE hosts SET address = REPLACE(address, '$old_domain', '$IP4'), sni = REPLACE(sni, '$old_domain', '$IP4'), host_header = REPLACE(host_header, '$old_domain', '$IP4');" 2>/dev/null || true
    fi

    # Update Reality target to real external server for genuine probe responses
    sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = REPLACE(stream_settings, '127.0.0.1:9443', '${reality_target}') WHERE protocol='vless' AND stream_settings LIKE '%reality%';" 2>/dev/null || true

    # 3X-UI backend panel runs in plain HTTP on 127.0.0.1 (Nginx handles SSL on frontend 443/7443)
    sqlite3 "$XUIDB" "UPDATE settings SET value = '' WHERE key IN ('webCertFile', 'webKeyFile', 'webDomain', 'subDomain', 'webListen');" 2>/dev/null || true
    sqlite3 "$XUIDB" "UPDATE settings SET value = 'https://${IP4}/${sub_path}/' WHERE key = 'subURI';" 2>/dev/null || true
    sqlite3 "$XUIDB" "UPDATE settings SET value = 'https://${IP4}/${web_path}?name=' WHERE key = 'subJsonURI';" 2>/dev/null || true
fi

# Reset 3X-UI internal certificate references so it does not reject local Nginx reverse proxy
if [[ -f "/usr/local/x-ui/x-ui" ]]; then
    /usr/local/x-ui/x-ui cert -webCert "" -webCertKey "" >/dev/null 2>&1 || true
    /usr/local/x-ui/x-ui setting -webListen "" >/dev/null 2>&1 || true
fi

# Remove obsolete certbot renew cron jobs to avoid errors
crontab -l 2>/dev/null | grep -v "certbot renew" | crontab - 2>/dev/null || true

# Restart services
echo "Restarting Nginx and X-UI..."
pkill -9 -f nginx 2>/dev/null || true
fuser -k 80/tcp 443/tcp 7443/tcp 9443/tcp 2>/dev/null || true

if nginx -t 2>&1 | grep -q 'successful'; then
    systemctl restart nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true
else
    echo -e "\e[1;41m Warning: Nginx syntax test failed! \e[0m"
    nginx -t
    systemctl restart nginx 2>/dev/null || true
fi

x-ui restart 2>/dev/null || systemctl restart x-ui 2>/dev/null || true

echo ""
echo -e "\e[1;42m Successfully switched to IP mode! \e[0m"
echo -e "\e[1;34m Server IPv4:             $IP4 \e[0m"
echo -e "\e[1;34m Reality Camouflage SNI:  $reality_sni \e[0m"
echo -e "\e[1;34m Panel URL (HTTPS):       https://${IP4}/${panel_path}/ \e[0m"
echo -e "   \e[33m(Browser will warn about self-signed SSL; click 'Advanced' -> 'Proceed to $IP4')\e[0m"
echo -e "\e[1;34m Subscription (HTTPS):    https://${IP4}/${sub_path}/ \e[0m"
echo -e "\e[1;34m Subscription (HTTP):     http://${IP4}/${sub_path}/ \e[0m"
if [[ -n "$web_path" ]]; then
echo -e "\e[1;34m Web Sub Page:            http://${IP4}/${web_path}?name=first \e[0m"
fi
echo -e "\e[32m===================================\e[0m"
