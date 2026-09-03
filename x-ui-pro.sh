#!/bin/bash
#################### x-ui-pro v2.4.3 @ github.com/GFW4Fun ##############################################
[[ $EUID -ne 0 ]] && msg_err "Error: Please run as root (sudo)" && exit 1
##############################INFO######################################################################
msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}
echo;msg_inf '           ___    _   _   _  '	;
msg_inf		 ' \/ __ | |  | __ |_) |_) / \ '	;
msg_inf		 ' /\    |_| _|_   |   | \ \_/ '	; echo
##################################Variables#############################################################
XUIDB="/etc/x-ui/x-ui.db";domain="";UNINSTALL="x";INSTALL="n";PNLNUM=1;CFALLOW="n";CLASH=0;CUSTOMWEBSUB=0;WARP="n"
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")
systemctl stop x-ui 2>/dev/null || true
rm -rf /etc/systemd/system/x-ui.service
rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
rm -rf /etc/nginx/sites-enabled/*
rm -rf /etc/nginx/sites-available/*
rm -rf /etc/nginx/stream-enabled/*


##################################generate ports and paths#############################################################
get_port() {
	echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}
check_free() {
	local port=$1
	nc -z 127.0.0.1 $port &>/dev/null
	return $?
}

make_port() {
	while true; do
		PORT=$(get_port)
		if ! check_free $PORT; then 
			echo $PORT
			break
		fi
	done
}

sub_port=$(make_port)
panel_port=$(make_port)
web_path=$(gen_random_string 10)
sub2singbox_path=$(gen_random_string 10)
sub_path=$(gen_random_string 10)
json_path=$(gen_random_string 10)
panel_path=$(gen_random_string 10)
ws_port=$(make_port)
trojan_port=$(make_port)
hy2_port=$(make_port)
ws_path=$(gen_random_string 10)
trojan_path=$(gen_random_string 10)
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 10)
AUTODOMAIN="n"

##################################Random Port and Path #################################################
#RNDSTR=$(tr -dc A-Za-z0-9 </dev/urandom | head -c "$(shuf -i 6-12 -n 1)")
#while true; do 
#    PORT=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
#    status="$(nc -z 127.0.0.1 $PORT < /dev/null &>/dev/null; echo $?)"
#    if [ "${status}" != "0" ]; then
#        break
#    fi
#done

################################Get arguments###########################################################
while [ "$#" -gt 0 ]; do
  case "$1" in
    -auto_domain) AUTODOMAIN="$2"; shift 2;;
    -install) INSTALL="$2"; shift 2;;
    -panel) PNLNUM="$2"; shift 2;;
    -subdomain) domain="$2"; shift 2;;
    -reality_domain) reality_domain="$2"; shift 2;;
    -ONLY_CF_IP_ALLOW) CFALLOW="$2"; shift 2;;
    -websub) CUSTOMWEBSUB="$2"; shift 2;;
    -clash) CLASH="$2"; shift 2;;
    -uninstall) UNINSTALL="$2"; shift 2;;
    -warp) WARP="$2"; shift 2;;
    *) shift 1;;
  esac
done


##############################Uninstall#################################################################
UNINSTALL_XUI(){
	printf 'y\n' | x-ui uninstall
	rm -rf "/etc/x-ui/" "/usr/local/x-ui/" "/usr/bin/x-ui/"
	$Pak -y remove nginx nginx-common nginx-core nginx-full python3-certbot-nginx
	$Pak -y purge nginx nginx-common nginx-core nginx-full python3-certbot-nginx
	$Pak -y autoremove
	$Pak -y autoclean
	rm -rf "/var/www/html/" "/etc/nginx/" "/usr/share/nginx/" 
}
if [[ ${UNINSTALL} == *"y"* ]]; then
	UNINSTALL_XUI	
	clear && msg_ok "Completely Uninstalled!" && exit 1
fi


# --- get public IPv4 early (for auto-domain mode)
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')


if [[ ${AUTODOMAIN} == *"y"* ]]; then
    # panel domain: x.x.x.x.cdn-one.org
    domain="${IP4}.cdn-one.org"

    # reality domain: x-x-x-x.cdn-one.org
    reality_domain="${IP4//./-}.cdn-one.org"
fi


##############################Domain Validations########################################################
while true; do	
	if [[ -n "$domain" ]]; then
		break
	fi
	echo -en "Enter available subdomain (sub.domain.tld): " && read domain 
done

domain=$(echo "$domain" 2>&1 | tr -d '[:space:]' )
SubDomain=$(echo "$domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
MainDomain=$(echo "$domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] ; then
	MainDomain=${domain}
fi

while true; do	
	if [[ -n "$reality_domain" ]]; then
		break
	fi
	echo -en "Enter available subdomain for REALITY (sub.domain.tld): " && read reality_domain 
done

reality_domain=$(echo "$reality_domain" 2>&1 | tr -d '[:space:]' )
RealitySubDomain=$(echo "$reality_domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
RealityMainDomain=$(echo "$reality_domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${RealitySubDomain}.${RealityMainDomain}" != "${reality_domain}" ]] ; then
	RealityMainDomain=${reality_domain}
fi


while true; do	
	if [[ "$WARP" == "y" || "$WARP" == "n" ]]; then
		break
	fi
	echo -en "Do you want to configure AI & Global Bypass routing via WARP+? (y/n): " && read WARP 
done


###############################Install Packages#########################################################
command -v ufw >/dev/null 2>&1 && ufw disable
if [[ ${INSTALL} == *"y"* ]]; then

         version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)

         # Проверяем, является ли версия 20 или 22
        if [[ "$version" == "20" || "$version" == "22" ]]; then
              echo "Версия системы: Ubuntu $version"
        fi

	$Pak -y update

	$Pak -y install curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw

	systemctl daemon-reload && systemctl enable --now nginx
fi
systemctl stop nginx 
fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null
##################################GET SERVER IPv4-6#####################################################
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
IP6=$(ip route get 2620:fe::fe 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com);
[[ $IP6 =~ $IP6_REGEX ]] || IP6=$(curl -s ipv6.icanhazip.com);
##############################Install SSL###############################################################

resolve_to_ip () {
    local host="$1"
    # get first A-record
    local a
    a=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n "$a" ]] && [[ "$a" == "$IP4" ]]
}

if [[ ${AUTODOMAIN} == *"y"* ]]; then
    if ! resolve_to_ip "$domain"; then
        msg_err "Auto-domain $domain does not resolve to this server IP ($IP4). Fix DNS/service and retry."
        exit 1
    fi
    if ! resolve_to_ip "$reality_domain"; then
        msg_err "Auto-domain $reality_domain does not resolve to this server IP ($IP4). Fix DNS/service and retry."
        exit 1
    fi
fi


certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain"
if [[ ! -d "/etc/letsencrypt/live/${domain}/" ]]; then
 	systemctl start nginx >/dev/null 2>&1
	msg_err "$domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi

certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$reality_domain"
if [[ ! -d "/etc/letsencrypt/live/${reality_domain}/" ]]; then
 	systemctl start nginx >/dev/null 2>&1
	msg_err "$reality_domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi
################################# Access to configs only with cloudflare#################################

###################################Get Installed XUI Port/Path##########################################
if [[ -f $XUIDB ]]; then
	XUIPORT=$(sqlite3 -list $XUIDB 'SELECT "value" FROM settings WHERE "key"="webPort" LIMIT 1;' 2>&1)
	XUIPATH=$(sqlite3 -list $XUIDB 'SELECT "value" FROM settings WHERE "key"="webBasePath" LIMIT 1;' 2>&1)
if [[ $XUIPORT -gt 0 && $XUIPORT != "54321" && $XUIPORT != "2053" ]] && [[ ${#XUIPORT} -gt 4 ]]; then
	RNDSTR=$(echo "$XUIPATH" 2>&1 | tr -d '/')
	PORT=$XUIPORT
	sqlite3 $XUIDB <<EOF
	DELETE FROM "settings" WHERE ( "key"="webCertFile" ) OR ( "key"="webKeyFile" ); 
	INSERT INTO "settings" ("key", "value") VALUES ("webCertFile",  "");
	INSERT INTO "settings" ("key", "value") VALUES ("webKeyFile", "");
EOF
fi
fi
#################################Nginx Config###########################################################
mkdir -p /root/cert/${domain}
chmod 755 /root/cert/*

ln -s /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
ln -s /etc/letsencrypt/live/${domain}/privkey.pem /root/cert/${domain}/privkey.pem

mkdir -p /etc/nginx/stream-enabled
cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}      xray;
    ${domain}           www;
    default              xray;
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

grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* ||echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
grep -qR "ngx_stream_module" /etc/nginx/ || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so;\n/' /etc/nginx/nginx.conf
grep -qR "ngx_stream_geoip2_module" /etc/nginx/ || sed -i '2s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_geoip2_module.so;\n/' /etc/nginx/nginx.conf
grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* ||echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf
cat > "/etc/nginx/sites-available/80.conf" << EOF
server {
    listen 80;
    server_name ${domain} ${reality_domain};
    return 301 https://\$host\$request_uri;
}
EOF


cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
	server_tokens off;
	server_name ${domain};
	listen 7443 ssl http2 proxy_protocol;
	listen [::]:7443 ssl http2 proxy_protocol;
	index index.html index.htm index.php index.nginx-debian.html;
	root /var/www/html/;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
	ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
	if (\$host !~* ^(.+\.)?$domain\$ ){return 444;}
	if (\$scheme ~* https) {set \$safe 1;}
	if (\$ssl_server_name !~* ^(.+\.)?$domain\$ ) {set \$safe "\${safe}0"; }
	if (\$safe = 10){return 444;}
	if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
	error_page 400 401 402 403 500 501 502 503 504 =404 /404;
	proxy_intercept_errors on;
	#X-UI Admin Panel
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
	include /etc/nginx/snippets/includes.conf;

}
EOF

cat > "/etc/nginx/snippets/includes.conf" << EOF
  	#sub2sing-box
	location /${sub2singbox_path}/ {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass http://127.0.0.1:8080/;
		}
    # Path to open clash.yaml and generate YAML
    location ~ ^/${web_path}/clashmeta/(.+)$ {
        default_type text/plain;
        ssi on;
        ssi_types text/plain;
        set \$subid \$1;
        root /var/www/subpage;
        try_files /clash.yaml =404;
    }
    # web
    location ~ ^/${web_path} {
        root /var/www/subpage;
        index index.html;
        try_files \$uri \$uri/ /index.html =404;
    }
 	#Subscription Path (simple/encode)
        location /${sub_path} {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass http://127.0.0.1:${sub_port};
                break;
        }
	location /${sub_path}/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass http://127.0.0.1:${sub_port};
                break;
        }
	location /assets/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass http://127.0.0.1:${sub_port};
                break;
        }
	location /assets {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass http://127.0.0.1:${sub_port};
                break;
        }
	#Subscription Path (json/fragment)
        location /${json_path} {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass http://127.0.0.1:${sub_port};
                break;
        }
	location /${json_path}/ {
                if (\$hack = 1) {return 404;}
                proxy_redirect off;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_pass http://127.0.0.1:${sub_port};
                break;
        }

 	#Xray Config Path
	location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
		if (\$hack = 1) {return 404;}
		client_max_body_size 0;
		client_body_timeout 1d;
		grpc_read_timeout 1d;
		grpc_socket_keepalive on;
		proxy_read_timeout 1d;
		proxy_http_version 1.1;
		proxy_buffering off;
		proxy_request_buffering off;
		proxy_socket_keepalive on;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		#proxy_set_header CF-IPCountry \$http_cf_ipcountry;
		#proxy_set_header CF-IP \$realip_remote_addr;
		if (\$content_type ~* "GRPC") {
			grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
			break;
		}
		if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
			proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
			break;
	        }
		if (\$request_method ~* ^(PUT|POST|GET)\$) {
			proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
			break;
		}
	}
	location / { try_files \$uri \$uri/ =404; }
EOF

cat > "/etc/nginx/sites-available/${reality_domain}" << EOF
server {
	server_tokens off;
	server_name ${reality_domain};
	listen 9443 ssl http2;
	listen [::]:9443 ssl http2;
	index index.html index.htm index.php index.nginx-debian.html;
	root /var/www/html/;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
	ssl_certificate /etc/letsencrypt/live/$reality_domain/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/$reality_domain/privkey.pem;
	if (\$host !~* ^(.+\.)?${reality_domain}\$ ){return 444;}
	if (\$scheme ~* https) {set \$safe 1;}
	if (\$ssl_server_name !~* ^(.+\.)?${reality_domain}\$ ) {set \$safe "\${safe}0"; }
	if (\$safe = 10){return 444;}
	if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
	error_page 400 401 402 403 500 501 502 503 504 =404 /404;
	proxy_intercept_errors on;
	#X-UI Admin Panel
	location /${panel_path}/ {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass http://127.0.0.1:${panel_port};
		break;
	}
        location /$panel_path {
		proxy_redirect off;
		proxy_set_header Host \$host;
		proxy_set_header X-Real-IP \$remote_addr;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_pass http://127.0.0.1:${panel_port};
		break;
	}
include /etc/nginx/snippets/includes.conf;
}
EOF
##################################Check Nginx status####################################################
if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
	unlink "/etc/nginx/sites-enabled/default" >/dev/null 2>&1
	rm -f "/etc/nginx/sites-enabled/default" "/etc/nginx/sites-available/default"
	ln -s "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
        ln -s "/etc/nginx/sites-available/${reality_domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
	ln -s "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/" 2>/dev/null
else
	msg_err "${domain} nginx config not exist!" && exit 1
fi

if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
    nginx -t
    msg_err "nginx config is not ok!" && exit 1
else
	systemctl start nginx 
fi


##############################generate uri's###########################################################
sub_uri=https://${domain}/${sub_path}/
json_uri=https://${domain}/${web_path}?name=
##############################generate keys###########################################################
shor=($(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8))

SETUP_WARP(){
    msg_inf "Installing Cloudflare WARP+..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list
    $Pak update && $Pak -y install cloudflare-warp

    warp-cli --accept-tos registration new
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port 40000

    msg_inf "Fetching Free WARP+ premium key..."
    WARP_KEY=$(curl -s "https://t.me/s/warpplus" | grep -oE "[a-zA-Z0-9]{8}-[a-zA-Z0-9]{8}-[a-zA-Z0-9]{8}" | tail -n 1)
    if [[ -n "$WARP_KEY" ]]; then
        warp-cli --accept-tos account license "$WARP_KEY"
    fi
    warp-cli --accept-tos connect
    warp-cli --accept-tos enable-always-on

    msg_inf "Downloading optimized roscomvpn geo databases..."
    wget -O /usr/local/x-ui/bin/geoip.dat "https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat"
    wget -O /usr/local/x-ui/bin/geosite.dat "https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat"

    msg_inf "Configuring global WARP routing in X-UI..."
    clean_config='{
      "log": { "access": "", "error": "", "loglevel": "warning" },
      "inbounds": [],
      "outbounds": [
        { "tag": "direct", "protocol": "freedom", "settings": {} },
        { "tag": "blocked", "protocol": "blackhole", "settings": {} },
        { "tag": "warp", "protocol": "socks", "settings": { "servers": [{"address": "127.0.0.1", "port": 40000}] } }
      ],
      "routing": {
        "domainStrategy": "AsIs",
        "rules": [
          { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
          { "type": "field", "outboundTag": "blocked", "ip": ["geoip:private"] },
          { "type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"] },
          { "type": "field", "network": "udp", "port": "443", "outboundTag": "blocked" },
          {
            "type": "field",
            "outboundTag": "warp",
            "domain": [
              "domain:chatgpt.com", "domain:oaistatic.com", "domain:oaiusercontent.com", "domain:claude.ai",
              "domain:api.fitbit.com", "domain:fitbit-pa.googleapis.com", "domain:fitbitvestibuleshim-pa.googleapis.com",
              "domain:fitbit.google.com", "domain:gemini.google.com", "domain:aistudio.google.com", "domain:generativelanguage.googleapis.com",
              "domain:aitestkitchen.withgoogle.com", "domain:aisandbox-pa.googleapis.com", "domain:webchannel-alkalimakersuite-pa.clients6.google.com",
              "domain:alkalimakersuite-pa.clients6.google.com", "domain:assistant-s3-pa.googleapis.com", "domain:proactivebackend-pa.googleapis.com",
              "domain:robinfrontend-pa.googleapis.com", "domain:o.pki.goog", "domain:labs.google", "domain:notebooklm.google.com", "domain:jules.google.com",
              "domain:stitch.withgoogle.com", "domain:googleapis.com", "domain:accounts.google.com", "domain:aiplatform.googleapis.com",
              "domain:googleapis.cn", "domain:goog", "domain:antigravity.google.com", "domain:antigravity-unleash.goog", "domain:google.com"
            ]
          },
          { "type": "field", "outboundTag": "direct", "ip": ["geoip:direct"] },
          { "type": "field", "network": "tcp,udp", "outboundTag": "warp" }
        ]
      }
    }'
    
    escaped_config=$(echo "$clean_config" | jq -c . | sed "s/'/''/g")
    sqlite3 -batch -noheader -init /dev/null $XUIDB <<EOF
DELETE FROM settings WHERE key='xrayTemplateConfig';
INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', '${escaped_config}');
EOF
    msg_ok "WARP+ proxy and optimized AI routing installed successfully!"
}
########################################Update X-UI Port/Path for first INSTALL#########################
UPDATE_XUIDB(){
if [[ -f $XUIDB ]]; then
        x-ui stop
        output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)

        private_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
        public_key=$(echo "$output" | grep "^Password" | awk '{print $3}')

        client_id=$(/usr/local/x-ui/bin/xray-linux-amd64 uuid)
        
        awg_output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
        server_priv=$(echo "$awg_output" | grep -i "Private" | awk '{print $NF}' | tr -cd 'A-Za-z0-9+/=')
        client_awg_output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
        client_priv=$(echo "$client_awg_output" | grep -i "Private" | awk '{print $NF}')
        client_pub=$(echo "$client_awg_output" | grep -i "Public" | awk '{print $NF}')
        if [[ -z "$client_pub" ]]; then
            client_pub=$(echo "$client_awg_output" | grep -i "Password" | awk '{print $NF}')
        fi
        
        awg_output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
        server_priv=$(echo "$awg_output" | grep -i "Private" | awk '{print $NF}' | tr -cd 'A-Za-z0-9+/=')
        server_pub=$(echo "$awg_output" | grep -i "Public" | awk '{print $NF}' | tr -cd 'A-Za-z0-9+/=')
        if [[ -z "$server_pub" ]]; then
            server_pub=$(echo "$awg_output" | grep -i "Password" | awk '{print $NF}' | tr -cd 'A-Za-z0-9+/=')
        fi
        if [[ ${#server_priv} -ne 44 ]]; then
            server_priv=""
            server_pub=""
        fi
        client_awg_output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
        client_priv=$(echo "$client_awg_output" | grep -i "Private" | awk '{print $NF}' | tr -cd 'A-Za-z0-9+/=')
        client_pub=$(echo "$client_awg_output" | grep -i "Public" | awk '{print $NF}' | tr -cd 'A-Za-z0-9+/=')
        if [[ -z "$client_pub" ]]; then
            client_pub=$(echo "$client_awg_output" | grep -i "Password" | awk '{print $NF}' | tr -cd 'A-Za-z0-9+/=')
        fi
        if [[ ${#client_priv} -ne 44 ]]; then
            client_priv=""
            client_pub=""
        fi
        ip_info=$(LC_ALL=en_US.UTF-8 curl -s https://ipwho.is/)
        emoji_flag=$(echo "$ip_info" | jq -r '.flag.emoji')
        country=$(echo "$ip_info" | jq -r '.country')
        node_name="${emoji_flag} ${country}"
       	
  echo -e "\e[1;34m Generating AmneziaWG 3.1 Obfuscation Parameters... \e[0m"
  obfs=$(python3 -c "
import os, base64, random
jc = random.randint(3, 6)
jmin = random.randint(40, 89)
jmax = jmin + random.randint(50, 250)
s1 = random.randint(15, 150)
s2 = random.randint(15, 150)
while s1 + 56 == s2: s2 = random.randint(15, 150)
s3 = random.randint(12, 55)
s4 = random.randint(12, 27)
h = []
lo = 5
band = (2147483647 - lo + 1) // 4
for i in range(4):
    blo = lo + i * band
    bhi = blo + band - 1
    start = random.randint(blo, bhi - 100 - 1)
    h.append(f'{start}-{random.randint(start + 100, bhi - 1)}')
i1 = f'<r {random.randint(32, 256)}>'
hpk = base64.b64encode(os.urandom(32)).decode('utf-8')
cplo = random.randint(8, 24)
cp = f'{cplo}-{cplo + random.randint(8, 40)}'
rklo = random.randint(100, 120)
rkhi = rklo + random.randint(10, 40)
rka = f'{rklo}-{rkhi}'
rjlo = rkhi + random.randint(30, 60)
rja = f'{rjlo}-{rjlo + random.randint(30, 90)}'
rtlo = random.randint(3, 6)
rt = f'{rtlo}-{rtlo + random.randint(1, 4)}'
kalo = random.randint(8, 12)
ka = f'{kalo}-{kalo + random.randint(2, 8)}'
halo = random.randint(15, 25)
mha = f'{halo}-{halo + random.randint(5, 25)}'
print(f'{jc}|{jmin}|{jmax}|{s1}|{s2}|{s3}|{s4}|{h[0]}|{h[1]}|{h[2]}|{h[3]}|{i1}|{hpk}|{cp}|{rka}|{rja}|{rt}|{ka}|{mha}')
")
  IFS='|' read -r o_jc o_jmin o_jmax o_s1 o_s2 o_s3 o_s4 o_h1 o_h2 o_h3 o_h4 o_i1 o_hpk o_cp o_rka o_rja o_rt o_ka o_mha <<< "$obfs"

sqlite3 $XUIDB <<EOF
             DELETE FROM "inbounds";
             DELETE FROM "clients";
             DELETE FROM "client_inbounds";
             DELETE FROM "client_traffics";
             DELETE FROM "settings";
             DELETE FROM sqlite_sequence WHERE name='inbounds';
             DELETE FROM sqlite_sequence WHERE name='clients';
             DELETE FROM sqlite_sequence WHERE name='client_inbounds';
             DELETE FROM sqlite_sequence WHERE name='client_traffics';
             UPDATE "nodes" SET "name" = '${node_name}', "remark" = '${node_name}' WHERE "id" = 1;
             INSERT INTO "settings" ("key", "value") VALUES ("subPort",  '${sub_port}');
	     INSERT INTO "settings" ("key", "value") VALUES ("subPath",  '/${sub_path}/');
	     INSERT INTO "settings" ("key", "value") VALUES ("subURI",  '${sub_uri}');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonPath",  '${json_path}');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonURI",  '${json_uri}');
		 INSERT INTO "settings" ("key", "value") VALUES ("subClashEnable",  'false');
		 INSERT INTO "settings" ("key", "value") VALUES ("subEnableRouting",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("subEnable",  'true');
             INSERT INTO "settings" ("key", "value") VALUES ("webListen",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("webDomain",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("webCertFile",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("webKeyFile",  '');
       	     INSERT INTO "settings" ("key", "value") VALUES ("sessionMaxAge",  '60');
             INSERT INTO "settings" ("key", "value") VALUES ("pageSize",  '50');
             INSERT INTO "settings" ("key", "value") VALUES ("expireDiff",  '0');
             INSERT INTO "settings" ("key", "value") VALUES ("trafficDiff",  '0');
             INSERT INTO "settings" ("key", "value") VALUES ("remarkModel",  '-ieo');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotEnable",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotToken",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotProxy",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotAPIServer",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgBotChatId",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("tgRunTime",  '@daily');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgBotBackup",  'false');
             INSERT INTO "settings" ("key", "value") VALUES ("tgBotLoginNotify",  'true');
	     INSERT INTO "settings" ("key", "value") VALUES ("tgCpu",  '80');
             INSERT INTO "settings" ("key", "value") VALUES ("tgLang",  'en-US');
	     INSERT INTO "settings" ("key", "value") VALUES ("timeLocation",  'Europe/Moscow');
             INSERT INTO "settings" ("key", "value") VALUES ("secretEnable",  'false');
	     INSERT INTO "settings" ("key", "value") VALUES ("subDomain",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subCertFile",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("subKeyFile",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subUpdates",  '12');
	     INSERT INTO "settings" ("key", "value") VALUES ("subEncrypt",  'true');
             INSERT INTO "settings" ("key", "value") VALUES ("subShowInfo",  'true');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonFragment",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonNoises",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("subJsonMux",  '');
             INSERT INTO "settings" ("key", "value") VALUES ("subJsonRules",  '');
	     INSERT INTO "settings" ("key", "value") VALUES ("datepicker",  'gregorian');
             INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','first','0','0','0','0','0');
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','first','0','0','0','0','0');
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('3','1','first','0','0','0','0','0');
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('4','1','first','0','0','0','0','0');
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('5','1','first','0','0','0','0','0');
	     INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('6','1','first','0','0','0','0','0');
             INSERT INTO "clients" ("id", "email", "sub_id", "uuid", "password", "auth", "flow", "limit_ip", "total_gb", "expiry_time", "enable", "tg_id", "reset", "created_at", "updated_at", "wg_private_key", "wg_public_key", "wg_allowed_ips") VALUES (1, 'first', 'first', '${client_id}', '${client_id}', '${client_id}', '', 0, 0, 0, 1, 0, 0, 1756726925000, 1756726925000, '${client_priv}', '${client_pub}', '10.8.1.2/32');
             INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") VALUES (1, 1, 'xtls-rprx-vision', 1756726925000);
             INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") VALUES (1, 2, '', 1756726925000);
             INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") VALUES (1, 3, '', 1756726925000);
             INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") VALUES (1, 4, '', 1756726925000);
             INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") VALUES (1, 5, '', 1756726925000);
             INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") VALUES (1, 6, '', 1756726925000);
             INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${emoji_flag} reality',
	     '1',
             '0',
	     '',
             '8443',
	     'vless',
             '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}',
	     '{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [
    {
      "forceTls": "same",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "127.0.0.1:9443",
    "serverNames": [
      "$reality_domain"
    ],
    "privateKey": "${private_key}",
    "minClient": "0.0.0",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": [
      "${shor[0]}",
      "${shor[1]}",
      "${shor[2]}",
      "${shor[3]}",
      "${shor[4]}",
      "${shor[5]}",
      "${shor[6]}",
      "${shor[7]}"
    ],
    "settings": {
      "publicKey": "${public_key}",
      "fingerprint": "chrome",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": true,
    "header": {
      "type": "none"
    }
  }
}',
             'inbound-8443',
	     '{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic"
  ],
  "metadataOnly": false,
  "routeOnly": true
}'
	     );
      INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
             '1',
	     '0',
             '0',
	     '0',
             '${emoji_flag} ws',
	     '1',
             '0',
	     '',
             '${ws_port}',
	     'vless',
             '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}','{
  "network": "ws",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "wsSettings": {
    "acceptProxyProtocol": false,
    "path": "/${ws_port}/${ws_path}",
    "host": "${domain}",
    "headers": {}
  }
}',
             'inbound-${ws_port}',
	     '{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic"
  ],
  "metadataOnly": false,
  "routeOnly": true
}'
	     );
	INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
	     '1',
	     '0',
         '0',
	     '0',
         '${emoji_flag} trojan-grpc',
	     '1',
         '0',
		 '',
		 '${trojan_port}',
		 'trojan',
		 '{
  "clients": [],
  "fallbacks": []
}',
'{
  "network": "grpc",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "grpcSettings": {
    "serviceName": "/${trojan_port}/${trojan_path}",
    "authority": "${domain}",
    "multiMode": false
  }
}',
'inbound-${trojan_port}',
'{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic"
  ],
  "metadataOnly": false,
  "routeOnly": true
}',
         '1'
	);
	INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
	     '1',
	     '0',
         '0',
	     '0',
         '${emoji_flag} hysteria2',
	     '1',
         '0',
		 '',
		 '${hy2_port}',
		 'hysteria',
		 '{
  "clients": [],
  "ignoreClientBandwidth": false
}',
'{
  "network": "hysteria",
  "security": "tls",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": ${hy2_port},
      "remark": ""
    }
  ],
  "hysteriaSettings": {
    "version": 2,
    "udpIdleTimeout": 300
  },
  "tlsSettings": {
    "serverName": "${domain}",
    "certificates": [
      {
        "useFile": true,
        "certificateFile": "/root/cert/${domain}/fullchain.pem",
        "keyFile": "/root/cert/${domain}/privkey.pem"
      }
    ],
    "alpn": [
      "h3"
    ]
  }
}',
'inbound-${hy2_port}',
'{
  "enabled": true,
  "destOverride": [
    "http",
    "tls",
    "quic"
  ],
  "metadataOnly": false,
  "routeOnly": true
}'
	     );
	INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
	     '1',
	     '0',
         '0',
	     '0',
         '${emoji_flag} amneziawg',
	     '1',
         '0',
		 '',
		 '${awg_port}',
		 'amneziawg',
		 '{
  "server": {
    "privateKey": "${server_priv}",
    "publicKey": "${server_pub}",
    "subnetIp": "10.8.1.0",
    "subnetCidr": 24,
    "mtu": 1280,
    "primaryDns": "8.8.8.8",
    "secondaryDns": "8.8.4.4",
    "jc": ${o_jc},
    "jmin": ${o_jmin},
    "jmax": ${o_jmax},
    "s1": ${o_s1},
    "s2": ${o_s2},
    "s3": ${o_s3},
    "s4": ${o_s4},
    "h1": "${o_h1}",
    "h2": "${o_h2}",
    "h3": "${o_h3}",
    "h4": "${o_h4}",
    "i1": "${o_i1}",
    "headerProtectionKey": "${o_hpk}",
    "contentPaddingAddition": "${o_cp}",
    "rekeyAfterTime": "${o_rka}",
    "rejectAfterTime": "${o_rja}",
    "rekeyTimeout": "${o_rt}",
    "keepaliveTimeout": "${o_ka}",
    "maxHandshakeAttempts": "${o_mha}",
    "randomTrailers": true,
    "disableCookies": true
  },
  "clients": []
}',
'{
  "network": "amneziawg",
  "security": "none"
}',
'inbound-${awg_port}',
'{
  "enabled": false,
  "destOverride": [
    "http",
    "tls",
    "quic",
    "fakedns"
  ],
  "metadataOnly": false,
  "routeOnly": false
}'
	);
EOF
/usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${panel_port}" -webBasePath "${panel_path}"
/usr/local/x-ui/x-ui cert -webCert "/root/cert/${domain}/fullchain.pem" -webCertKey "/root/cert/${domain}/privkey.pem"
x-ui start
else
	msg_err "x-ui.db file not exist! Maybe x-ui isn't installed." && exit 1;
fi
}
arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

config_after_install() {
            /usr/local/x-ui/x-ui setting -username "asdfasdf" -password "asdfasdf" -port "2096" -webBasePath "asdfasdf"    
            /usr/local/x-ui/x-ui migrate
}

install_panel() {
apt-get update && apt-get install -y -q wget curl tar tzdata
    cd /usr/local/
    
    # Download resources
    if [ $# == 0 ]; then
        tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}Trying to fetch version with IPv4...${plain}"
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ ! -n "$tag_version" ]]; then
                echo -e "${red}Failed to fetch x-ui version, it may be due to GitHub API restrictions, please try it later${plain}"
                exit 1
            fi
        fi
        echo -e "Got x-ui latest version: ${tag_version}, beginning the installation..."
        wget -N -O /usr/local/x-ui-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading x-ui failed, please be sure that your server can access GitHub ${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="2.3.5"
        
        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}Please use a newer version (at least v2.3.5). Exiting installation.${plain}"
            exit 1
        fi
        
        url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "Beginning to install x-ui $1"
        wget -N -O /usr/local/x-ui-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download x-ui $1 failed, please check if the version exists ${plain}"
            exit 1
        fi
    fi
    wget -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to download x-ui.sh${plain}"
        exit 1
    fi
    
    # Stop x-ui service and remove old resources
    if [[ -e /usr/local/x-ui/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        rm /usr/local/x-ui/ -rf
    fi
    
    # Extract resources and set permissions
    tar zxvf x-ui-linux-$(arch).tar.gz
    rm x-ui-linux-$(arch).tar.gz -f
    
    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh
    
    # Check the system's architecture and rename the file accordingly
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-$(arch)
    
    # Update x-ui cli and se set permission
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
	config_after_install
    
    if [[ $release == "alpine" ]]; then
        wget --inet4-only -O /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Failed to download x-ui.rc${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
        systemctl daemon-reload
        systemctl enable x-ui
        systemctl start x-ui
    fi
    
    echo -e "${green}x-ui ${tag_version}${plain} installation finished, it is running now..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Admin Management Script          │
│  ${blue}x-ui start${plain}        - Start                            │
│  ${blue}x-ui stop${plain}         - Stop                             │
│  ${blue}x-ui restart${plain}      - Restart                          │
│  ${blue}x-ui status${plain}       - Current Status                   │
│  ${blue}x-ui settings${plain}     - Current Settings                 │
│  ${blue}x-ui enable${plain}       - Enable Autostart on OS Startup   │
│  ${blue}x-ui disable${plain}      - Disable Autostart on OS Startup  │
│  ${blue}x-ui log${plain}          - Check logs                       │
│  ${blue}x-ui banlog${plain}       - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}       - Update                           │
│  ${blue}x-ui legacy${plain}       - Legacy version                   │
│  ${blue}x-ui install${plain}      - Install                          │
│  ${blue}x-ui uninstall${plain}    - Uninstall                        │
└───────────────────────────────────────────────────────┘"

}
###################################Install X-UI#########################################################
if systemctl is-active --quiet x-ui; then
	x-ui restart
else
    install_panel	
	UPDATE_XUIDB
	if [[ ${WARP} == *"y"* ]]; then
		SETUP_WARP
	fi
	if ! systemctl is-enabled --quiet x-ui; then
		systemctl daemon-reload && systemctl enable x-ui.service
	fi
	x-ui restart
fi

######################enable bbr and tune system########################################################
apt-get install -yqq --no-install-recommends ca-certificates
echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
echo "fs.file-max=2097152" | tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_timestamps = 1" | tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_sack = 1" | tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_window_scaling = 1" | tee -a /etc/sysctl.conf
echo "net.core.rmem_max = 16777216" | tee -a /etc/sysctl.conf
echo "net.core.wmem_max = 16777216" | tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_rmem = 4096 87380 16777216" | tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_wmem = 4096 65536 16777216" | tee -a /etc/sysctl.conf

sysctl -p


######################install_sub2sing-box#################################################################

if pgrep -x "sub2sing-box" > /dev/null; then
    echo "kill sub2sing-box..."
    pkill -x "sub2sing-box"
fi
if [ -f "/usr/bin/sub2sing-box" ]; then
    echo "delete sub2sing-box..."
    rm -f /usr/bin/sub2sing-box
fi
wget -P /root/ https://github.com/legiz-ru/sub2sing-box/releases/download/v0.0.9/sub2sing-box_0.0.9_linux_amd64.tar.gz
tar -xvzf /root/sub2sing-box_0.0.9_linux_amd64.tar.gz -C /root/ --strip-components=1 sub2sing-box_0.0.9_linux_amd64/sub2sing-box
mv /root/sub2sing-box /usr/bin/
chmod +x /usr/bin/sub2sing-box
rm /root/sub2sing-box_0.0.9_linux_amd64.tar.gz
su -c "/usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 & disown" root

######################install_fake_site#################################################################

FAKE_SITE_TMP=$(mktemp -d)
if wget -qO "$FAKE_SITE_TMP/repo.tar.gz" "https://github.com/mozaroc/3x-ui-pro/archive/refs/heads/main.tar.gz" \
	&& tar -xzf "$FAKE_SITE_TMP/repo.tar.gz" -C "$FAKE_SITE_TMP" --strip-components=3 "3x-ui-pro-main/assets/fake-sites"; then
	FAKE_SITES=("$FAKE_SITE_TMP"/site-*/)
	FAKE_SITE="${FAKE_SITES[$((RANDOM % ${#FAKE_SITES[@]}))]}"
	msg_inf "Random fake site template: $(basename "$FAKE_SITE")"
	mkdir -p /var/www/html
	rm -rf /var/www/html/*
	cp -a "$FAKE_SITE". /var/www/html/
	msg_ok "Fake site installed successfully!"
else
	msg_err "Failed to download fake site templates!"
fi
rm -rf "$FAKE_SITE_TMP"

######################install_web_sub_page##############################################################

URL_SUB_PAGE=( "https://github.com/DesperateVanilla/x-ui-pro/raw/master/sub-3x-ui.html"
		"https://github.com/DesperateVanilla/x-ui-pro/raw/master/sub-3x-ui-classical.html"
	)
URL_CLASH_SUB=( "https://github.com/DesperateVanilla/x-ui-pro/raw/master/clash/clash.yaml"
		"https://github.com/DesperateVanilla/x-ui-pro/raw/master/clash/clash_skrepysh.yaml"
		"https://github.com/DesperateVanilla/x-ui-pro/raw/master/clash/clash_fullproxy_without_ru.yaml"
  		"https://github.com/DesperateVanilla/x-ui-pro/raw/master/clash/clash_refilter_ech.yaml"
	)
DEST_DIR_SUB_PAGE="/var/www/subpage"
DEST_FILE_SUB_PAGE="$DEST_DIR_SUB_PAGE/index.html"
DEST_FILE_CLASH_SUB="$DEST_DIR_SUB_PAGE/clash.yaml"

sudo mkdir -p "$DEST_DIR_SUB_PAGE"

sudo curl -L "${URL_CLASH_SUB[$CLASH]}" -o "$DEST_FILE_CLASH_SUB"
sudo curl -L "${URL_SUB_PAGE[$CUSTOMWEBSUB]}" -o "$DEST_FILE_SUB_PAGE"

sed -i "s/\${DOMAIN}/$domain/g" "$DEST_FILE_SUB_PAGE"
sed -i "s/\${DOMAIN}/$domain/g" "$DEST_FILE_CLASH_SUB"
sed -i "s#\${SUB_JSON_PATH}#$json_path#g" "$DEST_FILE_SUB_PAGE"
sed -i "s#\${SUB_PATH}#$sub_path#g" "$DEST_FILE_SUB_PAGE"
sed -i "s#\${SUB_PATH}#$sub_path#g" "$DEST_FILE_CLASH_SUB"
sed -i "s|sub.legiz.ru|$domain/$sub2singbox_path|g" "$DEST_FILE_SUB_PAGE"

#while true; do	
#	if [[ -n "$tg_escaped_link" ]]; then
#		break
#	fi
#	echo -en "Enter your support link for web sub page (example https://t.me/durov/ ): " && read tg_escaped_link
#done

#sed -i -e "s|https://t.me/gozargah_marzban|$tg_escaped_link|g" -e "s|https://github.com/Gozargah/Marzban#donation|$tg_escaped_link|g" "$DEST_FILE_SUB_PAGE"

######################cronjob for ssl/reload service/cloudflareips######################################
crontab -l | grep -v "certbot\|x-ui\|cloudflareips\|sub2sing-box" | crontab -
(crontab -l 2>/dev/null; echo '@reboot /usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 > /dev/null 2>&1') | crontab -
(crontab -l 2>/dev/null; echo '@daily x-ui restart > /dev/null 2>&1 && nginx -s reload;') | crontab -
(crontab -l 2>/dev/null; echo '@monthly certbot renew --nginx --non-interactive --post-hook "nginx -s reload" > /dev/null 2>&1;') | crontab -
##################################ufw###################################################################
ufw disable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow ${hy2_port}/udp
ufw allow ${hy2_port}/tcp
ufw allow ${panel_port}/tcp
ufw --force enable  
##################################Show Details##########################################################

if systemctl is-active --quiet x-ui; then clear
	printf '0\n' | x-ui | grep --color=never -i ':'
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	nginx -T | grep -i 'ssl_certificate\|ssl_certificate_key'
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	certbot certificates | grep -i 'Path:\|Domains:\|Expiry Date:'

#	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
#	if [[ -n $IP4 ]] && [[ "$IP4" =~ $IP4_REGEX ]]; then 
#		msg_inf "IPv4: http://$IP4:$PORT/$RNDSTR/"
#	fi
#	if [[ -n $IP6 ]] && [[ "$IP6" =~ $IP6_REGEX ]]; then 
#		msg_inf "IPv6: http://[$IP6]:$PORT/$RNDSTR/"
#	fi

 msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/\n"
 	echo -e "Username:  ${config_username} \n" 
	echo -e "Password:  ${config_password} \n" 
	msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    msg_inf "Web Sub Page your first client: https://${domain}/${web_path}?name=first\n"
    msg_inf "Your local sub2sing-box instance: https://${domain}/$sub2singbox_path/\n"
  msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
	msg_inf "Please Save this Screen!!"	
else
	nginx -t && printf '0\n' | x-ui | grep --color=never -i ':'
	msg_err "sqlite and x-ui to be checked, try on a new clean linux! "
fi
#################################################N-joy##################################################
