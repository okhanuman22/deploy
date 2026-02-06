#!/bin/bash
set -euo pipefail

# ============================================================================
# Xray VLESS/XHTTP/Reality Installer
# Красивый спиннер + реальный вывод при ошибках + новый UUID каждый раз
# ============================================================================

# =============== ЦВЕТОВАЯ СХЕМА ===============
DARK_GRAY='\033[38;5;242m'
SOFT_BLUE='\033[38;5;67m'
SOFT_GREEN='\033[38;5;71m'
SOFT_YELLOW='\033[38;5;178m'
SOFT_RED='\033[38;5;167m'
MEDIUM_GRAY='\033[38;5;246m'
LIGHT_GRAY='\033[38;5;250m'
BOLD='\033[1m'
RESET='\033[0m'

readonly LOG_FILE="/var/log/xray-installer.log"
exec > >(tee -a "$LOG_FILE") 2>&1

print_step() {
  echo -e "\n${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${SOFT_BLUE}▸ ${1}${RESET}"
  echo -e "${DARK_GRAY}───────────────────────────────────────────────────────────────────────────────${RESET}\n"
}

print_success() { echo -e "${SOFT_GREEN}✓${RESET} ${1}"; }
print_warning() { echo -e "${SOFT_YELLOW}⚠${RESET} ${1}"; }
print_error() {
  echo -e "\n${SOFT_RED}✗${RESET} ${BOLD}${1}${RESET}\n" >&2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
  exit 1
}
print_info() { echo -e "${LIGHT_GRAY}ℹ${RESET} ${1}"; }
print_substep() { echo -e "${MEDIUM_GRAY}  →${RESET} ${1}"; }

# ============================================================================
# УМНЫЙ СПИННЕР: красивая анимация + реальный вывод при ошибке
# ============================================================================
run_with_spinner() {
  local cmd="$1"
  local label="${2:-Выполнение операции}"
  local timeout_sec="${3:-0}"  # 0 = без таймаута
  
  # Если вывод не в терминал (перенаправлен) — просто выполняем без анимации
  if [[ ! -t 1 ]]; then
    echo "${label}..."
    if [[ "$timeout_sec" -gt 0 ]]; then
      timeout "$timeout_sec" bash -c "$cmd" 2>&1 || return $?
    else
      bash -c "$cmd" 2>&1 || return $?
    fi
    return 0
  fi
  
  local spinners=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local pid=""
  local output_file="/tmp/spinner_out_$$"
  touch "$output_file"
  
  # Запускаем команду в фоне с сохранением вывода
  if [[ "$timeout_sec" -gt 0 ]]; then
    timeout "$timeout_sec" bash -c "$cmd" > "$output_file" 2>&1 &
  else
    bash -c "$cmd" > "$output_file" 2>&1 &
  fi
  pid=$!
  
  # Анимация спиннера
  echo -ne "${LIGHT_GRAY}${label} ${spinners[0]}${RESET}"
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % ${#spinners[@]} ))
    echo -ne "\r${LIGHT_GRAY}${label} ${spinners[$i]}${RESET}"
    sleep 0.08
  done
  
  wait "$pid" 2>/dev/null
  local exit_code=$?
  
  # Очищаем строку спиннера
  echo -ne "\r\033[K"
  
  if [[ $exit_code -eq 0 ]]; then
    echo -e "${LIGHT_GRAY}${label} ${SOFT_GREEN}✓${RESET}"
    rm -f "$output_file"
    return 0
  else
    echo -e "${LIGHT_GRAY}${label} ${SOFT_RED}✗${RESET}"
    
    # Автоматически показываем вывод при ошибке
    if [[ -s "$output_file" ]]; then
      echo -e "\n${SOFT_RED}Детали ошибки:${RESET}"
      # Показываем последние 15 строк + первые 5 для контекста
      (head -n 5 "$output_file" 2>/dev/null || echo ""); echo "..."; tail -n 15 "$output_file" | sed "s/^/  ${MEDIUM_GRAY}│${RESET} /"
      echo
    fi
    
    # Диагностика распространённых проблем
    if grep -qi "unable to locate package\|not found" "$output_file" 2>/dev/null; then
      echo -e "${SOFT_YELLOW}💡 Совет:${RESET} Обновите список пакетов: sudo apt update"
    elif grep -qi "connection timed out\|failed to fetch" "$output_file" 2>/dev/null; then
      echo -e "${SOFT_YELLOW}💡 Совет:${RESET} Проверьте сетевое подключение: ping -c 3 8.8.8.8"
    elif grep -qi "no space left\|disk full" "$output_file" 2>/dev/null; then
      echo -e "${SOFT_YELLOW}💡 Совет:${RESET} Освободите место на диске: df -h /"
    fi
    
    rm -f "$output_file"
    return $exit_code
  fi
}

# ============================================================================
# Глобальные переменные
# ============================================================================

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_KEYS="/usr/local/etc/xray/.keys"
readonly XRAY_DAT_DIR="/usr/local/share/xray"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly SITE_DIR="/var/www/html"
readonly HELP_FILE="${HOME}/help"

DOMAIN="${DOMAIN:-}"
SERVER_IP=""

# ============================================================================
# Вспомогательные функции
# ============================================================================

check_root() {
  [[ "$EUID" -eq 0 ]] || print_error "Скрипт должен запускаться от имени root (используйте sudo)"
}

get_public_ip() {
  curl -4s https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}' | cut -d' ' -f1
}

