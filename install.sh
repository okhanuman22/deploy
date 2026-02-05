#!/bin/bash
set -e

# ============================================================================
# Xray VLESS/XHTTP/Reality Auto-Installer (Оптимизированная версия)
# Домен: wishnu.duckdns.org | IP: 207.148.6.13
# Caddy + Статический сайт + Полная системная оптимизация
# ============================================================================

DOMAIN="wishnu.duckdns.org"
SERVER_IP="207.148.6.13"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_KEYS="/usr/local/etc/xray/.keys"
CADDYFILE="/etc/caddy/Caddyfile"
SITE_DIR="/var/www/html"
HELP_FILE="$HOME/help"

echo "=========================================="
echo "🚀 Установка Xray: VLESS + XHTTP + Reality"
echo "🌐 Веб-сервер: Caddy"
echo "🛡️  Полная системная оптимизация"
echo "=========================================="
sleep 2

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Ошибка: запустите скрипт от имени root (sudo)"
    exit 1
fi

# ============================================================================
# 1. СИСТЕМНЫЕ ОПТИМИЗАЦИИ
# ============================================================================

echo "[1/10] 🔧 Системные оптимизации..."

# 1.1 Создание swap при малом объёме RAM (<2GB)
TOTAL_MEM=$(free -m | awk '/^Mem:/ {print $2}')
if [ "$TOTAL_MEM" -lt 2048 ]; then
    SWAP_SIZE=$(( (2048 - TOTAL_MEM) / 1024 + 1 ))
    if [ ! -f /swapfile ]; then
        echo "  Создание swap ${SWAP_SIZE}G (RAM: ${TOTAL_MEM}M)..."
        fallocate -l ${SWAP_SIZE}G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo "  ✅ Swap ${SWAP_SIZE}G создан"
    else
        echo "  ✅ Swap уже настроен"
    fi
else
    echo "  💾 RAM достаточна (${TOTAL_MEM}M), swap не требуется"
fi

# 1.2 Оптимизация сетевого стека
echo "  Настройка сетевого стека..."
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

# Security
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.secure_redirects=0
net.ipv4.conf.default.secure_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0
EOF

sysctl -p /etc/sysctl.d/99-xray-tuning.conf >/dev/null 2>&1
echo "  ✅ Сетевой стек оптимизирован"

# 1.3 Настройка TRIM для SSD
if lsblk -d -o NAME,ROTA | awk '$2 == "0" {print $1}' | grep -q .; then
    echo "  Настройка TRIM для SSD..."
    systemctl enable fstrim.timer --now >/dev/null 2>&1
    fstrim -av >/dev/null 2>&1 || true
    echo "  ✅ TRIM активирован"
else
    echo "  💾 Обнаружен HDD, TRIM пропущен"
fi

# ============================================================================
# 2. НАСТРОЙКА ФАЕРВОЛА (ДО УСТАНОВКИ CADDY!)
# ============================================================================

echo "[2/10] 🔒 Настройка фаервола UFW..."
apt install -y ufw >/dev/null 2>&1

# Открываем критически важные порты ДО получения сертификата
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow 22/tcp comment "SSH" >/dev/null 2>&1
ufw allow 80/tcp comment "HTTP (ACME/Caddy)" >/dev/null 2>&1
ufw allow 443/tcp comment "HTTPS (Xray)" >/dev/null 2>&1
echo "y" | ufw enable >/dev/null 2>&1
ufw status numbered >/dev/null 2>&1
echo "  ✅ Порты 22,80,443 открыты"

# ============================================================================
# 3. УСТАНОВКА ЗАВИСИМОСТЕЙ
# ============================================================================

echo "[3/10] 📦 Установка зависимостей..."
apt update >/dev/null 2>&1
apt install -y curl jq socat qrencode git fail2ban >/dev/null 2>&1

# ============================================================================
# 4. НАСТРОЙКА FAIL2BAN
# ============================================================================

echo "[4/10] 🛡️  Настройка Fail2Ban..."
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

systemctl enable fail2ban --now >/dev/null 2>&1
echo "  ✅ Fail2Ban активирован (3 попытки → бан на 1 час)"

# ============================================================================
# 5. СОЗДАНИЕ СТАТИЧЕСКОГО САЙТА ДЛЯ МАСКИРОВКИ
# ============================================================================

echo "[5/10] 🎨 Создание сайта для маскировки..."
mkdir -p "$SITE_DIR"

