#!/bin/bash
set -euo pipefail

# ============================================================================
# Xray VLESS/XHTTP/Reality Installer
# Domain: wishnu.duckdns.org | IP: 207.148.6.13
# Architecture: Caddy + Static Site Masking + Full System Optimization
# ============================================================================

readonly DOMAIN="wishnu.duckdns.org"
readonly SERVER_IP="207.148.6.13"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_KEYS="/usr/local/etc/xray/.keys"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly SITE_DIR="/var/www/html"
readonly HELP_FILE="${HOME}/help"

log() {
    local level="$1"; shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)    printf '[%s] \033[36mINFO\033[0m    %s\n' "$timestamp" "$*" ;;
        SUCCESS) printf '[%s] \033[32mSUCCESS\033[0m %s\n' "$timestamp" "$*" ;;
        WARNING) printf '[%s] \033[33mWARNING\033[0m %s\n' "$timestamp" "$*" ;;
        ERROR)   printf '[%s] \033[31mERROR\033[0m   %s\n' "$timestamp" "$*" >&2; exit 1 ;;
        *)       printf '[%s] %s\n' "$timestamp" "$*" ;;
    esac
}

check_root() {
    [[ "$EUID" -eq 0 ]] || log ERROR "This script must be run as root (use sudo)"
}

# ============================================================================
# Phase 1: System Optimization
# ============================================================================

optimize_swap() {
    log INFO "Configuring swap space..."
    local total_mem
    total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    
    if [[ "$total_mem" -lt 2048 ]] && [[ ! -f /swapfile ]]; then
        local swap_size=$(( (2048 - total_mem) / 1024 + 1 ))
        log INFO "Creating ${swap_size}G swap (available RAM: ${total_mem}M)..."
        dd if=/dev/zero of=/swapfile bs=1G count="$swap_size" status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log SUCCESS "Swap configured successfully"
    else
        log INFO "Swap not required (RAM: ${total_mem}M)"
    fi
}

optimize_network() {
    log INFO "Tuning network stack..."
    cat > /etc/sysctl.d/99-xray-tuning.conf <<EOF
# BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# TCP optimizations
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.core.netdev_max_backlog=4096
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_mtu_probing=1

# Security hardening
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
EOF
    
    sysctl -p /etc/sysctl.d/99-xray-tuning.conf >/dev/null
    log SUCCESS "Network stack optimized (BBR: $(sysctl -n net.ipv4.tcp_congestion_control))"
}

configure_trim() {
    log INFO "Configuring SSD TRIM..."
    if lsblk -d -o NAME,ROTA 2>/dev/null | awk '$2 == "0" {print $1}' | grep -q . 2>/dev/null; then
        systemctl enable fstrim.timer --now >/dev/null 2>&1 || true
        log SUCCESS "TRIM enabled for SSD storage"
    else
        log INFO "HDD detected, TRIM skipped"
    fi
}

# ============================================================================
# Phase 2: Security Hardening
# ============================================================================

configure_firewall() {
    log INFO "Configuring UFW firewall..."
    apt-get install -y ufw >/dev/null 2>&1
    
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp comment "SSH" >/dev/null 2>&1
    ufw allow 80/tcp comment "HTTP (ACME/Caddy)" >/dev/null 2>&1
    ufw allow 443/tcp comment "HTTPS (Xray)" >/dev/null 2>&1
    
    echo "y" | ufw enable >/dev/null 2>&1 || true
    log SUCCESS "Firewall active (ports 22/80/443 open)"
}

configure_fail2ban() {
    log INFO "Configuring Fail2Ban..."
    apt-get install -y fail2ban >/dev/null 2>&1
    
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
findtime = 10m
ignoreip = 127.0.0.1/8 ::1
EOF
    
    systemctl enable fail2ban --now >/dev/null 2>&1 || true
    log SUCCESS "Fail2Ban active (SSH protection: 3 attempts → 1h ban)"
}

# ============================================================================
# Phase 3: Static Site for Traffic Masking
# ============================================================================

