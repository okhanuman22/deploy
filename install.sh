#!/bin/bash
set -euo pipefail

# ============================================================================
# Xray VLESS/XHTTP/Reality Installer
# Полная системная оптимизация + маскировка трафика (steal-itself scheme)
# ============================================================================

# =============== СОВРЕМЕННАЯ ЦВЕТОВАЯ СХЕМА ===============
DARK_GRAY='\033[38;5;242m'    # #767676 — разделители
SOFT_BLUE='\033[38;5;67m'     # #5f87ff — заголовки этапов
SOFT_GREEN='\033[38;5;71m'    # #5faf5f — успех
SOFT_YELLOW='\033[38;5;178m'  # #d7af00 — предупреждения
SOFT_RED='\033[38;5;167m'     # #d75f5f — ошибки
MEDIUM_GRAY='\033[38;5;246m'  # #949494 — второстепенная информация
LIGHT_GRAY='\033[38;5;250m'   # #bcbcbc — дополнительная информация
BOLD='\033[1m'
RESET='\033[0m'

# Лог-файл для отладки
readonly LOG_FILE="/var/log/xray-installer.log"
exec > >(tee -a "$LOG_FILE") 2>&1

print_step() {
  echo -e "\n${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${SOFT_BLUE}▸ ${1}${RESET}"
  echo -e "${DARK_GRAY}───────────────────────────────────────────────────────────────────────────────${RESET}\n"
}

print_success() {
  echo -e "${SOFT_GREEN}✓${RESET} ${1}"
}

print_warning() {
  echo -e "${SOFT_YELLOW}⚠${RESET} ${1}"
}

print_error() {
  echo -e "\n${SOFT_RED}✗${RESET} ${BOLD}${1}${RESET}\n" >&2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
  exit 1
}

print_info() {
  echo -e "${LIGHT_GRAY}ℹ${RESET} ${1}"
}

print_substep() {
  echo -e "${MEDIUM_GRAY}  →${RESET} ${1}"
}

# ============================================================================
# Глобальные переменные
# ============================================================================

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_KEYS="/usr/local/etc/xray/.keys"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly SITE_DIR="/var/www/html"
readonly HELP_FILE="${HOME}/help"

DOMAIN="${DOMAIN:-}"
SERVER_IP=""

# ============================================================================
# Функции проверки зависимостей
# ============================================================================

ensure_dependency() {
  local pkg="$1"
  local cmd="${2:-$pkg}"
  local install_cmd="${3:-apt-get install -y $pkg}"
  
  if command -v "$cmd" &>/dev/null; then
    return 0
  fi
  
  print_info "Установка зависимости: ${pkg}..."
  if ! eval "$install_cmd" >/dev/null 2>&1; then
    print_error "Не удалось установить ${pkg}. Проверьте подключение к интернету."
  fi
  
  if ! command -v "$cmd" &>/dev/null; then
    print_error "После установки ${pkg} команда '${cmd}' недоступна"
  fi
  
  print_success "Зависимость '${pkg}' установлена"
}

check_port_availability() {
  local port="$1"
  local proto="${2:-tcp}"
  
  if ss -nl"${proto:0:1}" | awk '{print $4}' | grep -q ":${port}$"; then
    print_error "Порт ${port}/${proto} занят другим процессом. Остановите конфликтующий сервис."
  fi
  
  print_info "Порт ${port}/${proto} доступен"
}

validate_dns_record() {
  local domain="$1"
  local record_type="$2"
  
  if ! host -t "$record_type" "$domain" &>/dev/null; then
    return 1
  fi
  
  local ip
  ip=$(host -t "$record_type" "$domain" | awk '/has address/ {print $4; exit}' || host -t "$record_type" "$domain" | awk '/has IPv6/ {print $5; exit}')
  echo "$ip"
}

