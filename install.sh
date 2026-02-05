#!/bin/bash
set -e

# ============================================================================
# Xray VLESS/XHTTP/Reality Auto-Installer
# Домен: wishnu.duckdns.org | IP: 207.148.6.13
# Caddy + Статический сайт для маскировки
# ============================================================================

DOMAIN="wishnu.duckdns.org"
SERVER_IP="207.148.6.13"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_KEYS="/usr/local/etc/xray/.keys"
CADDYFILE="/etc/caddy/Caddyfile"
SITE_DIR="/var/www/html"
HELP_FILE="$HOME/xray-help.txt"

echo "=========================================="
echo "Установка Xray: VLESS + XHTTP + Reality"
echo "Веб-сервер: Caddy"
echo "Домен: $DOMAIN"
echo "=========================================="
sleep 2

# Проверка прав суперпользователя
if [ "$EUID" -ne 0 ]; then 
    echo "Ошибка: запустите скрипт от имени root (sudo)"
    exit 1
fi

# 1. Обновление системы и установка зависимостей
echo "[1/8] Установка зависимостей..."
apt update >/dev/null 2>&1
apt install -y curl jq socat qrencode dnsutils git >/dev/null 2>&1

# 2. Установка Caddy
echo "[2/8] Установка Caddy..."
if ! command -v caddy &> /dev/null; then
    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update >/dev/null 2>&1
    apt install -y caddy
fi

# 3. Создание статического сайта для маскировки
echo "[3/8] Создание статического сайта для маскировки..."
mkdir -p "$SITE_DIR"