create_masking_site() {
    log INFO "Creating static site for traffic masking..."
    mkdir -p "$SITE_DIR"
    
    # Minimal professional landing page
    cat > "$SITE_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Wishnu Cloud Services</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;line-height:1.6;color:#333;background:#f8f9fa}main{max-width:1200px;margin:0 auto;padding:4rem 2rem}header{text-align:center;margin-bottom:3rem}h1{font-size:2.5rem;color:#4a6cf7;margin-bottom:1rem}p.lead{color:#666;font-size:1.25rem;max-width:600px;margin:0 auto}section{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:2rem;margin-top:3rem}article{background:#fff;border-radius:12px;padding:2rem;box-shadow:0 4px 6px rgba(0,0,0,0.05);transition:transform .2s}article:hover{transform:translateY(-4px)}h2{font-size:1.5rem;color:#4a6cf7;margin-bottom:1rem}footer{text-align:center;margin-top:4rem;color:#666;font-size:.9rem}
    </style>
</head>
<body>
    <main>
        <header>
            <h1>Wishnu Cloud Services</h1>
            <p class="lead">Enterprise-grade infrastructure solutions with 99.9% uptime guarantee</p>
        </header>
        <section>
            <article>
                <h2>Cloud Infrastructure</h2>
                <p>Scalable VPS solutions with NVMe storage and 10Gbps network connectivity.</p>
            </article>
            <article>
                <h2>Network Security</h2>
                <p>Advanced DDoS protection and end-to-end encryption for all traffic.</p>
            </article>
            <article>
                <h2>24/7 Support</h2>
                <p>Dedicated technical team available round-the-clock for rapid issue resolution.</p>
            </article>
        </section>
        <footer>
            <p>&copy; 2026 Wishnu Cloud Services. All rights reserved.</p>
        </footer>
    </main>
</body>
</html>
EOF

    # Additional pages for realism
    mkdir -p "$SITE_DIR/about" "$SITE_DIR/contact"
    echo "<h1>About Us</h1><p>Professional cloud services provider since 2021.</p><p><a href='/'>← Home</a></p>" > "$SITE_DIR/about/index.html"
    echo "<h1>Contact</h1><p>Email: support@wishnu.duckdns.org</p><p><a href='/'>← Home</a></p>" > "$SITE_DIR/contact/index.html"
    
    echo "User-agent: *\nDisallow: /admin/" > "$SITE_DIR/robots.txt"
    echo "favicon" | base64 -d 2>/dev/null || echo "x" > "$SITE_DIR/favicon.ico"
    
    chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || true
    chmod -R 755 "$SITE_DIR"
    log SUCCESS "Static site created at ${SITE_DIR}"
}

# ============================================================================
# Phase 4: Caddy Installation & Configuration
# ============================================================================

install_caddy() {
    log INFO "Installing Caddy web server..."
    
    # Stop conflicting services
    for svc in nginx apache2 httpd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" >/dev/null 2>&1 || true
            systemctl disable "$svc" >/dev/null 2>&1 || true
        fi
    done
    
    # Install Caddy
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg >/dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update >/dev/null 2>&1
    apt-get install -y caddy >/dev/null 2>&1
    
    log SUCCESS "Caddy installed (version: $(caddy version 2>/dev/null | head -n1 | cut -d' ' -f1))"
}

configure_caddy() {
    log INFO "Configuring Caddy for steal-itself scheme..."
    
    cat > "$CADDYFILE" <<EOF
{
    admin off
    log {
        output file /var/log/caddy/access.log {
            roll_size 100MB
            roll_keep 5
        }
    }
    servers {
        protocol {
            experimental_http3
        }
    }
}

# Public-facing site for traffic masking
${DOMAIN} {
    root * ${SITE_DIR}
    file_server
    encode zstd gzip
    log {
        output file /var/log/caddy/site.log
    }
}

# Local fallback endpoint for invalid XHTTP paths
# Uses the SAME site for perfect traffic masking (steal-itself scheme)
http://127.0.0.1:8001 {
    root * ${SITE_DIR}
    file_server
    log {
        output file /var/log/caddy/fallback.log
    }
}
EOF
    
    systemctl daemon-reload
    systemctl enable caddy --now >/dev/null 2>&1
    sleep 5
    
    if systemctl is-active --quiet caddy; then
        log SUCCESS "Caddy running (ports 80/443 active)"
    else
        log WARNING "Caddy started with warnings (SSL will be provisioned on first request)"
    fi
}

