#!/bin/bash
[[ $EUID -ne 0 ]] && echo "not root!" && sudo su -

XUIDB="/etc/x-ui/x-ui.db"

if [[ ! -f $XUIDB ]]; then
    echo -e "\e[1;41m x-ui database not found at $XUIDB \e[0m"
    exit 1
fi

PROTOCOL=$1
if [[ "$PROTOCOL" != "awg" ]]; then
    echo -e "\e[1;34m Usage: bash add_protocol.sh awg \e[0m"
    exit 1
fi

echo -e "\e[1;34m Stopping X-UI to prevent database locks... \e[0m"
x-ui stop
sleep 2

echo -e "\e[1;34m Compressing Inbound IDs to prevent AWG ID error... \e[0m"
python3 -c "
import sqlite3, sys
db_path = '$XUIDB'
try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute('SELECT id FROM inbounds ORDER BY id')
    inbounds = [row[0] for row in cur.fetchall()]
    if not inbounds or max(inbounds) <= 400:
        sys.exit(0)
    
    new_id = 1
    for old_id in inbounds:
        if old_id != new_id:
            cur.execute('UPDATE inbounds SET id = ? WHERE id = ?', (new_id, old_id))
            for table in ['client_inbounds', 'client_traffics', 'hosts', 'inbound_client_ips']:
                try:
                    cur.execute(f'UPDATE {table} SET inbound_id = ? WHERE inbound_id = ?', (new_id, old_id))
                except sqlite3.OperationalError:
                    pass
        new_id += 1
    cur.execute(\"UPDATE sqlite_sequence SET seq = ? WHERE name = 'inbounds'\", (new_id - 1,))
    con.commit()
    con.close()
    print('IDs compressed successfully.')
except Exception as e:
    print('Error compressing IDs:', e)
"

# Check if awg already exists on LOCAL node
EXISTING=$(sqlite3 $XUIDB "SELECT id FROM inbounds WHERE protocol='amneziawg' AND (node_id IS NULL OR node_id = '');" | tail -n 1 | awk '{print $1}')
if [[ -n "$EXISTING" ]]; then
    echo -e "\e[1;42m AmneziaWG protocol already exists on Local Panel (inbound id: $EXISTING). \e[0m"
    x-ui restart
    exit 0
fi

# AWG port shouldn't conflict with existing
get_port() {
	echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}
check_free() {
	local port=$1
	nc -z -u 127.0.0.1 $port &>/dev/null
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
awg_port=$(make_port)

emoji_flag=$(sqlite3 $XUIDB "SELECT remark FROM inbounds LIMIT 1;" | tail -n 1 | awk '{print $1}')
if [[ -z "$emoji_flag" ]]; then
    emoji_flag="🚀"
fi

echo -e "\e[1;34m Generating AmneziaWG keys... \e[0m"
awg_output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
server_priv=$(echo "$awg_output" | grep -i "Private" | awk '{print $NF}')
server_pub=$(echo "$awg_output" | grep -i "Public" | awk '{print $NF}')
if [[ -z "$server_pub" ]]; then
    server_pub=$(echo "$awg_output" | grep -i "Password" | awk '{print $NF}')
fi

next_inbound_id=$(sqlite3 $XUIDB "SELECT COALESCE(MAX(id),0) + 1 FROM inbounds;" | tail -n 1 | awk '{print $1}')
created_at=$(date +%s000)

echo -e "\e[1;34m Generating AWG inbound on port $awg_port \e[0m"

# Update existing clients with AWG keys
client_ids=$(sqlite3 $XUIDB "SELECT id FROM clients;")
if [[ -z "$client_ids" ]]; then
    echo -e "\e[1;41m No clients found in database! \e[0m"
    x-ui restart
    exit 1
fi

awg_ip_counter=2
for cid in $client_ids; do
    client_awg_output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
    cpriv=$(echo "$client_awg_output" | grep -i "Private" | awk '{print $NF}')
    cpub=$(echo "$client_awg_output" | grep -i "Public" | awk '{print $NF}')
    if [[ -z "$cpub" ]]; then
        cpub=$(echo "$client_awg_output" | grep -i "Password" | awk '{print $NF}')
    fi
    allowed_ip="10.0.0.${awg_ip_counter}/32"
    
    sqlite3 $XUIDB "UPDATE clients SET wg_private_key='${cpriv}', wg_public_key='${cpub}', wg_allowed_ips='${allowed_ip}' WHERE id=${cid};"
    ((awg_ip_counter++))
done

# Insert AWG Inbound
sqlite3 $XUIDB <<EOF
    INSERT OR IGNORE INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") SELECT '${next_inbound_id}', enable, email, 0, 0, 0, 0, 0 FROM clients;
    INSERT INTO "client_inbounds" ("client_id", "inbound_id", "flow_override", "created_at") SELECT id, ${next_inbound_id}, '', ${created_at} FROM clients;
    INSERT INTO "inbounds" ("id", "user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
         ${next_inbound_id},
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
    "jc": 120,
    "jmin": 50,
    "jmax": 1000,
    "s1": 0,
    "s2": 0,
    "h1": "1",
    "h2": "2",
    "h3": "3",
    "h4": "4"
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

echo -e "\e[1;42m AmneziaWG inbound successfully added! Restarting X-UI... \e[0m"
x-ui restart
echo -e "\e[1;34m Check your 3x-ui panel to see the new connection. \e[0m"