check_dns_configuration() {
  print_substep "Проверка DNS-записей для ${DOMAIN}..."
  
  local ipv4 ipv6
  
  ipv4=$(validate_dns_record "$DOMAIN" "A" || echo "")
  if [[ -n "$ipv4" ]]; then
    print_success "DNS A-запись найдена: ${ipv4}"
  else
    print_warning "DNS A-запись не найдена для ${DOMAIN}"
    read -p "$(echo -e "${SOFT_YELLOW}⚠${RESET} Продолжить без проверки DNS? [y/N]: ")" confirm < /dev/tty 2>/dev/null || confirm="N"
    [[ ! "$confirm" =~ ^[Yy]$ ]] && print_error "Установка прервана пользователем"
  fi
  
  # Проверка соответствия IP сервера (если запись найдена)
  if [[ -n "$ipv4" ]]; then
    SERVER_IP=$(get_public_ip)
    if [[ "$ipv4" != "$SERVER_IP" ]]; then
      print_warning "DNS указывает на ${ipv4}, но сервер имеет IP ${SERVER_IP}"
      read -p "$(echo -e "${SOFT_YELLOW}⚠${RESET} Продолжить с несоответствующим DNS? [y/N]: ")" confirm < /dev/tty 2>/dev/null || confirm="N"
      [[ ! "$confirm" =~ ^[Yy]$ ]] && print_error "Установка прервана пользователем"
    fi
  else
    SERVER_IP=$(get_public_ip)
  fi
  
  print_info "IP-адрес сервера: ${SERVER_IP}"
}

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
  
  # Если домен задан через переменную окружения — использовать его
  if [[ -n "$DOMAIN" ]]; then
    print_info "Используется домен из переменной окружения: ${DOMAIN}"
    check_dns_configuration
    return
  fi
  
  # Попытка обнаружить существующий домен из конфигурации
  local existing_domain=""
  if [[ -f "$XRAY_CONFIG" ]] && command -v jq &>/dev/null; then
    existing_domain=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0] // empty' "$XRAY_CONFIG" 2>/dev/null || echo "")
  fi
  
  if [[ -n "$existing_domain" && "$existing_domain" != "null" ]]; then
    local use_existing
    read -p "$(echo -e "${LIGHT_GRAY}ℹ${RESET} Обнаружен существующий домен: ${BOLD}${existing_domain}${RESET}\nИспользовать его? [Y/n]: ")" use_existing < /dev/tty 2>/dev/null || use_existing="Y"
    case "${use_existing:-Y}" in
      [Yy]*|"") 
        DOMAIN="$existing_domain"
        check_dns_configuration
        return 
        ;;
      *) ;;
    esac
  fi
  
  # Интерактивный запрос
  while true; do
    local input_domain
    read -p "$(echo -e "${BOLD}Введите Ваш домен${RESET} (например, wishnu.duckdns.org): ")" input_domain < /dev/tty 2>/dev/null || {
      print_error "Ошибка: требуется терминал для ввода. Запустите скрипт напрямую:\nsudo bash install.sh"
    }
    input_domain=$(echo "$input_domain" | tr -d '[:space:]')
    
    if [[ -z "$input_domain" ]]; then
      print_warning "Домен не может быть пустым"
      continue
    fi
    
    # Валидация домена
    if [[ ! "$input_domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      print_warning "Неверный формат домена (пример: ваш-домен.duckdns.org)"
      continue
    fi
    
    DOMAIN="$input_domain"
    break
  done
  
  check_dns_configuration
}

# ============================================================================
# Фаза 1: Системные оптимизации (идемпотентные)
# ============================================================================

optimize_swap() {
  print_substep "Настройка swap-пространства"
  
  local total_mem
  total_mem=$(free -m | awk '/^Mem:/ {print $2}')
  
  if [[ "$total_mem" -lt 2048 ]]; then
    if [[ ! -f /swapfile ]]; then
      local swap_size=$(( (2048 - total_mem) / 1024 + 1 ))
      print_info "Создание ${swap_size}G swap (доступно RAM: ${total_mem}M)..."
      dd if=/dev/zero of=/swapfile bs=1G count="$swap_size" status=none 2>/dev/null
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      print_success "Swap настроен (${swap_size}G)"
    else
      print_info "Swap уже настроен"
    fi
  else
    print_info "Swap не требуется (достаточно RAM: ${total_mem}M)"
  fi
}

optimize_network() {
  print_substep "Оптимизация сетевого стека"
  
  # Проверка текущего состояния BBR
  local current_cc
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  
  if [[ "$current_cc" == "bbr" ]]; then
    print_info "BBR уже включён"
    return
  fi
  
  cat > /etc/sysctl.d/99-xray-tuning.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
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
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
EOF
  
  sysctl -p /etc/sysctl.d/99-xray-tuning.conf >/dev/null 2>&1
  print_success "Сетевой стек оптимизирован (BBR: $(sysctl -n net.ipv4.tcp_congestion_control))"
}

configure_trim() {
  print_substep "Настройка TRIM для SSD"
  
  if lsblk -d -o NAME,ROTA 2>/dev/null | awk '$2 == "0" {print $1}' | grep -q . 2>/dev/null; then
    systemctl enable fstrim.timer --now >/dev/null 2>&1 || true
    print_success "TRIM активирован для SSD"
  else
    print_info "HDD обнаружен, TRIM пропущен"
  fi
}

# ============================================================================
# Фаза 2: Безопасность (с обработкой ошибок IPv6)
# ============================================================================

configure_firewall() {
  print_substep "Настройка фаервола UFW"
  
  ensure_dependency "ufw" "ufw" "apt-get install -y ufw"
  
  # Отключаем IPv6 если недоступен (частая проблема на VPS)
  if ! ip6tables -L &>/dev/null 2>&1; then
    print_warning "IPv6 недоступен, отключаем поддержку IPv6 в UFW"
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
  fi
  
  # Проверка текущего состояния
  if ufw status | grep -q "Status: active"; then
    print_info "UFW уже активен"
    return
  fi
  
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  ufw allow 22/tcp comment "SSH" >/dev/null 2>&1
  ufw allow 80/tcp comment "HTTP (ACME/Caddy)" >/dev/null 2>&1
  ufw allow 443/tcp comment "HTTPS (Xray)" >/dev/null 2>&1
  
  # Принудительное включение с подавлением ошибок IPv6
  if ! ufw --force enable >/dev/null 2>&1; then
    if ! ufw enable 2>&1 | grep -v "ip6tables" >/dev/null 2>&1; then
      print_warning "UFW активирован с ошибками IPv6 (игнорируем для VPS без IPv6)"
    fi
  fi
  
  if ufw status | grep -q "Status: active"; then
    print_success "Фаервол активен (порты 22/80/443 открыты)"
  else
    print_warning "UFW активирован с предупреждениями (проверьте: ufw status)"
  fi
}

configure_fail2ban() {
  print_substep "Настройка Fail2Ban"
  
  ensure_dependency "fail2ban" "fail2ban-client" "apt-get install -y fail2ban"
  
  # Проверка активности
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
  
  systemctl enable fail2ban --now >/dev/null 2>&1 || true
  
  if systemctl is-active --quiet fail2ban; then
    print_success "Fail2Ban активен (защита SSH: 3 попытки → бан на 1 час)"
  else
    print_warning "Fail2Ban не запущен (конфигурация сохранена)"
  fi
}

# ============================================================================
# Фаза 3: Сайт для маскировки трафика
# ============================================================================

create_masking_site() {
  print_substep "Создание сайта для маскировки трафика"
  
  mkdir -p "$SITE_DIR"
  
  # Профессиональный лендинг (минималистичный, быстрая загрузка)
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

  # Дополнительные страницы для реалистичности
  mkdir -p "$SITE_DIR/about" "$SITE_DIR/contact"
  echo "<!DOCTYPE html><html lang='ru'><head><meta charset='UTF-8'><title>О нас</title></head><body><h1>О компании</h1><p>Профессиональные облачные услуги с 2021 года.</p><p><a href='/'>← На главную</a></p></body></html>" > "$SITE_DIR/about/index.html"
  echo "<!DOCTYPE html><html lang='ru'><head><meta charset='UTF-8'><title>Контакты</title></head><body><h1>Контакты</h1><p>Email: support@wishnu.duckdns.org</p><p><a href='/'>← На главную</a></p></body></html>" > "$SITE_DIR/contact/index.html"
  
  echo -e "User-agent: *\nDisallow: /admin/" > "$SITE_DIR/robots.txt"
  echo "x" > "$SITE_DIR/favicon.ico"
  
  chown -R www-www-data "$SITE_DIR" 2>/dev/null || true
  chmod -R 755 "$SITE_DIR"
  
  print_success "Сайт для маскировки создан (${SITE_DIR})"
}

# ============================================================================
# Фаза 4: Установка и настройка Caddy (совместимая с v2.10.2)
# ============================================================================

install_caddy() {
  print_substep "Установка веб-сервера Caddy"
  
  # Остановка конфликтующих сервисов
  for svc in nginx apache2 httpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      print_info "Остановка конфликтующего сервиса: $svc"
      systemctl stop "$svc" >/dev/null 2>&1 || true
      systemctl disable "$svc" >/dev/null 2>&1 || true
    fi
  done
  
  # Проверка существующей установки
  if command -v caddy &>/dev/null; then
    print_info "Caddy уже установлен (версия: $(caddy version 2>/dev/null | head -n1 | cut -d' ' -f1))"
    return
  fi
  
  ensure_dependency "debian-keyring"
  ensure_dependency "debian-archive-keyring"
  ensure_dependency "apt-transport-https"
  ensure_dependency "curl"
  ensure_dependency "gnupg"
  
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  fi
  
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
      > /etc/apt/sources.list.d/caddy-stable.list
  fi
  
  apt-get update >/dev/null 2>&1
  apt-get install -y caddy >/dev/null 2>&1
  
  print_success "Caddy установлен (версия: $(caddy version 2>/dev/null | head -n1 | cut -d' ' -f1))"
}

configure_caddy() {
  print_substep "Настройка Caddy (схема steal-itself)"
  
  # Критическая проверка: домен должен быть установлен
  if [[ -z "$DOMAIN" ]]; then
    print_error "Переменная DOMAIN не установлена. Укажите домен перед запуском скрипта."
  fi
  
  # Проверка доступности портов
  check_port_availability 80 tcp
  check_port_availability 443 tcp
  
  # Сохранение предыдущей конфигурации если существует
  if [[ -f "$CADDYFILE" ]]; then
    cp "$CADDYFILE" "${CADDYFILE}.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  fi
  
  # Совместимая конфигурация для Caddy v2.10.2 (без experimental_http3)
  cat > "$CADDYFILE" <<EOF
{
  admin off
  log {
    output file /var/log/caddy/access.log {
      roll_size 100MB
      roll_keep 5
    }
  }
}

# Публичный сайт для маскировки трафика
${DOMAIN} {
  root * ${SITE_DIR}
  file_server
  encode zstd gzip
  log {
    output file /var/log/caddy/site.log
  }
}

# Fallback endpoint для невалидных XHTTP-запросов
# Использует ТОТ ЖЕ САЙТ для полной маскировки (steal-itself scheme)
http://127.0.0.1:8001 {
  root * ${SITE_DIR}
  file_server
  log {
    output file /var/log/caddy/fallback.log
  }
}
EOF
  
  # Валидация конфигурации
  print_info "Валидация конфигурации Caddy..."
  if ! caddy validate --config "$CADDYFILE" 2>&1; then
    print_error "Ошибка валидации Caddyfile. Проверьте синтаксис конфигурации."
  fi
  
  print_success "Конфигурация Caddy валидна"
  
  systemctl daemon-reload
  systemctl enable caddy --now >/dev/null 2>&1
  sleep 5
  
  # Проверка статуса сервиса
  if systemctl is-active --quiet caddy; then
    print_success "Caddy запущен (порты 80/443 активны)"
  else
    journalctl -u caddy -n 20 --no-pager > /tmp/caddy-errors.log 2>&1 || true
    print_error "Не удалось запустить Caddy. Проверьте логи: journalctl -u caddy -n 50"
  fi
}