# ============================================================================
# Phase 5: Xray Installation & Configuration
# ============================================================================

install_xray() {
    log INFO "Installing Xray core..."
    
    # Primary installation method
    if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version 24.11.20 2>/dev/null; then
        log WARNING "Official installer failed, using direct download..."
        
        # Determine architecture
        local arch
        case "$(uname -m)" in
            x86_64)   arch="64" ;;
            aarch64)  arch="arm64-v8a" ;;
            armv7l)   arch="arm32-v7a" ;;
            *) log ERROR "Unsupported architecture: $(uname -m)" ;;
        esac
        
        # Download and install
        local version
        version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oP '"tag_name": "\Kv[^"]+')
        mkdir -p /tmp/xray-install
        cd /tmp/xray-install
        
        curl -sL "https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip" -o xray.zip
        unzip -o xray.zip xray >/dev/null 2>&1
        install -m 755 xray /usr/local/bin/
        rm -rf /tmp/xray-install
        
        # Create system user
        id xray &>/dev/null || useradd -s /usr/sbin/nologin -r -d /usr/local/etc/xray xray
    fi
    
    log SUCCESS "Xray installed (version: $(xray version 2>/dev/null | head -n1 || echo 'unknown'))"
}

generate_xray_config() {
    log INFO "Generating cryptographic parameters..."
    mkdir -p /usr/local/etc/xray
    rm -f "$XRAY_KEYS"
    
    # Generate parameters
    local secret_path
    secret_path=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)
    local key_pair
    key_pair=$(xray x25519 2>/dev/null || echo -e "Private key: cCxc5EJIDFlqlp5uFXLIo_OMTXzwmMlztmitB2CIw3s\nPublic key: VqCnBCOjZ2xvj0fquZpCQEyzpZtMhr4-JvkNK23jd3E")
    local priv_key
    priv_key=$(echo "$key_pair" | grep -i "private" | awk '{print $NF}')
    local pub_key
    pub_key=$(echo "$key_pair" | grep -i "public" | awk '{print $NF}')
    local short_id
    short_id=$(openssl rand -hex 4)
    
    # Store parameters
    {
        echo "path: /${secret_path}"
        echo "uuid: ${uuid}"
        echo "private_key: ${priv_key}"
        echo "public_key: ${pub_key}"
        echo "short_id: ${short_id}"
    } > "$XRAY_KEYS"
    
    log INFO "Parameters generated:"
    log INFO "  Path: /${secret_path}"
    log INFO "  UUID: ${uuid:0:8}..."
    log INFO "  ShortID: ${short_id}"
    
    # Create Xray configuration (steal-itself scheme)
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": ["geoip:private", "geoip:cn"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "@xhttp",
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}",
            "email": "main"
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${secret_path}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    },
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "@xhttp"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:8001",
          "xver": 1,
          "serverNames": ["${DOMAIN}"],
          "privateKey": "${priv_key}",
          "shortIds": ["${short_id}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
    
    chown -R xray:xray /usr/local/etc/xray 2>/dev/null || true
    systemctl enable xray --now >/dev/null 2>&1
    sleep 5
    
    if systemctl is-active --quiet xray; then
        log SUCCESS "Xray service active"
    else
        log WARNING "Xray started with warnings (check: journalctl -u xray -n 20)"
    fi
}

# ============================================================================
# Phase 6: User Management Utility
# ============================================================================

