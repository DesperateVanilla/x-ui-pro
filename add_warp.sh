#!/bin/bash
#################### Add WARP to existing 3X-UI ####################
[[ $EUID -ne 0 ]] && echo "Error: This script must be run as root!" && exit 1

msg_ok() { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m $1 \e[0m";}

Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")
XUIDB="/etc/x-ui/x-ui.db"

if [ ! -f "$XUIDB" ]; then
    msg_err "x-ui.db not found at $XUIDB! Is 3x-ui installed?"
    exit 1
fi

msg_inf "Installing requirements (jq, curl, gpg)..."
$Pak -y update
$Pak -y install jq curl gnupg2 sqlite3

msg_inf "Cleaning up old cloudflare-warp if present..."
if command -v warp-cli &> /dev/null; then
    warp-cli --accept-tos registration delete 2>/dev/null || true
    systemctl stop warp-svc 2>/dev/null || true
    $Pak -y remove cloudflare-warp || true
fi

msg_inf "Installing WARP WireProxy Manager..."
bash <(wget -qO- https://raw.githubusercontent.com/kuzzrus/WARP_WireProxy_Manager/main/warpwp.sh) --install
sleep 3

msg_inf "Injecting WARP Outbound and Routing into x-ui database..."
# Use -batch -noheader -init /dev/null to prevent .sqliterc output pollution
current_config=$(sqlite3 -batch -noheader -init /dev/null $XUIDB "SELECT value FROM settings WHERE key='xrayTemplateConfig';")

# Validate current config is actually valid JSON
if ! echo "$current_config" | jq . >/dev/null 2>&1; then
    msg_err "Current xrayTemplateConfig is empty or corrupted (invalid JSON). Generating a fresh default config..."
    current_config=""
fi

if [ -z "$current_config" ] || [ "$current_config" == "null" ]; then
    msg_inf "Generating default template with WARP..."
    new_config='{
  "log": { "access": "", "error": "", "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": {} },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} },
    { "tag": "warp", "protocol": "socks", "settings": { "servers": [ { "address": "127.0.0.1", "port": 40000 } ] } }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": [ "api" ], "outboundTag": "api" },
      { "type": "field", "outboundTag": "blocked", "ip": [ "geoip:private" ] },
      { "type": "field", "outboundTag": "blocked", "protocol": [ "bittorrent" ] },
      { "type": "field", "outboundTag": "warp", "domain": [
          "geosite:openai", "geosite:anthropic", "domain:chatgpt.com", "domain:oaistatic.com", "domain:oaiusercontent.com", "domain:claude.ai",
          "domain:api.fitbit.com", "domain:fitbit-pa.googleapis.com", "domain:fitbitvestibuleshim-pa.googleapis.com",
          "domain:fitbit.google.com", "domain:gemini.google.com", "domain:aistudio.google.com", "domain:generativelanguage.googleapis.com",
          "domain:aitestkitchen.withgoogle.com", "domain:aisandbox-pa.googleapis.com", "domain:webchannel-alkalimakersuite-pa.clients6.google.com",
          "domain:alkalimakersuite-pa.clients6.google.com", "domain:assistant-s3-pa.googleapis.com", "domain:proactivebackend-pa.googleapis.com",
          "domain:robinfrontend-pa.googleapis.com", "domain:o.pki.goog", "domain:labs.google", "domain:notebooklm.google.com", "domain:jules.google.com",
          "domain:stitch.withgoogle.com"
      ] }
    ]
  }
}'
else
    msg_inf "Found existing valid xrayTemplateConfig. Updating via jq..."
    
    # Check if 'warp' outbound exists, if not, add it
    has_warp=$(echo "$current_config" | jq '[.outbounds[]? | select(.tag == "warp")] | length')
    if [ "$has_warp" -eq 0 ]; then
        current_config=$(echo "$current_config" | jq '.outbounds += [{"tag": "warp", "protocol": "socks", "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}}]')
    fi
    
    # Add or replace the warp routing rule safely
    new_config=$(echo "$current_config" | jq '
        if .routing == null then .routing = {"domainStrategy": "AsIs", "rules": []} else . end |
        if .routing.rules == null then .routing.rules = [] else . end |
        .routing.rules = [.routing.rules[] | select(.outboundTag != "warp")] + 
        [{"type": "field", "outboundTag": "warp", "domain": [
          "geosite:openai", "geosite:anthropic", "domain:chatgpt.com", "domain:oaistatic.com", "domain:oaiusercontent.com", "domain:claude.ai",
          "domain:api.fitbit.com", "domain:fitbit-pa.googleapis.com", "domain:fitbitvestibuleshim-pa.googleapis.com",
          "domain:fitbit.google.com", "domain:gemini.google.com", "domain:aistudio.google.com", "domain:generativelanguage.googleapis.com",
          "domain:aitestkitchen.withgoogle.com", "domain:aisandbox-pa.googleapis.com", "domain:webchannel-alkalimakersuite-pa.clients6.google.com",
          "domain:alkalimakersuite-pa.clients6.google.com", "domain:assistant-s3-pa.googleapis.com", "domain:proactivebackend-pa.googleapis.com",
          "domain:robinfrontend-pa.googleapis.com", "domain:o.pki.goog", "domain:labs.google", "domain:notebooklm.google.com", "domain:jules.google.com",
          "domain:stitch.withgoogle.com"
        ]}]
    ')
fi

# Validate new config before destroying the old one
if ! echo "$new_config" | jq . >/dev/null 2>&1; then
    msg_err "Critical Error: Generated JSON is invalid. Aborting to prevent x-ui crash."
    exit 1
fi

# Insert back to SQLite
escaped_config=$(echo "$new_config" | sed "s/'/''/g")
sqlite3 -batch -noheader -init /dev/null $XUIDB <<EOF
DELETE FROM settings WHERE key='xrayTemplateConfig';
INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', '${escaped_config}');
EOF

msg_ok "Configuration injected successfully!"
msg_inf "Restarting x-ui to apply changes..."
systemctl restart x-ui
sleep 2

if systemctl is-active --quiet x-ui; then
    msg_ok "WARP integration is complete! Your AI services are now routed through Cloudflare WARP."
else
    msg_err "Failed to restart x-ui. Please check 'systemctl status x-ui' and database syntax."
fi