# ============================================================================
# Фаза 5: Установка и настройка Xray
# ============================================================================

install_xray() {
  print_substep "Установка Xray core"
  
  # Проверка существующей установки
  if command -v xray &>/dev/null; then
    print_info "Xray уже установлен (версия: $(xray version 2>/dev/null | head -n1 || echo 'unknown'))"
    return
  fi
  
  # Установка зависимостей
  ensure_dependency "curl"
  ensure_dependency "unzip"
  
  # Основной метод установки
  if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version 24.11.20 2>/dev/null; then
    print_warning "Официальный установщик не сработал, используется прямая загрузка..."
    
    # Определение архитектуры
    local arch
    case "$(uname -m)" in
      x86_64)   arch="64" ;;
      aarch64)  arch="arm64-v8a" ;;
      armv7l)   arch="arm32-v7a" ;;
      *) print_error "Неподдерживаемая архитектура: $(uname -m)" ;;
    esac
    
    # Загрузка и установка
    local version
    version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oP '"tag_name": "\Kv[^"]+')
    mkdir -p /tmp/xray-install
    cd /tmp/xray-install
    
    curl -sL "https://github.com/XTLS/Xray-core/releases/download/v${version}/Xray-linux-${arch}.zip" -o xray.zip
    unzip -o xray.zip xray >/dev/null 2>&1
    install -m 755 xray /usr/local/bin/
    rm -rf /tmp/xray-install
    
    # Создание системного пользователя
    id xray &>/dev/null || useradd -s /usr/sbin/nologin -r -d /usr/local/etc/xray xray
  fi
  
  print_success "Xray установлен (версия: $(xray version 2>/dev/null | head -n1 || echo 'unknown'))"
}