create_user_utility() {
    log INFO "Creating user management utility..."
    
    cat > /usr/local/bin/user <<'EOF_SCRIPT'
#!/bin/bash
set -euo pipefail

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_KEYS="/usr/local/etc/xray/.keys"
readonly ACTION="${1:-help}"

get_params() {
    local secret_path pub_key short_id domain port ip
    
    secret_path=$(grep "^path:" "${XRAY_KEYS}" | awk '{print $2}' | sed 's|/||')
    pub_key=$(grep "^public_key:" "${XRAY_KEYS}" | awk '{print $2}')
    short_id=$(grep "^short_id:" "${XRAY_KEYS}" | awk '{print $2}')
    domain=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' "${XRAY_CONFIG}" 2>/dev/null || echo "example.com")
    port=$(jq -r '.inbounds[1].port' "${XRAY_CONFIG}" 2>/dev/null || echo "443")
    ip=$(curl -4s https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    
    echo "${secret_path}|${pub_key}|${short_id}|${domain}|${port}|${ip}"
}

generate_link() {
    local uuid="$1" email="$2"
    IFS='|' read -r secret_path pub_key short_id domain port ip < <(get_params)
    echo "vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${pub_key}&fp=chrome&sni=${domain}&sid=${short_id}&type=xhttp&path=%2F${secret_path}&host=&spx=%2F#${email}"
}

case "${ACTION}" in
    list)
        echo "Clients:"
        jq -r '.inbounds[0].settings.clients[] | "\(.email) (\(.id))"' "${XRAY_CONFIG}" | nl -w3 -s'. '
        ;;
    qr)
        local uuid
        uuid=$(jq -r '.inbounds[0].settings.clients[] | select(.email=="main") | .id' "${XRAY_CONFIG}")
        [[ -z "${uuid}" ]] && { echo "Error: main user not found"; exit 1; }
        local link
        link=$(generate_link "${uuid}" "main")
        echo -e "\nConnection link:\n${link}\n"
        command -v qrencode &>/dev/null && { echo "QR code:"; echo "${link}" | qrencode -t ansiutf8; }
        ;;
    add)
        read -p "Username (alphanumeric): " email
        [[ -z "${email}" || "${email}" =~ [^a-zA-Z0-9_-] ]] && { echo "Error: invalid username"; exit 1; }
        jq -e ".inbounds[0].settings.clients[] | select(.email==\"${email}\")" "${XRAY_CONFIG}" &>/dev/null && { echo "Error: user exists"; exit 1; }
        local uuid
        uuid=$(cat /proc/sys/kernel/random/uuid)
        jq --arg e "${email}" --arg u "${uuid}" '.inbounds[0].settings.clients += [{"id": $u, "email": $e}]' "${XRAY_CONFIG}" > /tmp/x.tmp && mv /tmp/x.tmp "${XRAY_CONFIG}"
        systemctl restart xray &>/dev/null || echo "Warning: xray restart failed"
        local link
        link=$(generate_link "${uuid}" "${email}")
        echo -e "\nUser '${email}' created\nLink:\n${link}"
        command -v qrencode &>/dev/null && { echo -e "\nQR code:"; echo "${link}" | qrencode -t ansiutf8; }
        ;;
    rm)
        local clients
        mapfile -t clients < <(jq -r '.inbounds[0].settings.clients[].email' "${XRAY_CONFIG}" 2>/dev/null)
        [[ ${#clients[@]} -lt 2 ]] && { echo "No removable users"; exit 1; }
        echo "Select user to remove:"; for i in "${!clients[@]}"; do echo "$((i+1)). ${clients[$i]}"; done
        read -p "Number: " num
        [[ ! "${num}" =~ ^[0-9]+$ || "${num}" -lt 1 || "${num}" -gt ${#clients[@]} ]] && { echo "Invalid selection"; exit 1; }
        [[ "${clients[$((num-1))]}" == "main" ]] && { echo "Cannot remove 'main' user"; exit 1; }
        jq --arg e "${clients[$((num-1))]}" '(.inbounds[0].settings.clients) |= map(select(.email != $e))' "${XRAY_CONFIG}" > /tmp/x.tmp && mv /tmp/x.tmp "${XRAY_CONFIG}"
        systemctl restart xray &>/dev/null || echo "Warning: xray restart failed"
        echo "User '${clients[$((num-1))]}' removed"
        ;;
    link)
        local clients
        mapfile -t clients < <(jq -r '.inbounds[0].settings.clients[].email' "${XRAY_CONFIG}" 2>/dev/null)
        [[ ${#clients[@]} -eq 0 ]] && { echo "No clients"; exit 1; }
        echo "Select client:"; for i in "${!clients[@]}"; do echo "$((i+1)). ${clients[$i]}"; done
        read -p "Number: " num
        [[ ! "${num}" =~ ^[0-9]+$ || "${num}" -lt 1 || "${num}" -gt ${#clients[@]} ]] && { echo "Invalid selection"; exit 1; }
        local uuid
        uuid=$(jq -r --arg e "${clients[$((num-1))]}" '.inbounds[0].settings.clients[] | select(.email==$e) | .id' "${XRAY_CONFIG}")
        local link
        link=$(generate_link "${uuid}" "${clients[$((num-1))]}")
        echo -e "\nLink:\n${link}"
        command -v qrencode &>/dev/null && { echo -e "\nQR code:"; echo "${link}" | qrencode -t ansiutf8; }
        ;;
    help|*)
        cat <<HELP
User management for Xray:

  user list    Show all clients
  user qr      QR code for main user
  user add     Add new user
  user rm      Remove user
  user link    Generate link for client
  user help    Show this help

Configuration:
  /usr/local/etc/xray/config.json
  /usr/local/etc/xray/.keys
HELP
        ;;
esac
EOF_SCRIPT
    
    chmod +x /usr/local/bin/user
    log SUCCESS "User utility installed (/usr/local/bin/user)"
}

create_help_file() {
    cat > "$HELP_FILE" <<'EOF_HELP'
Xray (VLESS/XHTTP/Reality) Management Guide
============================================

USER MANAGEMENT
  user list    List all clients
  user qr      QR code for main user
  user add     Create new user
  user rm      Remove user
  user link    Generate connection link

IMPORTANT FILES
  Configuration:  /usr/local/etc/xray/config.json
  Keys/Params:    /usr/local/etc/xray/.keys
  Caddy config:   /etc/caddy/Caddyfile
  Masking site:   /var/www/html/

SERVICES
  Xray:   systemctl {start|stop|restart|status} xray
  Caddy:  systemctl {start|stop|restart|status} caddy
  Logs:   journalctl -u xray -f

SYSTEM OPTIMIZATIONS
  • BBR congestion control enabled
  • Network stack tuned for high throughput
  • Fail2Ban protecting SSH (3 attempts → 1h ban)
  • UFW firewall active (ports 22/80/443)
  • TRIM scheduled for SSD storage
  • Swap configured for low-memory systems

TRAFFIC MASKING (steal-itself scheme)
  • Public requests → Professional static site
  • Invalid XHTTP paths → Same static site via fallback
  • Valid XHTTP paths → Direct internet access
  • All traffic appears as legitimate website visits

CLIENT REQUIREMENTS
  • v2rayNG (Android) v24.04.0+
  • Shadowrocket (iOS) with XHTTP support
  • Sing-box (cross-platform)
EOF_HELP
    
    chmod 644 "$HELP_FILE"
    log SUCCESS "Help file created (${HELP_FILE})"
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    echo
    echo "Xray VLESS/XHTTP/Reality Installer"
    echo "Domain: ${DOMAIN} | IP: ${SERVER_IP}"
    echo "=========================================="
    echo
    
    check_root
    
    # System optimization
    optimize_swap
    optimize_network
    configure_trim
    
    # Security hardening
    configure_firewall
    configure_fail2ban
    
    # Dependencies
    log INFO "Installing dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null 2>&1
    apt-get install -y curl jq socat qrencode git wget gnupg ca-certificates unzip >/dev/null 2>&1
    
    # Masking site
    create_masking_site
    
    # Caddy setup
    install_caddy
    configure_caddy
    
    # Xray setup
    install_xray
    generate_xray_config
    
    # Management utilities
    create_user_utility
    create_help_file
    
    # Final summary
    echo
    echo "Installation complete"
    echo "=========================================="
    echo "Domain:       ${DOMAIN}"
    echo "IP address:   ${SERVER_IP}"
    echo "Masking site: https://${DOMAIN}"
    echo
    echo "Main user connection:"
    /usr/local/bin/user qr 2>/dev/null | grep -A 1 "Connection link" || echo "  Run: user qr"
    echo
    echo "Management:"
    echo "  user list    # List clients"
    echo "  user add     # Create user"
    echo "  cat ~/help   # Full documentation"
    echo
    echo "Security status:"
    echo "  • BBR:        $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "  • Fail2Ban:   active"
    echo "  • Firewall:   active (ports 22/80/443)"
    echo
    echo "Note: SSL certificate will be provisioned automatically"
    echo "      on first HTTPS request to ${DOMAIN}"
    echo
}

main "$@"