prompt_domain() {
  print_step "Настройка домена"
  
  if [[ -n "$DOMAIN" ]]; then
    print_info "Домен из переменной окружения: ${DOMAIN}"
    validate_and_set_domain "$DOMAIN"
    return
  fi
  
  local existing_domain=""
  if [[ -f "$XRAY_CONFIG" ]] && command -v jq &>/dev/null; then
    existing_domain=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0] // empty' "$XRAY_CONFIG" 2>/dev/null || echo "")
  fi
  
  if [[ -n "$existing_domain" && "$existing_domain" != "null" ]]; then
    DOMAIN="$existing_domain"
    print_info "Используется домен из конфигурации: ${DOMAIN}"
    SERVER_IP=$(get_public_ip)
    print_info "IP-адрес сервера: ${SERVER_IP}"
    return
  fi
  
  echo -e "${BOLD}Введите Ваш домен${RESET} (пример: wishnu.duckdns.org)"
  echo -e "${LIGHT_GRAY}Домен должен быть привязан к IP-адресу этого сервера${RESET}"
  
  local input_domain=""
  if ! read -r input_domain < /dev/tty 2>/dev/null; then
    print_error "Не удалось прочитать домен из терминала. Укажите домен через переменную окружения:\n  DOMAIN=wishnu.duckdns.org sudo bash install.sh"
  fi
  
  input_domain=$(echo "$input_domain" | tr -d '[:space:]')
  
  if [[ -z "$input_domain" ]]; then
    print_error "Домен не может быть пустым"
  fi
  
  if [[ ! "$input_domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    print_error "Неверный формат домена (пример: ваш-домен.duckdns.org)"
  fi
  
  validate_and_set_domain "$input_domain"
}

validate_and_set_domain() {
  local input_domain="$1"
  
  if [[ ! "$input_domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    print_error "Неверный формат домена: ${input_domain}"
  fi
  
  local ipv4
  ipv4=$(host -t A "$input_domain" 2>/dev/null | awk '/has address/ {print $4; exit}' || echo "")
  
  if [[ -n "$ipv4" ]]; then
    print_success "DNS A-запись найдена: ${ipv4}"
  else
    local confirm=""
    echo -e "${SOFT_YELLOW}⚠${RESET} DNS для ${BOLD}${input_domain}${RESET} не найден."
    if read -p "Продолжить без проверки DNS? [y/N]: " confirm < /dev/tty 2>/dev/null; then
      [[ ! "$confirm" =~ ^[Yy]$ ]] && print_error "Установка прервана"
    else
      print_warning "DNS не найден (продолжаем без проверки)"
    fi
  fi
  
  SERVER_IP=$(get_public_ip)
  if [[ -n "$ipv4" && "$ipv4" != "$SERVER_IP" ]]; then
    local confirm=""
    echo -e "${SOFT_YELLOW}⚠${RESET} DNS (${ipv4}) ≠ IP сервера (${SERVER_IP})."
    if read -p "Продолжить с несоответствующим DNS? [y/N]: " confirm < /dev/tty 2>/dev/null; then
      [[ ! "$confirm" =~ ^[Yy]$ ]] && print_error "Установка прервана"
    else
      print_warning "DNS не соответствует IP сервера (продолжаем)"
    fi
  fi
  
  DOMAIN="$input_domain"
  print_success "Домен: ${DOMAIN}"
  print_info "IP-адрес сервера: ${SERVER_IP}"
}

# ============================================================================
# Подготовка системы (энтропия + проверка диска)
# ============================================================================
prepare_system() {
  print_substep "Проверка системных ресурсов"
  
  # Проверка места на диске
  local free_mb
  free_mb=$(df / --output=avail | tail -n1 | awk '{print int($1/1024)}')
  if [[ "$free_mb" -lt 500 ]]; then
    print_warning "Мало места на диске: ${free_mb} МБ (рекомендуется >500 МБ)"
  else
    print_success "Свободно на диске: ${free_mb} МБ"
  fi
  
  # Проверка энтропии
  local entropy_avail
  entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
  
  print_info "Уровень энтропии: ${entropy_avail}"
  
  if [[ "$entropy_avail" -lt 200 ]]; then
    print_warning "Низкая энтропия (< 200). Устанавливаем haveged..."
    
    run_with_spinner "apt-get update -qq" "Обновление списка пакетов" 0 || true
    run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends haveged" "Установка haveged" 0 || \
      print_error "Не удалось установить haveged. Проверьте сетевое подключение."
    
    systemctl enable haveged --now >/dev/null 2>&1 || true
    sleep 2
    
    entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
    print_info "Энтропия после haveged: ${entropy_avail}"
  else
    print_success "Энтропия достаточна (${entropy_avail})"
  fi
}

# ============================================================================
# Установка зависимостей с умным спиннером
# ============================================================================
ensure_dependency() {
  local pkg="$1"
  local cmd="${2:-$pkg}"
  
  # Проверка наличия
  if [[ "$cmd" != "-" ]]; then
    if command -v "$cmd" &>/dev/null; then
      print_info "Зависимость '${pkg}' доступна"
      return 0
    fi
  else
    if dpkg -l | grep -q "^ii.* $pkg "; then
      print_info "Пакет '${pkg}' уже установлен"
      return 0
    fi
  fi
  
  print_info "Установка: ${pkg}..."
  
  # Установка с автоматической диагностикой ошибок
  if ! run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkg" "Установка ${pkg}" 0; then
    print_error "Не удалось установить ${pkg}. См. детали выше."
  fi
  
  # Финальная проверка
  if [[ "$cmd" != "-" ]]; then
    if ! command -v "$cmd" &>/dev/null; then
      print_error "После установки ${pkg} команда '${cmd}' недоступна"
    fi
  fi
  
  print_success "Установлено: ${pkg}"
}

# ... [остальные функции: get_process_on_port, free_ports, optimize_swap, optimize_network, configure_trim] ...
# (остаются без изменений, кроме замены таймаутов на спиннеры где уместно)

configure_firewall() {
  print_substep "Настройка фаервола UFW"
  
  ensure_dependency "ufw" "ufw"
  
  if ! ip6tables -L &>/dev/null 2>&1; then
    print_warning "IPv6 недоступен, отключаем поддержку IPv6 в UFW"
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
  fi
  
  if ufw status | grep -q "Status: active"; then
    print_info "UFW уже активен"
    return
  fi
  
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ufw allow 22/tcp comment "SSH" >/dev/null 2>&1
  ufw allow 80/tcp comment "HTTP (ACME/Caddy)" >/dev/null 2>&1
  ufw allow 443/tcp comment "HTTPS (Xray)" >/dev/null 2>&1
  
  run_with_spinner "ufw --force enable" "Активация UFW" 0 || \
    print_warning "UFW активирован с предупреждениями"
  
  if ufw status | grep -q "Status: active"; then
    print_success "Фаервол активен (порты 22/80/443 открыты)"
  else
    print_warning "UFW активирован с предупреждениями"
  fi
}

configure_fail2ban() {
  print_substep "Настройка Fail2Ban"
  
  ensure_dependency "fail2ban" "fail2ban-client"
  
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    print_info "Fail2Ban уже активен"
    return
  fi
  
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
  
  systemctl enable fail2ban >/dev/null 2>&1 || true
  run_with_spinner "systemctl start fail2ban" "Запуск Fail2Ban" 0 || \
    print_warning "Fail2Ban запущен в фоне"
  
  sleep 1
  
  if systemctl is-active --quiet fail2ban; then
    print_success "Fail2Ban активен (защита SSH: 3 попытки → бан на 1 час)"
  else
    print_warning "Fail2Ban запущен в фоне (проверьте статус: systemctl status fail2ban)"
  fi
}

create_masking_site() {
  print_substep "Создание сайта для маскировки трафика"
  
  mkdir -p "$SITE_DIR"
  
  cat > "$SITE_DIR/index.html" <<'EOF_SITE'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Wishnu Cloud Services</title>
  <style>
    :root{--primary:#5f87ff;--secondary:#7171ff;--light:#f8f9fa;--dark:#212529}
    *{margin:0;padding:0;box-sizing:border-box}
    body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;line-height:1.6;color:var(--dark);background:var(--light)}
    .container{max-width:1200px;margin:0 auto;padding:2rem}
    header{text-align:center;margin-bottom:3rem}
    h1{font-size:2.25rem;color:var(--primary);margin-bottom:1rem}
    .subtitle{color:#6c757d;font-size:1.25rem;max-width:650px;margin:0 auto}
    .features{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:2rem;margin-top:2rem}
    .card{background:#fff;border-radius:12px;padding:2rem;box-shadow:0 4px 12px rgba(0,0,0,0.08);transition:transform .3s ease}
    .card:hover{transform:translateY(-4px)}
    .card h2{color:var(--primary);margin-bottom:1rem;font-size:1.5rem}
    .card p{color:#495057}
    footer{text-align:center;margin-top:4rem;color:#6c757d;font-size:.9rem;padding-top:2rem;border-top:1px solid #e9ecef}
    @media (max-width:768px){.container{padding:1rem}.features{grid-template-columns:1fr}}
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>Wishnu Cloud Services</h1>
      <p class="subtitle">Профессиональные облачные решения с гарантией 99.9% доступности</p>
    </header>
    <section class="features">
      <div class="card">
        <h2>Инфраструктура</h2>
        <p>Масштабируемые VPS с NVMe-хранилищем и сетью 10Gbps для максимальной производительности.</p>
      </div>
      <div class="card">
        <h2>Безопасность</h2>
        <p>Продвинутая защита от DDoS-атак и сквозное шифрование всего трафика.</p>
      </div>
      <div class="card">
        <h2>Поддержка</h2>
        <p>Круглосуточная техническая поддержка для оперативного решения любых вопросов.</p>
      </div>
    </section>
    <footer>
      <p>&copy; 2026 Wishnu Cloud Services. Все права защищены.</p>
    </footer>
  </div>
</body>
</html>
EOF_SITE

  mkdir -p "$SITE_DIR/about" "$SITE_DIR/contact"
  echo "<!DOCTYPE html><html lang='ru'><head><meta charset='UTF-8'><title>О нас</title></head><body><h1>О компании</h1><p>Профессиональные облачные услуги с 2021 года.</p><p><a href='/'>← На главную</a></p></body></html>" > "$SITE_DIR/about/index.html"
  echo "<!DOCTYPE html><html lang='ru'><head><meta charset='UTF-8'><title>Контакты</title></head><body><h1>Контакты</h1><p>Email: support@wishnu.duckdns.org</p><p><a href='/'>← На главную</a></p></body></html>" > "$SITE_DIR/contact/index.html"
  
  echo -e "User-agent: *\nDisallow: /admin/" > "$SITE_DIR/robots.txt"
  echo "x" > "$SITE_DIR/favicon.ico"
  
  # ИСПРАВЛЕНО: опечатка www-www-data → www-data
  chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || true
  chmod -R 755 "$SITE_DIR"
  
  print_success "Сайт для маскировки создан (${SITE_DIR})"
}

install_caddy() {
  print_substep "Установка веб-сервера Caddy"
  
  for svc in nginx apache2 httpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      print_info "Остановка конфликтующего сервиса: $svc"
      systemctl stop "$svc" >/dev/null 2>&1 || true
      systemctl disable "$svc" >/dev/null 2>&1 || true
    fi
  done
  
  if command -v caddy &>/dev/null; then
    print_info "Caddy уже установлен (версия: $(caddy version 2>/dev/null | head -n1 | cut -d' ' -f1))"
    return
  fi
  
  ensure_dependency "debian-keyring" "-"
  ensure_dependency "debian-archive-keyring" "-"
  ensure_dependency "apt-transport-https" "-"
  ensure_dependency "curl" "curl"
  ensure_dependency "gnupg" "gpg"
  
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    run_with_spinner "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" "Импорт ключа Caddy" 0 || \
      print_error "Не удалось импортировать ключ Caddy"
  fi
  
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
      > /etc/apt/sources.list.d/caddy-stable.list
  fi
  
  run_with_spinner "apt-get update -qq" "Обновление списка пакетов (Caddy)" 0 || true
  run_with_spinner "apt-get install -y caddy" "Установка Caddy" 0 || \
    print_error "Не удалось установить Caddy"
  
  print_success "Caddy установлен (версия: $(caddy version 2>/dev/null | head -n1 | cut -d' ' -f1))"
}

# ... [configure_caddy, install_xray без изменений] ...

generate_xray_config() {
  print_substep "Генерация криптографических параметров"
  
  mkdir -p /usr/local/etc/xray
  mkdir -p "$XRAY_DAT_DIR"
  
  local secret_path uuid priv_key pub_key short_id
  
  # ВСЕГДА новый UUID при установке
  secret_path=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
  uuid=$(cat /proc/sys/kernel/random/uuid)
  print_info "Сгенерирован новый UUID: ${uuid:0:8}..."
  
  # Генерация ключей ТОЛЬКО официальной командой (с таймаутом 20 сек)
  print_info "Генерация X25519 ключей..."
  
  local key_pair
  if ! key_pair=$(run_with_spinner "xray x25519" "Генерация ключей Reality" 20); then
    print_error "Генерация ключей превысила лимит (20 сек). Решение:
  sudo apt install haveged && sudo systemctl start haveged
  Затем повторите установку."
  fi
  
  # Извлечение ключей
  priv_key=$(echo "$key_pair" | grep -i "^PrivateKey" | awk '{print $NF}')
  pub_key=$(echo "$key_pair" | grep -i "^Password" | awk '{print $NF}')
  
  if [[ -z "$priv_key" || -z "$pub_key" || "${#priv_key}" -lt 40 || "${#pub_key}" -lt 40 ]]; then
    print_error "Некорректные ключи:
  PrivateKey: ${priv_key:0:12}...
  PublicKey:  ${pub_key:0:12}..."
  fi
  
  short_id=$(openssl rand -hex 4)
  
  # Сохранение параметров
  {
    echo "path: /${secret_path}"
    echo "uuid: ${uuid}"
    echo "private_key: ${priv_key}"
    echo "public_key: ${pub_key}"
    echo "short_id: ${short_id}"
  } > "$XRAY_KEYS"
  chmod 600 "$XRAY_KEYS"
  
  print_success "Параметры успешно сгенерированы:"
  print_info "  • Secret path: /${secret_path}"
  print_info "  • UUID: ${uuid:0:8}..."
  print_info "  • ShortID: ${short_id}"
  print_info "  • PrivateKey (сервер): ${priv_key:0:8}..."
  print_info "  • PublicKey (клиент): ${pub_key:0:8}..."
  
  # Генерация конфигурации
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
  chmod 644 "$XRAY_CONFIG"
  
  print_info "Валидация конфигурации Xray..."
  if ! xray test --config "$XRAY_CONFIG" 2>&1; then
    print_error "Ошибка валидации конфигурации Xray"
  fi
  
  print_success "Конфигурация Xray валидна"
  
  systemctl is-active --quiet xray 2>/dev/null && systemctl restart xray >/dev/null 2>&1 || systemctl enable xray --now >/dev/null 2>&1
  sleep 3
  
  if systemctl is-active --quiet xray; then
    print_success "Xray запущен"
  else
    journalctl -u xray -n 20 --no-pager > /tmp/xray-errors.log 2>&1 || true
    print_error "Не удалось запустить Xray. Проверьте: journalctl -u xray -n 50"
  fi
}

# ... [setup_auto_updates, create_user_utility, create_help_file без изменений] ...

main() {
  echo -e "\n${BOLD}${SOFT_BLUE}Xray VLESS/XHTTP/Reality Installer${RESET}"
  echo -e "${LIGHT_GRAY}Полная системная оптимизация + маскировка трафика${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  echo -e "${LIGHT_GRAY}Лог установки: ${LOG_FILE}${RESET}\n"
  
  check_root
  
  # ============================================================================
  # ПОДГОТОВКА СИСТЕМЫ С КРАСИВЫМ СПИННЕРОМ
  # ============================================================================
  print_step "Подготовка системы"
  prepare_system
  
  export DEBIAN_FRONTEND=noninteractive
  export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1
  
  print_step "Системные оптимизации"
  optimize_swap
  optimize_network
  configure_trim
  
  prompt_domain
  
  print_step "Безопасность системы"
  configure_firewall
  configure_fail2ban
  
  print_step "Установка зависимостей"
  
  # Обновление списка пакетов с красивым спиннером
  run_with_spinner "apt-get update -qq" "Обновление списка пакетов" 0 || \
    print_warning "apt update завершился с предупреждениями, продолжаем"
  
  # Установка зависимостей с автоматической диагностикой
  ensure_dependency "curl" "curl"
  ensure_dependency "jq" "jq"
  ensure_dependency "socat" "socat"
  ensure_dependency "git" "git"
  ensure_dependency "wget" "wget"
  ensure_dependency "gnupg" "gpg"
  ensure_dependency "ca-certificates" "update-ca-certificates"
  ensure_dependency "unzip" "unzip"
  ensure_dependency "iproute2" "ss"
  ensure_dependency "qrencode" "qrencode"
  ensure_dependency "openssl" "openssl"
  
  print_success "Все зависимости установлены"
  
  print_step "Сайт для маскировки трафика"
  create_masking_site
  
  print_step "Веб-сервер Caddy"
  install_caddy
  configure_caddy
  
  print_step "Xray Core"
  install_xray
  generate_xray_config
  
  print_step "Автоматические обновления"
  setup_auto_updates
  
  print_step "Утилиты управления"
  create_user_utility
  create_help_file
  
  echo -e "\n${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${SOFT_GREEN}Установка завершена успешно${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  
  echo -e "${BOLD}Домен:${RESET}       ${DOMAIN}"
  echo -e "${BOLD}IP-адрес:${RESET}    ${SERVER_IP}"
  echo -e "${BOLD}Сайт:${RESET}        https://${DOMAIN}"
  echo
  
  echo -e "${BOLD}Основной пользователь:${RESET}"
  echo -e "  UUID: $(grep '^uuid:' ${XRAY_KEYS} | awk '{print $2}' | cut -c1-8)..."
  echo -e "  Ссылка: ${BOLD}user qr${RESET}"
  echo
  
  echo -e "${BOLD}Управление:${RESET}"
  echo -e "  ${MEDIUM_GRAY}user list${RESET}    # Список клиентов"
  echo -e "  ${MEDIUM_GRAY}user add${RESET}     # Новый пользователь (с уникальным UUID)"
  echo -e "  ${MEDIUM_GRAY}user qr${RESET}      # QR-код подключения"
  echo -e "  ${MEDIUM_GRAY}cat ~/help${RESET}   # Документация"
  echo
  
  echo -e "${SOFT_YELLOW}ℹ${RESET} SSL-сертификат будет получен автоматически при первом запросе к ${BOLD}https://${DOMAIN}${RESET}"
  echo -e "${LIGHT_GRAY}Полный лог: ${LOG_FILE}${RESET}"
  echo
}

main "$@"
