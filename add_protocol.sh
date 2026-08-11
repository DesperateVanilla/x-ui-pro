#!/bin/bash
[[ $EUID -ne 0 ]] && echo "not root!" && sudo su -

XUIDB="/etc/x-ui/x-ui.db"

if [[ ! -f $XUIDB ]]; then
    echo -e "\e[1;41m x-ui database not found at $XUIDB \e[0m"
    exit 1
fi

PROTOCOL=$1
if [[ "$PROTOCOL" != "xhttp" ]]; then
    echo -e "\e[1;34m Usage: bash add_protocol.sh xhttp \e[0m"
    exit 1
fi

# Check if xhttp already exists
EXISTING=$(sqlite3 $XUIDB "SELECT id FROM inbounds WHERE remark LIKE '%xhttp%';")
if [[ -n "$EXISTING" ]]; then
    echo -e "\e[1;42m XHTTP protocol already exists in the database (inbound id: $EXISTING). \e[0m"
    exit 0
fi

# Get existing domain and emoji flag
domain=$(sqlite3 $XUIDB "SELECT value FROM settings WHERE key='subURI';" | grep -v 'Loading resources' | awk -F/ '{print $3}' | grep -v '^$')
if [[ -z "$domain" ]]; then
    # Fallback to serverName from any inbound
    domain=$(sqlite3 $XUIDB "SELECT stream_settings FROM inbounds;" | grep -oP '(?<="serverName": ")[^"]*' | head -n 1)
fi
if [[ -z "$domain" ]]; then
    # Fallback to dest from any inbound
    domain=$(sqlite3 $XUIDB "SELECT stream_settings FROM inbounds;" | grep -oP '(?<="dest": ")[^"]*' | head -n 1)
fi
if [[ -z "$domain" ]]; then
    echo -e "\e[1;41m Failed to extract domain from database! \e[0m"
    exit 1
fi

emoji_flag=$(sqlite3 $XUIDB "SELECT remark FROM inbounds LIMIT 1;" | grep -v 'Loading resources' | awk '{print $1}')
if [[ -z "$emoji_flag" ]]; then
    emoji_flag="🚀"
fi

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

xhttp_port=$(make_port)
xhttp_path=$(gen_random_string 10)

echo -e "\e[1;34m Generating XHTTP inbound on port $xhttp_port with path /$xhttp_port/$xhttp_path \e[0m"

# Get next inbound ID (max id + 1)
next_inbound_id=$(sqlite3 $XUIDB "SELECT COALESCE(MAX(id),0) + 1 FROM inbounds;")

# Get the first client ID to link it
client_id=$(sqlite3 $XUIDB "SELECT id FROM clients ORDER BY id ASC LIMIT 1;")
if [[ -z "$client_id" ]]; then
    echo -e "\e[1;41m No clients found in database! \e[0m"
    exit 1
fi

# Insert into database
sqlite3 $XUIDB <<EOF
    INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('${next_inbound_id}','1','first','0','0','0','0','0');
    INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") VALUES (${client_id}, ${next_inbound_id}, '', 1756726925000);
    INSERT INTO "inbounds" ("id", "user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
         ${next_inbound_id},
	     '1',
	     '0',
         '0',
	     '0',
         '${emoji_flag} xhttp',
	     '1',
         '0',
		 '',
		 '${xhttp_port}',
		 'vless',
		 '{
  "clients": [],
  "decryption": "none",
  "fallbacks": []
}',
'{
  "network": "xhttp",
  "security": "none",
  "externalProxy": [
    {
      "forceTls": "tls",
      "dest": "${domain}",
      "port": 443,
      "remark": ""
    }
  ],
  "xhttpSettings": {
    "path": "/${xhttp_port}/${xhttp_path}",
    "host": "${domain}",
    "headers": {},
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000",
    "mode": "auto",
    "extra": {
      "noFastIn": false,
      "noFastOut": false
    }
  }
}',
'inbound-${xhttp_port}',
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

echo -e "\e[1;42m XHTTP inbound successfully added! Restarting X-UI... \e[0m"
x-ui restart

echo -e "\e[1;34m Check your 3x-ui panel to see the new connection. \e[0m"