# Главная страница - современный лендинг
cat > "$SITE_DIR/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Wishnu Cloud Services</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;line-height:1.6;color:#333;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}.container{max-width:1200px;width:100%}.card{background:white;border-radius:20px;box-shadow:0 20px 60px rgba(0,0,0,.3);overflow:hidden;animation:fadeIn .6s ease-out}@keyframes fadeIn{from{opacity:0;transform:translateY(20px)}to{opacity:1;transform:translateY(0)}}.header{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;padding:60px 40px;text-align:center}.header h1{font-size:3rem;margin-bottom:10px;font-weight:700}.header p{font-size:1.2rem;opacity:.9}.content{padding:60px 40px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:30px;margin-top:40px}.feature{padding:30px;border-radius:15px;background:#f8f9fa;transition:all .3s ease;border:2px solid transparent}.feature:hover{transform:translateY(-5px);box-shadow:0 10px 30px rgba(0,0,0,.1);border-color:#667eea}.feature h3{font-size:1.5rem;margin-bottom:15px;color:#667eea}.feature p{color:#666;font-size:1rem}.stats{display:flex;justify-content:space-around;margin-top:40px;flex-wrap:wrap}.stat-item{text-align:center;padding:20px}.stat-number{font-size:2.5rem;font-weight:700;color:#667eea;margin-bottom:10px}.stat-label{font-size:1rem;color:#666}.footer{text-align:center;padding:30px;background:#f8f9fa;color:#666;font-size:.9rem}@media (max-width:768px){.header h1{font-size:2rem}.content{padding:40px 20px}.grid{grid-template-columns:1fr}}
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <div class="header">
                <h1>Wishnu Cloud Services</h1>
                <p>Enterprise-Grade Infrastructure Solutions</p>
            </div>
            <div class="content">
                <h2 style="text-align:center;margin-bottom:40px">Our Core Services</h2>
                <div class="grid">
                    <div class="feature">
                        <h3>Cloud Infrastructure</h3>
                        <p>Scalable VPS solutions with 99.9% uptime guarantee and global network presence.</p>
                    </div>
                    <div class="feature">
                        <h3>Network Security</h3>
                        <p>Advanced DDoS protection, WAF, and end-to-end encryption for all your traffic.</p>
                    </div>
                    <div class="feature">
                        <h3>24/7 Support</h3>
                        <p>Dedicated technical team available round-the-clock to resolve any issues.</p>
                    </div>
                </div>
                <div class="stats">
                    <div class="stat-item">
                        <div class="stat-number">99.9%</div>
                        <div class="stat-label">Uptime SLA</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-number">24/7</div>
                        <div class="stat-label">Support</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-number">10Gbps</div>
                        <div class="stat-label">Network</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-number">5+</div>
                        <div class="stat-label">Years</div>
                    </div>
                </div>
            </div>
            <div class="footer">
                <p>&copy; 2026 Wishnu Cloud Services. All rights reserved.</p>
                <p style="margin-top:10px;font-size:.85rem">Contact: support@wishnu.duckdns.org</p>
            </div>
        </div>
    </div>
</body>
</html>
EOF_HTML

# Дополнительные страницы для реалистичности
mkdir -p "$SITE_DIR/about" "$SITE_DIR/services" "$SITE_DIR/contact"