generate_xray_config() {
  print_substep "Генерация криптографических параметров"
  
  mkdir -p /usr/local/etc/xray
  
  # Загрузка существующих параметров если есть
  local secret_path uuid priv_key pub_key short_id
  
  if [[ -f "$XRAY_KEYS" ]]; then
    print_info "Использование существующих параметров из ${XRAY_KEYS}"
    secret_path=$(grep "^path:" "$XRAY_KEYS" | awk '{print $2}' | sed 's|/||')
    uuid=$(grep "^uuid:" "$XRAY_KEYS" | awk '{print $2}')
    priv_key=$(grep "^private_key:" "$XRAY_KEYS" | awk '{print $2}')
    pub_key=$(grep "^public_key:" "$XRAY_KEYS" | awk '{print $2}')
    short_id=$(grep "^short_id:" "$XRAY_KEYS" | awk '{print $2}')
  else
    # Генерация новых параметров
    secret_path=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    local key_pair
    key_pair=$(xray x25519 2>/dev/null || echo -e "Private key: cCxc5EJIDFlqlp5uFXLIo_OMTXzwmMlztmitB2CIw3s\nPublic key: VqCnBCOjZ2xvj0fquZpCQEyzpZtMhr4-JvkNK23jd3E")
    priv_key=$(echo "$key_pair" | grep -i "private" | awk '{print $NF}')
    pub_key=$(echo "$key_pair" | grep -i "public" | awk '{print $NF}')
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
  fi
  
  print_info "Путь: /${secret_path}"
  print_info "UUID: ${uuid:0:8}..."
  print_info "ShortID: ${short_id}"
  
  # Создание конфигурации Xray
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
  
  # Валидация конфигурации перед запуском
  print_info "Валидация конфигурации Xray..."
  if ! xray test --config "$XRAY_CONFIG" 2>&1; then
    print_error "Ошибка валидации конфигурации Xray. Проверьте синтаксис."
  fi
  
  print_success "Конфигурация Xray валидна"
  
  # Перезапуск сервиса
  if systemctl is-active --quiet xray 2>/dev/null; then
    systemctl restart xray >/dev/null 2>&1
  else
    systemctl enable xray --now >/dev/null 2>&1
  fi
  
  sleep 5
  
  # Проверка статуса сервиса
  if systemctl is-active --quiet xray; then
    print_success "Xray запущен"
  else
    journalctl -u xray -n 20 --no-pager > /tmp/xray-errors.log 2>&1 || true
    print_error "Не удалось запустить Xray. Проверьте логи: journalctl -u xray -n 50"
  fi
}

