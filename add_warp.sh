#!/bin/bash
#################### Add WARP Routing to existing 3X-UI ####################
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

msg_inf "Installing jq and sqlite3..."
$Pak -y update
$Pak -y install jq sqlite3

msg_inf "Cleaning up any old external WARP clients (warp-cli, wireproxy)..."
systemctl stop warp-svc 2>/dev/null || true
$Pak -y remove cloudflare-warp 2>/dev/null || true
systemctl stop wireproxy 2>/dev/null || true
systemctl disable wireproxy 2>/dev/null || true
rm -f /usr/local/bin/wireproxy /usr/local/bin/warpwp /usr/local/bin/warp-wireproxy-native.sh
rm -rf /etc/wireguard/proxy.conf /etc/wireguard/warp*

msg_inf "Injecting WARP AI Routing into x-ui database..."
current_config=$(sqlite3 -batch -noheader -init /dev/null $XUIDB "SELECT value FROM settings WHERE key='xrayTemplateConfig';")

if ! echo "$current_config" | jq . >/dev/null 2>&1; then
    msg_err "Current xrayTemplateConfig is empty or corrupted (invalid JSON)."
    exit 1
fi

msg_inf "Found existing valid xrayTemplateConfig. Updating via jq..."

# We no longer generate a SOCKS5 outbound. We just set routing rules to point to tag 'warp'.
# The user will use the 3X-UI panel's native WARP generator to create the 'warp' outbound.
new_config=$(echo "$current_config" | jq '
    .outbounds = [.outbounds[]? | select(.protocol != "socks" or .tag != "warp")] |
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

if ! echo "$new_config" | jq . >/dev/null 2>&1; then
    msg_err "Critical Error: Generated JSON is invalid. Aborting."
    exit 1
fi

escaped_config=$(echo "$new_config" | sed "s/'/''/g")
sqlite3 -batch -noheader -init /dev/null $XUIDB <<EOF
DELETE FROM settings WHERE key='xrayTemplateConfig';
INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', '${escaped_config}');
EOF

msg_ok "Routing configuration injected successfully!"
msg_inf "Restarting x-ui to apply changes..."
systemctl restart x-ui
sleep 2

msg_ok "WARP integration is complete!"
msg_inf "IMPORTANT: Go to your 3X-UI Panel -> Outbounds -> Add WARP to generate the native outbound."
msg_inf "Ensure the tag is named 'warp' (lowercase) so the AI routing rules match it!"