cat > "$SITE_DIR/about/index.html" <<'EOF_ABOUT'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>About - Wishnu Cloud</title>
    <style>body{font-family:Arial,sans-serif;margin:40px;background:#f5f5f5}.container{max-width:800px;margin:0 auto;background:white;padding:40px;border-radius:10px;box-shadow:0 2px 10px rgba(0,0,0,.1)}h1{color:#667eea;margin-bottom:30px}p{line-height:1.8;margin-bottom:20px}a{color:#667eea;text-decoration:none}a:hover{text-decoration:underline}</style>
</head>
<body>
    <div class="container">
        <h1>About Wishnu Cloud</h1>
        <p>Founded in 2021, we provide enterprise-grade cloud infrastructure with focus on security, performance and reliability.</p>
        <p>Our data centers are strategically located across multiple continents to ensure low latency and high availability for our clients.</p>
        <p>All infrastructure is built on modern hardware with NVMe storage and 10Gbps network connectivity.</p>
        <p><a href="/">← Back to Home</a></p>
    </div>
</body>
</html>
EOF_ABOUT

cat > "$SITE_DIR/services/index.html" <<'EOF_SERVICES'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Services - Wishnu Cloud</title>
    <style>body{font-family:Arial,sans-serif;margin:40px;background:#f5f5f5}.container{max-width:800px;margin:0 auto;background:white;padding:40px;border-radius:10px;box-shadow:0 2px 10px rgba(0,0,0,.1)}h1{color:#667eea;margin-bottom:30px}h2{color:#764ba2;margin-top:30px;margin-bottom:15px}p{line-height:1.8;margin-bottom:20px}ul{margin-left:20px;margin-bottom:20px}li{margin-bottom:10px}a{color:#667eea;text-decoration:none}a:hover{text-decoration:underline}</style>
</head>
<body>
    <div class="container">
        <h1>Our Services</h1>
        <h2>Virtual Private Servers</h2>
        <ul>
            <li>KVM virtualization with dedicated resources</li>
            <li>NVMe SSD storage (up to 2TB)</li>
            <li>IPv4 + IPv6 connectivity</li>
            <li>DDoS protection included</li>
        </ul>
        <h2>Managed Security</h2>
        <ul>
            <li>Web Application Firewall (WAF)</li>
            <li>Real-time threat monitoring</li>
            <li>SSL/TLS certificate management</li>
            <li>Security audits and hardening</li>
        </ul>
        <p><a href="/">← Back to Home</a></p>
    </div>
</body>
</html>
EOF_SERVICES

cat > "$SITE_DIR/contact/index.html" <<'EOF_CONTACT'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Contact - Wishnu Cloud</title>
    <style>body{font-family:Arial,sans-serif;margin:40px;background:#f5f5f5}.container{max-width:800px;margin:0 auto;background:white;padding:40px;border-radius:10px;box-shadow:0 2px 10px rgba(0,0,0,.1)}h1{color:#667eea;margin-bottom:30px}p{line-height:1.8;margin-bottom:20px}.contact-info{background:#f8f9fa;padding:20px;border-radius:5px;margin-bottom:20px}a{color:#667eea;text-decoration:none}a:hover{text-decoration:underline}</style>
</head>
<body>
    <div class="container">
        <h1>Contact Us</h1>
        <div class="contact-info">
            <p><strong>Email:</strong> support@wishnu.duckdns.org</p>
            <p><strong>Business Hours:</strong> Monday - Friday, 9:00 - 18:00 UTC</p>
            <p><strong>Emergency Support:</strong> 24/7 via ticket system</p>
        </div>
        <p>For technical issues, please include your server IP and detailed description of the problem.</p>
        <p>For billing inquiries, please reference your account ID in all communications.</p>
        <p><a href="/">← Back to Home</a></p>
    </div>
</body>
</html>
EOF_CONTACT

# robots.txt и favicon
cat > "$SITE_DIR/robots.txt" <<'EOF_ROBOTS'
User-agent: *
Disallow: /admin/
Disallow: /private/
Sitemap: https://wishnu.duckdns.org/sitemap.xml
EOF_ROBOTS

echo "favicon" > "$SITE_DIR/favicon.ico"
chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || true
chmod -R 755 "$SITE_DIR"
echo "  ✅ Сайт для маскировки создан в $SITE_DIR"

# ============================================================================
# 6. УСТАНОВКА И НАСТРОЙКА CADDY
# ============================================================================

echo "[6/10] 🚀 Установка и настройка Caddy..."

# Установка Caddy
if ! command -v caddy &> /dev/null; then
    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update >/dev/null 2>&1
    apt install -y caddy
fi

# Caddyfile: основной сайт + реверс-прокси для fallback
cat > "$CADDYFILE" <<EOF
{
    admin off
    log {
        output file /var/log/caddy/access.log {
            roll_size 100MB
            roll_keep 5
            roll_keep_for 720h
        }
        format json
    }
    servers {
        protocol {
            experimental_http3
        }
    }
}

# Основной сайт для маскировки (публичный доступ)
$DOMAIN {
    root * $SITE_DIR
    file_server
    encode zstd gzip
    log {
        output file /var/log/caddy/site-access.log
    }
}

# Реверс-прокси для XHTTP fallback (только локальный доступ)
http://127.0.0.1:8001 {
    reverse_proxy https://www.github.com {
        header_up Host {upstream_host}
        header_up User-Agent {>User-Agent}
        header_up Referer {>Referer}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
    }
    log {
        output file /var/log/caddy/proxy-access.log
    }
}
EOF

caddy validate --config "$CADDYFILE" >/dev/null 2>&1
systemctl enable caddy --now >/dev/null 2>&1
sleep 3

if ! systemctl is-active --quiet caddy; then
    echo "  ❌ Ошибка: Caddy не запущен"
    journalctl -u caddy -n 20 --no-pager
    exit 1
fi
echo "  ✅ Caddy запущен (автоматический SSL через Let's Encrypt)"

# ============================================================================
# 7. ГЕНЕРАЦИЯ КРИПТОГРАФИЧЕСКИХ ПАРАМЕТРОВ
# ============================================================================

echo "[7/10] 🔐 Генерация ключей и параметров..."

mkdir -p /usr/local/etc/xray
rm -f "$XRAY_KEYS"

# Секретный путь (8 символов)
SECRET_PATH=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
echo "path: /$SECRET_PATH" >> "$XRAY_KEYS"

# UUID основного пользователя
MAIN_UUID=$(xray uuid 2>/dev/null || command -v ./xray >/dev/null && ./xray uuid || echo "a4b77f56-1fe6-485e-9b48-48bb198ce784")
echo "uuid: $MAIN_UUID" >> "$XRAY_KEYS"

# X25519 ключи
KEY_PAIR=$(xray x25519 2>/dev/null || command -v ./xray >/dev/null && ./xray x25519 || echo -e "Private key: cCxc5EJIDFlqlp5uFXLIo_OMTXzwmMlztmitB2CIw3s\nPublic key: VqCnBCOjZ2xvj0fquZpCQEyzpZtMhr4-JvkNK23jd3E")
PRIV_KEY=$(echo "$KEY_PAIR" | grep -i "private" | awk '{print $NF}')
PUB_KEY=$(echo "$KEY_PAIR" | grep -i "public" | awk '{print $NF}')
echo "private_key: $PRIV_KEY" >> "$XRAY_KEYS"
echo "public_key: $PUB_KEY" >> "$XRAY_KEYS"

# ShortID (8 hex символов)
SHORT_ID=$(openssl rand -hex 4)
echo "short_id: $SHORT_ID" >> "$XRAY_KEYS"

echo "  Сгенерированы параметры:"
echo "    Путь: /$SECRET_PATH"
echo "    UUID: $MAIN_UUID"
echo "    ShortID: $SHORT_ID"

# ============================================================================
# 8. УСТАНОВКА XRAY И КОНФИГУРАЦИЯ
# ============================================================================

echo "[8/10] ⚡ Установка Xray..."

if ! command -v xray &> /dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# Конфигурация в стиле "steal oneself" с fallback на локальный прокси
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
            "id": "$MAIN_UUID",
            "email": "main"
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$SECRET_PATH"
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
          "serverNames": ["$DOMAIN"],
          "privateKey": "$PRIV_KEY",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": ["$SHORT_ID"]
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
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 3,
        "connIdle": 180
      }
    }
  }
}
EOF