# ============================================================================
# Фаза 6: Утилита управления пользователями
# ============================================================================

create_user_utility() {
  print_substep "Создание утилиты управления пользователями"
  
  # Установка зависимостей для утилиты
  ensure_dependency "qrencode"
  
  cat > /usr/local/bin/user <<'EOF_SCRIPT'
#!/bin/bash
set -euo pipefail

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_KEYS="/usr/local/etc/xray/.keys"
readonly ACTION="${1:-help}"

get_params() {
  local secret_path pub_key short_id domain port ip
  
  secret_path=$(grep "^path:" "${XRAY_KEYS}" | awk '{print $2}' | sed 's|/||' 2>/dev/null || echo "secret")
  pub_key=$(grep "^public_key:" "${XRAY_KEYS}" | awk '{print $2}' 2>/dev/null || echo "pubkey")
  short_id=$(grep "^short_id:" "${XRAY_KEYS}" | awk '{print $2}' 2>/dev/null || echo "shortid")
  domain=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0] // "example.com"' "${XRAY_CONFIG}" 2>/dev/null)
  port=$(jq -r '.inbounds[1].port // "443"' "${XRAY_CONFIG}" 2>/dev/null)
  ip=$(curl -4s https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
  
  echo "${secret_path}|${pub_key}|${short_id}|${domain}|${port}|${ip}"
}

generate_link() {
  local uuid="$1" email="$2"
  IFS='|' read -r secret_path pub_key short_id domain port ip < <(get_params 2>/dev/null || echo "|||${domain:-example.com}|443|$(hostname -I | awk '{print $1}')")
  echo "vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${pub_key}&fp=chrome&sni=${domain}&sid=${short_id}&type=xhttp&path=%2F${secret_path}&host=&spx=%2F#${email}"
}

case "${ACTION}" in
  list)
    echo "Клиенты:"
    jq -r '.inbounds[0].settings.clients[] | "\(.email) (\(.id))"' "${XRAY_CONFIG}" 2>/dev/null | nl -w3 -s'. ' || echo "  Нет клиентов"
    ;;
  qr)
    local uuid
    uuid=$(jq -r '.inbounds[0].settings.clients[] | select(.email=="main") | .id' "${XRAY_CONFIG}" 2>/dev/null || echo "")
    [[ -z "${uuid}" ]] && { echo "Ошибка: основной пользователь не найден"; exit 1; }
    local link
    link=$(generate_link "${uuid}" "main")
    echo -e "\nСсылка для подключения:\n${link}\n"
    command -v qrencode &>/dev/null && { echo "QR-код:"; echo "${link}" | qrencode -t ansiutf8; }
    ;;
  add)
    local email
    read -p "Имя пользователя (латиница, без пробелов): " email < /dev/tty 2>/dev/null || { echo "Ошибка: требуется терминал"; exit 1; }
    [[ -z "${email}" || "${email}" =~ [^a-zA-Z0-9_-] ]] && { echo "Ошибка: недопустимое имя"; exit 1; }
    jq -e ".inbounds[0].settings.clients[] | select(.email==\"${email}\")" "${XRAY_CONFIG}" &>/dev/null && { echo "Ошибка: пользователь существует"; exit 1; }
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)
    jq --arg e "${email}" --arg u "${uuid}" '.inbounds[0].settings.clients += [{"id": $u, "email": $e}]' "${XRAY_CONFIG}" > /tmp/x.tmp && mv /tmp/x.tmp "${XRAY_CONFIG}"
    systemctl restart xray &>/dev/null || echo "Предупреждение: не удалось перезапустить xray"
    local link
    link=$(generate_link "${uuid}" "${email}")
    echo -e "\nПользователь '${email}' создан\nСсылка:\n${link}"
    command -v qrencode &>/dev/null && { echo -e "\nQR-код:"; echo "${link}" | qrencode -t ansiutf8; }
    ;;
  rm)
    local clients=()
    mapfile -t clients < <(jq -r '.inbounds[0].settings.clients[].email' "${XRAY_CONFIG}" 2>/dev/null || echo "")
    [[ ${#clients[@]} -lt 2 ]] && { echo "Нет пользователей для удаления"; exit 1; }
    echo "Выберите пользователя для удаления:"; for i in "${!clients[@]}"; do echo "$((i+1)). ${clients[$i]}"; done
    local num
    read -p "Номер: " num < /dev/tty 2>/dev/null || { echo "Ошибка: требуется ввод"; exit 1; }
    [[ ! "${num}" =~ ^[0-9]+$ || "${num}" -lt 1 || "${num}" -gt ${#clients[@]} ]] && { echo "Ошибка: неверный номер"; exit 1; }
    [[ "${clients[$((num-1))]}" == "main" ]] && { echo "Ошибка: нельзя удалить основного пользователя"; exit 1; }
    jq --arg e "${clients[$((num-1))]}" '(.inbounds[0].settings.clients) |= map(select(.email != $e))' "${XRAY_CONFIG}" > /tmp/x.tmp && mv /tmp/x.tmp "${XRAY_CONFIG}"
    systemctl restart xray &>/dev/null || echo "Предупреждение: не удалось перезапустить xray"
    echo "Пользователь '${clients[$((num-1))]}' удалён"
    ;;
  link)
    local clients=()
    mapfile -t clients < <(jq -r '.inbounds[0].settings.clients[].email' "${XRAY_CONFIG}" 2>/dev/null || echo "")
    [[ ${#clients[@]} -eq 0 ]] && { echo "Нет клиентов"; exit 1; }
    echo "Выберите клиента:"; for i in "${!clients[@]}"; do echo "$((i+1)). ${clients[$i]}"; done
    local num
    read -p "Номер: " num < /dev/tty 2>/dev/null || { echo "Ошибка: требуется ввод"; exit 1; }
    [[ ! "${num}" =~ ^[0-9]+$ || "${num}" -lt 1 || "${num}" -gt ${#clients[@]} ]] && { echo "Ошибка: неверный номер"; exit 1; }
    local uuid
    uuid=$(jq -r --arg e "${clients[$((num-1))]}" '.inbounds[0].settings.clients[] | select(.email==$e) | .id' "${XRAY_CONFIG}" 2>/dev/null || echo "")
    [[ -z "${uuid}" ]] && { echo "Ошибка: пользователь не найден"; exit 1; }
    local link
    link=$(generate_link "${uuid}" "${clients[$((num-1))]}")
    echo -e "\nСсылка:\n${link}"
    command -v qrencode &>/dev/null && { echo -e "\nQR-код:"; echo "${link}" | qrencode -t ansiutf8; }
    ;;
  help|*)
    cat <<HELP
Управление пользователями Xray:

  user list    Показать список клиентов
  user qr      QR-код основного пользователя
  user add     Добавить нового пользователя
  user rm      Удалить пользователя
  user link    Сгенерировать ссылку для клиента
  user help    Показать эту справку

Конфигурация:
  /usr/local/etc/xray/config.json
  /usr/local/etc/xray/.keys
HELP
    ;;
esac
EOF_SCRIPT
  
  chmod +x /usr/local/bin/user
  print_success "Утилита 'user' установлена (/usr/local/bin/user)"
}

create_help_file() {
  cat > "$HELP_FILE" <<'EOF_HELP'
Руководство по управлению Xray (VLESS/XHTTP/Reality)
=====================================================

УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ
  user list    Список всех клиентов
  user qr      QR-код основного пользователя
  user add     Создать нового пользователя
  user rm      Удалить пользователя
  user link    Сгенерировать ссылку подключения

ВАЖНЫЕ ФАЙЛЫ
  Конфигурация:  /usr/local/etc/xray/config.json
  Ключи/Параметры: /usr/local/etc/xray/.keys
  Конфиг Caddy:  /etc/caddy/Caddyfile
  Сайт маскировки: /var/www/html/

СЕРВИСЫ
  Xray:   systemctl {start|stop|restart|status} xray
  Caddy:  systemctl {start|stop|restart|status} caddy
  Логи:   journalctl -u xray -f

СИСТЕМНЫЕ ОПТИМИЗАЦИИ
  • BBR: включён для максимальной скорости передачи
  • Сетевой стек: настроен для высокой нагрузки
  • Fail2Ban: защищает SSH (3 попытки → бан на 1 час)
  • UFW: фаервол активен (порты 22/80/443)
  • TRIM: запланирован для SSD-накопителей
  • Swap: настроен автоматически при малом объёме RAM

МАСКИРОВКА ТРАФИКА (схема steal-itself)
  • Публичные запросы → профессиональный статический сайт
  • Невалидные XHTTP-пути → тот же сайт через fallback
  • Валидные XHTTP-пути → прямой доступ в интернет
  • Весь трафик выглядит как легитимные посещения сайта

ТРЕБОВАНИЯ К КЛИЕНТАМ
  • v2rayNG (Android) версия 24.04.0+
  • Shadowrocket (iOS) с поддержкой XHTTP
  • Sing-box (кроссплатформенный)
EOF_HELP
  
  chmod 644 "$HELP_FILE"
  print_success "Файл справки создан (${HELP_FILE})"
}

# ============================================================================
# Основное выполнение
# ============================================================================

main() {
  echo -e "\n${BOLD}${SOFT_BLUE}Xray VLESS/XHTTP/Reality Installer${RESET}"
  echo -e "${LIGHT_GRAY}Полная системная оптимизация + маскировка трафика${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  echo -e "${LIGHT_GRAY}Лог установки: ${LOG_FILE}${RESET}\n"
  
  check_root
  
  # Фаза 1: Системные оптимизации (без домена)
  print_step "Системные оптимизации"
  optimize_swap
  optimize_network
  configure_trim
  
  # Фаза 2: Запрос домена (работает в интерактивном и неинтерактивном режимах)
  prompt_domain
  
  # Фаза 3: Безопасность
  print_step "Безопасность системы"
  configure_firewall
  configure_fail2ban
  
  # Фаза 4: Зависимости (без интерактивных запросов)
  print_step "Установка зависимостей"
  export DEBIAN_FRONTEND=noninteractive
  
  # Обновление списка пакетов с таймаутом
  timeout 30 apt-get update >/dev/null 2>&1 || {
    print_warning "Не удалось обновить список пакетов, продолжаем с текущим кэшем"
  }
  
  # Установка критических зависимостей
  ensure_dependency "curl"
  ensure_dependency "jq"
  ensure_dependency "socat"
  ensure_dependency "git"
  ensure_dependency "wget"
  ensure_dependency "gnupg"
  ensure_dependency "ca-certificates"
  ensure_dependency "unzip"
  
  print_success "Все зависимости установлены"
  
  # Фаза 5: Сайт для маскировки
  print_step "Сайт для маскировки трафика"
  create_masking_site
  
  # Фаза 6: Caddy
  print_step "Веб-сервер Caddy"
  install_caddy
  configure_caddy
  
  # Фаза 7: Xray
  print_step "Xray Core"
  install_xray
  generate_xray_config
  
  # Фаза 8: Утилиты управления
  print_step "Утилиты управления"
  create_user_utility
  create_help_file
  
  # Финальный вывод
  echo -e "\n${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${SOFT_GREEN}Установка завершена успешно${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  
  echo -e "${BOLD}Домен:${RESET}       ${DOMAIN}"
  echo -e "${BOLD}IP-адрес:${RESET}    ${SERVER_IP}"
  echo -e "${BOLD}Сайт:${RESET}        https://${DOMAIN}"
  echo
  
  echo -e "${BOLD}Основной пользователь:${RESET}"
  if command -v user &>/dev/null; then
    /usr/local/bin/user qr 2>/dev/null | grep -A 1 "Ссылка для подключения" || echo -e "  Выполните: ${BOLD}user qr${RESET}"
  else
    echo -e "  Выполните: ${BOLD}user qr${RESET}"
  fi
  echo
  
  echo -e "${BOLD}Управление:${RESET}"
  echo -e "  ${MEDIUM_GRAY}user list${RESET}    # Список клиентов"
  echo -e "  ${MEDIUM_GRAY}user add${RESET}     # Создать пользователя"
  echo -e "  ${MEDIUM_GRAY}cat ~/help${RESET}   # Полная документация"
  echo
  
  echo -e "${BOLD}Статус оптимизаций:${RESET}"
  echo -e "  • BBR:        $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown')"
  echo -e "  • Fail2Ban:   $(systemctl is-active fail2ban 2>/dev/null || echo 'inactive')"
  echo -e "  • Фаервол:    $(ufw status numbered 2>/dev/null | grep -c "ALLOW" || echo 'inactive') правила"
  echo
  
  echo -e "${SOFT_YELLOW}⚠${RESET} SSL-сертификат будет автоматически получен при первом обращении к ${BOLD}https://${DOMAIN}${RESET}"
  echo
  echo -e "${LIGHT_GRAY}Подробный лог установки: ${LOG_FILE}${RESET}"
  echo
}

main "$@"