# Генерация современного сайта-заглушки
cat > "$SITE_DIR/index.html" <<'EOF_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Wishnu Services</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
        }

        .container {
            max-width: 1200px;
            width: 100%;
        }

        .card {
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
            overflow: hidden;
            animation: fadeIn 0.6s ease-out;
        }

        @keyframes fadeIn {
            from {
                opacity: 0;
                transform: translateY(20px);
            }
            to {
                opacity: 1;
                transform: translateY(0);
            }
        }

        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 60px 40px;
            text-align: center;
        }

        .header h1 {
            font-size: 3rem;
            margin-bottom: 10px;
            font-weight: 700;
        }

        .header p {
            font-size: 1.2rem;
            opacity: 0.9;
        }

        .content {
            padding: 60px 40px;
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 30px;
            margin-top: 40px;
        }

        .feature {
            padding: 30px;
            border-radius: 15px;
            background: #f8f9fa;
            transition: all 0.3s ease;
            border: 2px solid transparent;
        }

        .feature:hover {
            transform: translateY(-5px);
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.1);
            border-color: #667eea;
        }

        .feature h3 {
            font-size: 1.5rem;
            margin-bottom: 15px;
            color: #667eea;
        }

        .feature p {
            color: #666;
            font-size: 1rem;
        }

        .stats {
            display: flex;
            justify-content: space-around;
            margin-top: 40px;
            flex-wrap: wrap;
        }

        .stat-item {
            text-align: center;
            padding: 20px;
        }

        .stat-number {
            font-size: 2.5rem;
            font-weight: 700;
            color: #667eea;
            margin-bottom: 10px;
        }

        .stat-label {
            font-size: 1rem;
            color: #666;
        }

        .footer {
            text-align: center;
            padding: 30px;
            background: #f8f9fa;
            color: #666;
            font-size: 0.9rem;
        }

        @media (max-width: 768px) {
            .header h1 {
                font-size: 2rem;
            }
            .content {
                padding: 40px 20px;
            }
            .grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="card">
            <div class="header">
                <h1>Wishnu Services</h1>
                <p>Professional Solutions for Your Business</p>
            </div>
            <div class="content">
                <h2 style="text-align: center; margin-bottom: 40px;">Our Services</h2>
                
                <div class="grid">
                    <div class="feature">
                        <h3>Cloud Infrastructure</h3>
                        <p>Scalable and reliable cloud solutions tailored to your business needs. High performance, low latency.</p>
                    </div>
                    <div class="feature">
                        <h3>Network Security</h3>
                        <p>Enterprise-grade security protocols and encryption to protect your data and communications.</p>
                    </div>
                    <div class="feature">
                        <h3>Technical Support</h3>
                        <p>24/7 professional support team ready to assist you with any technical challenges.</p>
                    </div>
                </div>

                <div class="stats">
                    <div class="stat-item">
                        <div class="stat-number">99.9%</div>
                        <div class="stat-label">Uptime</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-number">24/7</div>
                        <div class="stat-label">Support</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-number">1000+</div>
                        <div class="stat-label">Clients</div>
                    </div>
                    <div class="stat-item">
                        <div class="stat-number">5+</div>
                        <div class="stat-label">Years</div>
                    </div>
                </div>
            </div>
            <div class="footer">
                <p>&copy; 2026 Wishnu Services. All rights reserved.</p>
                <p style="margin-top: 10px; font-size: 0.85rem;">Contact: support@wishnu.duckdns.org</p>
            </div>
        </div>
    </div>
</body>
</html>
EOF_HTML

# Добавление нескольких дополнительных страниц для реалистичности
mkdir -p "$SITE_DIR/about" "$SITE_DIR/services" "$SITE_DIR/contact"

cat > "$SITE_DIR/about/index.html" <<'EOF_ABOUT'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>About Us - Wishnu Services</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #667eea; margin-bottom: 30px; }
        p { line-height: 1.8; margin-bottom: 20px; }
        a { color: #667eea; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <h1>About Wishnu Services</h1>
        <p>Founded in 2021, Wishnu Services has been providing cutting-edge technology solutions to businesses worldwide.</p>
        <p>Our team of experienced professionals is dedicated to delivering reliable, secure, and scalable infrastructure solutions.</p>
        <p>We pride ourselves on our commitment to excellence and customer satisfaction.</p>
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
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Services - Wishnu Services</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #667eea; margin-bottom: 30px; }
        h2 { color: #764ba2; margin-top: 30px; margin-bottom: 15px; }
        p { line-height: 1.8; margin-bottom: 20px; }
        ul { margin-left: 20px; margin-bottom: 20px; }
        li { margin-bottom: 10px; }
        a { color: #667eea; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Our Services</h1>
        
        <h2>Cloud Infrastructure</h2>
        <ul>
            <li>Virtual Private Servers (VPS)</li>
            <li>Dedicated Hosting Solutions</li>
            <li>Scalable Cloud Storage</li>
            <li>Load Balancing & CDN</li>
        </ul>

        <h2>Network Security</h2>
        <ul>
            <li>DDoS Protection</li>
            <li>SSL/TLS Certificates</li>
            <li>Firewall Configuration</li>
            <li>Security Audits</li>
        </ul>

        <h2>Managed Services</h2>
        <ul>
            <li>24/7 Server Monitoring</li>
            <li>Automated Backups</li>
            <li>Performance Optimization</li>
            <li>Technical Support</li>
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
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Contact - Wishnu Services</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #667eea; margin-bottom: 30px; }
        p { line-height: 1.8; margin-bottom: 20px; }
        .contact-info { background: #f8f9fa; padding: 20px; border-radius: 5px; margin-bottom: 20px; }
        a { color: #667eea; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Contact Us</h1>
        
        <div class="contact-info">
            <p><strong>Email:</strong> support@wishnu.duckdns.org</p>
            <p><strong>Business Hours:</strong> Monday - Friday, 9:00 AM - 6:00 PM</p>
            <p><strong>Emergency Support:</strong> 24/7 Available</p>
        </div>

        <p>For technical support, please include your account details and a description of the issue.</p>
        <p>For sales inquiries, please provide information about your requirements and expected timeline.</p>
        
        <p><a href="/">← Back to Home</a></p>
    </div>
</body>
</html>
EOF_CONTACT

# robots.txt для дополнительной реалистичности
cat > "$SITE_DIR/robots.txt" <<'EOF_ROBOTS'
User-agent: *
Disallow: /admin/
Disallow: /private/
Sitemap: https://wishnu.duckdns.org/sitemap.xml
EOF_ROBOTS

# favicon.ico (простой заглушка)
echo "favicon" > "$SITE_DIR/favicon.ico"

chown -R www-data:www-data "$SITE_DIR"
chmod -R 755 "$SITE_DIR"

echo "✅ Сайт для маскировки создан в $SITE_DIR"

# 4. Включение BBR
echo "[4/8] Настройка BBR..."
if ! sysctl -n net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    echo "BBR включён"
else
    echo "BBR уже включён"
fi

# 5. Генерация криптографических параметров
echo "[5/8] Генерация ключей и параметров..."
mkdir -p /usr/local/etc/xray
rm -f "$XRAY_KEYS"

# Генерация секретного пути (8 символов)
SECRET_PATH=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
echo "path: /$SECRET_PATH" >> "$XRAY_KEYS"

# Генерация UUID для основного пользователя
MAIN_UUID=$(xray uuid 2>/dev/null || command -v ./xray >/dev/null && ./xray uuid || echo "a4b77f56-1fe6-485e-9b48-48bb198ce784")
echo "uuid: $MAIN_UUID" >> "$XRAY_KEYS"

# Генерация X25519 ключей
KEY_PAIR=$(xray x25519 2>/dev/null || command -v ./xray >/dev/null && ./xray x25519 || echo -e "Private key: cCxc5EJIDFlqlp5uFXLIo_OMTXzwmMlztmitB2CIw3s\nPublic key: VqCnBCOjZ2xvj0fquZpCQEyzpZtMhr4-JvkNK23jd3E")
PRIV_KEY=$(echo "$KEY_PAIR" | grep -i "private" | awk '{print $NF}')
PUB_KEY=$(echo "$KEY_PAIR" | grep -i "public" | awk '{print $NF}')
echo "private_key: $PRIV_KEY" >> "$XRAY_KEYS"
echo "public_key: $PUB_KEY" >> "$XRAY_KEYS"

# Генерация короткого ID (shortId)
SHORT_ID=$(openssl rand -hex 4)
echo "short_id: $SHORT_ID" >> "$XRAY_KEYS"

echo "Сгенерированы параметры:"
echo "  Путь: /$SECRET_PATH"
echo "  UUID: $MAIN_UUID"
echo "  ShortID: $SHORT_ID"

# 6. Настройка Caddyfile
echo "[6/8] Настройка Caddy..."
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
}

# Основной сайт для маскировки (порт 80)
$DOMAIN {
    root * $SITE_DIR
    file_server
    encode zstd gzip
    log {
        output file /var/log/caddy/site-access.log
    }
}

# Реверс-прокси для XHTTP на локальном порту 8001
http://127.0.0.1:8001 {
    reverse_proxy https://www.github.com {
        header_up Host {upstream_host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
        header_up User-Agent {>User-Agent}
        header_up Referer {>Referer}
    }
    log {
        output file /var/log/caddy/proxy-access.log
    }
}
EOF

# Проверка и перезапуск Caddy
caddy validate --config "$CADDYFILE" >/dev/null 2>&1
systemctl enable caddy --now >/dev/null 2>&1
sleep 2

if ! systemctl is-active --quiet caddy; then
    echo "Ошибка: служба Caddy не запущена"
    journalctl -u caddy -n 20 --no-pager
    exit 1
fi

echo "✅ Caddy настроен и запущен"

# 7. Установка Xray и создание конфигурации
echo "[7/8] Установка Xray..."
if ! command -v xray &> /dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# Чтение параметров из файла ключей
SECRET_PATH=$(grep "^path:" "$XRAY_KEYS" | awk '{print $2}')
MAIN_UUID=$(grep "^uuid:" "$XRAY_KEYS" | awk '{print $2}')
PRIV_KEY=$(grep "^private_key:" "$XRAY_KEYS" | awk '{print $2}')
PUB_KEY=$(grep "^public_key:" "$XRAY_KEYS" | awk '{print $2}')
SHORT_ID=$(grep "^short_id:" "$XRAY_KEYS" | awk '{print $2}')

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
        "ip": ["geoip:cn"],
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
sleep 2

if ! systemctl is-active --quiet xray; then
    echo "Ошибка: служба Xray не запущена"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

echo "✅ Xray установлен и запущен"

# 8. Создание утилит управления пользователями
echo "[8/8] Создание утилит управления..."
cat > /usr/local/bin/user <<'EOF_SCRIPT'
#!/bin/bash
set -e

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_KEYS="/usr/local/etc/xray/.keys"
ACTION="$1"

get_params() {
    SECRET_PATH=$(grep "^path:" "$XRAY_KEYS" | awk '{print $2}')
    PUB_KEY=$(grep "^public_key:" "$XRAY_KEYS" | awk '{print $2}')
    SHORT_ID=$(grep "^short_id:" "$XRAY_KEYS" | awk '{print $2}')
    DOMAIN=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
    PORT=$(jq -r '.inbounds[1].port' "$XRAY_CONFIG")
    IP=$(curl -4s https://icanhazip.com 2>/dev/null || echo "SERVER_IP")
}

generate_link() {
    local UUID="$1"
    local EMAIL="$2"
    get_params
    local LINK="vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PUB_KEY}&fp=firefox&fp=chrome&sni=${DOMAIN}&sid=${SHORT_ID}&type=xhttp&path=$(echo -n "$SECRET_PATH" | jq -sRr @uri)&host=&spx=%2F#${EMAIL}"
    echo "$LINK"
}

case "$ACTION" in
    list)
        echo "Список клиентов:"
        jq -r '.inbounds[0].settings.clients[] | "\(.email) (\(.id))"' "$XRAY_CONFIG" | nl -w3 -s'. '
        ;;
    qr)
        EMAIL="main"
        UUID=$(jq -r '.inbounds[0].settings.clients[] | select(.email=="main") | .id' "$XRAY_CONFIG")
        LINK=$(generate_link "$UUID" "$EMAIL")
        echo -e "\nСсылка для подключения основного пользователя:\n$LINK\n"
        echo "QR-код:"
        echo "$LINK" | qrencode -t ansiutf8
        ;;
    add)
        read -p "Введите имя пользователя (без пробелов): " EMAIL
        [[ -z "$EMAIL" || "$EMAIL" == *" "* ]] && { echo "Ошибка: имя не может быть пустым или содержать пробелы"; exit 1; }
        if jq -e ".inbounds[0].settings.clients[] | select(.email==\"$EMAIL\")" "$XRAY_CONFIG" >/dev/null 2>&1; then
            echo "Ошибка: пользователь '$EMAIL' уже существует"
            exit 1
        fi
        UUID=$(xray uuid 2>/dev/null || /usr/local/bin/xray uuid)
        jq --arg email "$EMAIL" --arg uuid "$UUID" \
           '.inbounds[0].settings.clients += [{"id": $uuid, "email": $email}]' \
           "$XRAY_CONFIG" > /tmp/xray.tmp && mv /tmp/xray.tmp "$XRAY_CONFIG"
        systemctl restart xray
        LINK=$(generate_link "$UUID" "$EMAIL")
        echo -e "\n✅ Пользователь '$EMAIL' создан\n"
        echo "Ссылка для подключения:"
        echo "$LINK"
        echo -e "\nQR-код:"
        echo "$LINK" | qrencode -t ansiutf8
        ;;
    rm)
        CLIENTS=($(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG"))
        [[ ${#CLIENTS[@]} -eq 0 ]] && { echo "Нет клиентов для удаления"; exit 1; }
        echo "Список клиентов:"
        for i in "${!CLIENTS[@]}"; do
            echo "$((i+1)). ${CLIENTS[$i]}"
        done
        read -p "Введите номер для удаления: " NUM
        [[ ! "$NUM" =~ ^[0-9]+$ || $NUM -lt 1 || $NUM -gt ${#CLIENTS[@]} ]] && { echo "Ошибка: неверный номер"; exit 1; }
        EMAIL="${CLIENTS[$((NUM-1))]}"
        [[ "$EMAIL" == "main" ]] && { echo "Ошибка: нельзя удалить основного пользователя"; exit 1; }
        jq --arg email "$EMAIL" \
           '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
           "$XRAY_CONFIG" > /tmp/xray.tmp && mv /tmp/xray.tmp "$XRAY_CONFIG"
        systemctl restart xray
        echo "✅ Пользователь '$EMAIL' удалён"
        ;;
    link)
        CLIENTS=($(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG"))
        [[ ${#CLIENTS[@]} -eq 0 ]] && { echo "Нет клиентов"; exit 1; }
        echo "Выберите клиента:"
        for i in "${!CLIENTS[@]}"; do
            echo "$((i+1)). ${CLIENTS[$i]}"
        done
        read -p "Номер: " NUM
        [[ ! "$NUM" =~ ^[0-9]+$ || $NUM -lt 1 || $NUM -gt ${#CLIENTS[@]} ]] && { echo "Ошибка: неверный номер"; exit 1; }
        EMAIL="${CLIENTS[$((NUM-1))]}"
        UUID=$(jq -r --arg email "$EMAIL" '.inbounds[0].settings.clients[] | select(.email==$email) | .id' "$XRAY_CONFIG")
        LINK=$(generate_link "$UUID" "$EMAIL")
        echo -e "\nСсылка для '$EMAIL':\n$LINK\n"
        echo "QR-код:"
        echo "$LINK" | qrencode -t ansiutf8
        ;;
    help|*)
        cat <<HELP
Управление пользователями Xray:

  user list    - Показать список всех клиентов
  user qr      - QR-код основного пользователя
  user add     - Добавить нового пользователя
  user rm      - Удалить пользователя
  user link    - Создать ссылку для выбранного пользователя
  
Файл конфигурации: /usr/local/etc/xray/config.json
Ключи и параметры:  /usr/local/etc/xray/.keys
Перезапуск Xray:   systemctl restart xray
HELP
        ;;
esac
EOF_SCRIPT

chmod +x /usr/local/bin/user

# Создание файла справки
cat > "$HELP_FILE" <<'EOF_HELP'
==========================================
Управление Xray (VLESS/XHTTP/Reality)
==========================================

Основные команды:
  user list    - Список всех клиентов
  user qr      - QR-код основного пользователя
  user add     - Добавить нового пользователя
  user rm      - Удалить пользователя
  user link    - Ссылка для выбранного пользователя
  user help    - Эта справка

Важные файлы:
  • Конфигурация: /usr/local/etc/xray/config.json
  • Ключи/параметры: /usr/local/etc/xray/.keys
  • Caddy конфиг: /etc/caddy/Caddyfile
  • Сайт для маскировки: /var/www/html/

Сервисы:
  • Перезапуск Xray: systemctl restart xray
  • Перезапуск Caddy: systemctl restart caddy
  • Статус Xray: systemctl status xray
  • Статус Caddy: systemctl status caddy

Логи:
  • Xray: journalctl -u xray -f
  • Caddy: journalctl -u caddy -f
  • Access логи: /var/log/caddy/

Примечания:
  • Основной пользователь "main" защищён от удаления
  • Для подключения используйте клиенты с поддержкой VLESS+XHTTP+Reality
    (например: v2rayNG, Shadowrocket, Sing-box)
  • Маскировка трафика: при прямом обращении к сайту отображается 
    профессиональный сайт, трафик без правильного пути перенаправляется 
    на github.com
EOF_HELP

# Финальный вывод
echo ""
echo "=========================================="
echo "✅ Установка завершена успешно!"
echo "=========================================="
echo ""
echo "Домен: $DOMAIN"
echo "IP-адрес: $SERVER_IP"
echo ""
echo "📁 Сайт для маскировки: $SITE_DIR"
echo "   Посетите: http://$DOMAIN"
echo ""
echo "Основной пользователь:"
user qr 2>/dev/null | grep -A 10 "Ссылка для подключения"
echo ""
echo "📖 Справка: user help"
echo ""
echo "⚠️  Важно:"
echo "  • Убедитесь, что порты 80/tcp и 443/tcp открыты в фаерволе"
echo "  • Caddy автоматически получит SSL сертификат при первом обращении"
echo "  • Логи Xray: journalctl -u xray -f"
echo "  • Логи Caddy: journalctl -u caddy -f"
echo ""
echo "🎨 Сайт-заглушка включает страницы:"
echo "  • Главная (/)"
echo "  • О нас (/about/)"
echo "  • Услуги (/services/)"
echo "  • Контакты (/contact/)"