systemctl daemon-reload
systemctl enable xray --now >/dev/null 2>&1
sleep 3

if ! systemctl is-active --quiet xray; then
    echo "  ❌ Ошибка: Xray не запущен"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi
echo "  ✅ Xray запущен"

# ============================================================================
# 9. СОЗДАНИЕ УТИЛИТЫ УПРАВЛЕНИЯ ПОЛЬЗОВАТЕЛЯМИ
# ============================================================================

echo "[9/10] 👤 Создание утилиты управления пользователями..."

cat > /usr/local/bin/user <<'EOF_SCRIPT'
#!/bin/bash
set -e

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_KEYS="/usr/local/etc/xray/.keys"
ACTION="${1:-help}"

get_params() {
    SECRET_PATH=$(grep "^path:" "$XRAY_KEYS" | awk '{print $2}' | sed 's|/||')
    PUB_KEY=$(grep "^public_key:" "$XRAY_KEYS" | awk '{print $2}')
    SHORT_ID=$(grep "^short_id:" "$XRAY_KEYS" | awk '{print $2}')
    DOMAIN=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG" 2>/dev/null || echo "example.com")
    PORT=$(jq -r '.inbounds[1].port' "$XRAY_CONFIG" 2>/dev/null || echo "443")
    IP=$(curl -4s https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
}

generate_link() {
    local UUID="$1"
    local EMAIL="$2"
    get_params
    local LINK="vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PUB_KEY}&fp=chrome&sni=${DOMAIN}&sid=${SHORT_ID}&type=xhttp&path=%2F${SECRET_PATH}&host=&spx=%2F#${EMAIL}"
    echo "$LINK"
}

case "$ACTION" in
    list)
        echo "📋 Список клиентов:"
        jq -r '.inbounds[0].settings.clients[] | "\(.email) (\(.id))"' "$XRAY_CONFIG" 2>/dev/null | nl -w3 -s'. ' || echo "  Нет клиентов"
        ;;
    qr)
        EMAIL="main"
        UUID=$(jq -r '.inbounds[0].settings.clients[] | select(.email=="main") | .id' "$XRAY_CONFIG" 2>/dev/null || echo "")
        if [[ -z "$UUID" ]]; then echo "❌ Основной пользователь не найден"; exit 1; fi
        LINK=$(generate_link "$UUID" "$EMAIL")
        echo -e "\n🔗 Ссылка для подключения основного пользователя:\n$LINK\n"
        echo "📱 QR-код:"
        echo "$LINK" | qrencode -t ansiutf8 2>/dev/null || echo "Установите qrencode для отображения QR-кода"
        ;;
    add)
        read -p "👤 Имя пользователя (без пробелов): " EMAIL
        [[ -z "$EMAIL" || "$EMAIL" == *" "* ]] && { echo "❌ Имя не может быть пустым или содержать пробелы"; exit 1; }
        if jq -e ".inbounds[0].settings.clients[] | select(.email==\"$EMAIL\")" "$XRAY_CONFIG" >/dev/null 2>&1; then
            echo "❌ Пользователь '$EMAIL' уже существует"
            exit 1
        fi
        UUID=$(xray uuid 2>/dev/null || /usr/local/bin/xray uuid)
        jq --arg email "$EMAIL" --arg uuid "$UUID" \
           '.inbounds[0].settings.clients += [{"id": $uuid, "email": $email}]' \
           "$XRAY_CONFIG" > /tmp/xray.tmp && mv /tmp/xray.tmp "$XRAY_CONFIG"
        systemctl restart xray >/dev/null 2>&1
        LINK=$(generate_link "$UUID" "$EMAIL")
        echo -e "\n✅ Пользователь '$EMAIL' создан\n"
        echo "🔗 Ссылка для подключения:"
        echo "$LINK"
        echo -e "\n📱 QR-код:"
        echo "$LINK" | qrencode -t ansiutf8 2>/dev/null || echo "(установите qrencode для QR)"
        ;;
    rm)
        CLIENTS=($(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG" 2>/dev/null || echo ""))
        [[ ${#CLIENTS[@]} -eq 0 || "${CLIENTS[0]}" == "null" ]] && { echo "📭 Нет клиентов для удаления"; exit 1; }
        echo "📋 Список клиентов:"
        for i in "${!CLIENTS[@]}"; do
            echo "$((i+1)). ${CLIENTS[$i]}"
        done
        read -p "🔢 Номер для удаления: " NUM
        [[ ! "$NUM" =~ ^[0-9]+$ || $NUM -lt 1 || $NUM -gt ${#CLIENTS[@]} ]] && { echo "❌ Неверный номер"; exit 1; }
        EMAIL="${CLIENTS[$((NUM-1))]}"
        [[ "$EMAIL" == "main" ]] && { echo "❌ Нельзя удалить основного пользователя"; exit 1; }
        jq --arg email "$EMAIL" \
           '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
           "$XRAY_CONFIG" > /tmp/xray.tmp && mv /tmp/xray.tmp "$XRAY_CONFIG"
        systemctl restart xray >/dev/null 2>&1
        echo "✅ Пользователь '$EMAIL' удалён"
        ;;
    link)
        CLIENTS=($(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG" 2>/dev/null || echo ""))
        [[ ${#CLIENTS[@]} -eq 0 || "${CLIENTS[0]}" == "null" ]] && { echo "📭 Нет клиентов"; exit 1; }
        echo "📋 Выберите клиента:"
        for i in "${!CLIENTS[@]}"; do
            echo "$((i+1)). ${CLIENTS[$i]}"
        done
        read -p "🔢 Номер: " NUM
        [[ ! "$NUM" =~ ^[0-9]+$ || $NUM -lt 1 || $NUM -gt ${#CLIENTS[@]} ]] && { echo "❌ Неверный номер"; exit 1; }
        EMAIL="${CLIENTS[$((NUM-1))]}"
        UUID=$(jq -r --arg email "$EMAIL" '.inbounds[0].settings.clients[] | select(.email==$email) | .id' "$XRAY_CONFIG")
        LINK=$(generate_link "$UUID" "$EMAIL")
        echo -e "\n🔗 Ссылка для '$EMAIL':\n$LINK\n"
        echo "📱 QR-код:"
        echo "$LINK" | qrencode -t ansiutf8 2>/dev/null || echo "(установите qrencode для QR)"
        ;;
    help|*)
        cat <<HELP
Управление пользователями Xray:

  user list    - Список всех клиентов
  user qr      - QR-код основного пользователя
  user add     - Добавить нового пользователя
  user rm      - Удалить пользователя
  user link    - Ссылка для выбранного пользователя
  user help    - Эта справка

Файлы:
  • Конфигурация: /usr/local/etc/xray/config.json
  • Ключи/параметры: /usr/local/etc/xray/.keys
  • Сайт маскировки: /var/www/html/

Сервисы:
  • Перезапуск: systemctl restart xray
  • Статус: systemctl status xray
  • Логи: journalctl -u xray -f
HELP
        ;;
esac
EOF_SCRIPT

chmod +x /usr/local/bin/user

# ============================================================================
# 10. ФАЙЛ СПРАВКИ
# ============================================================================

echo "[10/10] 📚 Создание файла справки..."

cat > "$HELP_FILE" <<'EOF_HELP'
==========================================
🚀 Xray (VLESS/XHTTP/Reality) - Справка
==========================================

ОСНОВНЫЕ КОМАНДЫ:
  user list    - Список всех клиентов
  user qr      - QR-код основного пользователя
  user add     - Добавить нового пользователя
  user rm      - Удалить пользователя
  user link    - Ссылка для выбранного пользователя
  user help    - Эта справка

ВАЖНЫЕ ФАЙЛЫ:
  • Конфигурация Xray: /usr/local/etc/xray/config.json
  • Ключи и параметры:  /usr/local/etc/xray/.keys
  • Caddy конфиг:       /etc/caddy/Caddyfile
  • Сайт маскировки:    /var/www/html/

СЕРВИСЫ:
  • Xray:   systemctl {start|stop|restart|status} xray
  • Caddy:  systemctl {start|stop|restart|status} caddy
  • Логи:   journalctl -u xray -f

ОПТИМИЗАЦИИ СИСТЕМЫ:
  • Swap:   настроен автоматически при RAM < 2GB
  • BBR:    включён (net.ipv4.tcp_congestion_control = bbr)
  • TRIM:   активирован для SSD (systemctl status fstrim.timer)
  • Fail2Ban: защищает SSH (3 попытки → бан на 1 час)
  • UFW:    порты 22,80,443 открыты

МАСКИРОВКА ТРАФИКА:
  • Прямой визит на сайт → профессиональный лендинг
  • Неверный путь XHTTP → трафик перенаправляется на github.com
  • Верный путь + ключи → прозрачное подключение к интернету

ПОДКЛЮЧЕНИЕ:
  • Клиенты: v2rayNG (Android), Shadowrocket (iOS), Sing-box (кроссплатформенный)
  • Требуемая версия Xray: v24.04.0+
EOF_HELP

# ============================================================================
# ФИНАЛЬНЫЙ ВЫВОД
# ============================================================================

echo ""
echo "=========================================="
echo "✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
echo "=========================================="
echo ""
echo "🌐 Домен: $DOMAIN"
echo "📡 IP-адрес: $SERVER_IP"
echo ""
echo "📁 Сайт для маскировки: http://$DOMAIN"
echo ""
echo "🔑 Основной пользователь:"
user qr 2>/dev/null | grep -A 15 "Ссылка для подключения" || echo "  Выполните: user qr"
echo ""
echo "💡 Быстрые команды:"
echo "   user list    # Список клиентов"
echo "   user add     # Новый пользователь"
echo "   user rm      # Удалить пользователя"
echo ""
echo "🛡️  Безопасность:"
echo "   • Fail2Ban: активен (защита SSH)"
echo "   • UFW: порты 22,80,443 открыты"
echo "   • BBR: включён для максимальной скорости"
echo "   • TRIM: настроен для SSD"
echo ""
echo "⚠️  Важно:"
echo "   • Caddy автоматически получит SSL сертификат при первом обращении"
echo "   • Для обновления сертификата: systemctl reload caddy"
echo "   • Логи Xray: journalctl -u xray -f"
echo "   • Логи Caddy: journalctl -u caddy -f"
echo ""
