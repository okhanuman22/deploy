#!/bin/bash
set -euo pipefail

# ============================================================================
# Xray VLESS/XHTTP/Reality Installer
# Только официальная генерация ключей + новый UUID при каждой установке
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
# ВИЗУАЛЬНЫЙ ОБРАТНЫЙ ОТСЧЁТ
# ============================================================================
countdown() {
  local seconds="$1"
  local label="${2:-Операция}"
  local start_time=$(date +%s)
  local end_time=$((start_time + seconds))
  
  echo -ne "${LIGHT_GRAY}${label}...${RESET}"
  while true; do
    local now=$(date +%s)
    local remaining=$((end_time - now))
    
    if [[ $remaining -le 0 ]]; then
      echo -e " ${SOFT_GREEN}✓${RESET}"
      return 0
    fi
    
    # Анимация точек для обратного отсчёта
    local dots=$(( (seconds - remaining) % 4 ))
    local dot_str=""
    for ((i=0; i<dots; i++)); do dot_str+="."; done
    
    echo -ne "\r${LIGHT_GRAY}${label}${dot_str} (${remaining}s)${RESET}"
    sleep 0.5
  done
}

countdown_with_spinner() {
  local seconds="$1"
  local label="${2:-Операция}"
  local spinners=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local start_time=$(date +%s)
  local end_time=$((start_time + seconds))
  
  echo -ne "${LIGHT_GRAY}${label} ${spinners[0]}${RESET}"
  local i=0
  while true; do
    local now=$(date +%s)
    local remaining=$((end_time - now))
    
    if [[ $remaining -le 0 ]]; then
      echo -e "\r${LIGHT_GRAY}${label} ${SOFT_GREEN}✓${RESET}"
      return 0
    fi
    
    i=$(( (i + 1) % ${#spinners[@]} ))
    echo -ne "\r${LIGHT_GRAY}${label} ${spinners[$i]} (${remaining}s)${RESET}"
    sleep 0.1
  done
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
# Установка haveged с обратным отсчётом
# ============================================================================
ensure_entropy() {
  print_substep "Проверка энтропии"
  
  local entropy_avail
  entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
  
  print_info "Текущий уровень энтропии: ${entropy_avail}"
  
  if [[ "$entropy_avail" -lt 200 ]]; then
    print_warning "Низкая энтропия (< 200). Устанавливаем haveged..."
    
    # Обновление с таймаутом 20 сек
    if ! timeout 20 apt-get update >/dev/null 2>&1; then
      print_warning "apt update завершился с таймаутом, продолжаем"
    fi
    
    # Установка haveged с таймаутом 25 сек
    countdown_with_spinner 25 "Установка haveged"
    if ! timeout 25 DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends haveged >/dev/null 2>&1; then
      print_error "Не удалось установить haveged. Проверьте сетевое подключение."
    fi
    
    systemctl enable haveged --now >/dev/null 2>&1 || true
    print_success "haveged установлен и активирован"
    
    # Ожидание накопления энтропии с обратным отсчётом
    countdown 5 "Накопление энтропии"
    
    entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
    print_info "Энтропия после haveged: ${entropy_avail}"
    
    if [[ "$entropy_avail" -lt 100 ]]; then
      print_warning "Энтропия всё ещё низкая (${entropy_avail}). Продолжаем с риском."
    fi
  else
    print_success "Энтропия достаточна (${entropy_avail})"
  fi
}

# ============================================================================
# Установка зависимостей с уменьшенными таймаутами
# ============================================================================
ensure_dependency() {
  local pkg="$1"
  local cmd="${2:-$pkg}"
  
  if command -v "$cmd" &>/dev/null; then
    print_info "Зависимость '${pkg}' доступна"
    return 0
  fi
  
  if [[ "$cmd" == "-" ]]; then
    if dpkg -l | grep -q "^ii  $pkg "; then
      print_info "Пакет '${pkg}' уже установлен"
      return 0
    fi
  fi
  
  print_info "Установка: ${pkg}..."
  
  # Таймаут уменьшен до 120 секунд
  if ! timeout 120 sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' ${pkg} >/dev/null 2>&1"; then
    print_error "Не удалось установить ${pkg}. Проверьте сетевое подключение."
  fi
  
  # Проверка установки
  if [[ "$cmd" != "-" ]]; then
    local attempts=0
    while ! command -v "$cmd" &>/dev/null && [[ $attempts -lt 3 ]]; do
      sleep 1
      ((attempts++))
    done
    
    if ! command -v "$cmd" &>/dev/null; then
      print_error "После установки ${pkg} команда '${cmd}' недоступна"
    fi
  fi
  
  print_success "Установлено: ${pkg}"
}

get_process_on_port() {
  local port="$1"
  local proto="${2:-tcp}"
  
  if command -v ss &>/dev/null; then
    ss -nl"${proto:0:1}"p 2>/dev/null | awk -v port=":${port}" '$4 ~ port {print $7}' | head -n1 | cut -d',' -f2 | cut -d'=' -f2
  elif command -v netstat &>/dev/null; then
    netstat -nl"${proto:0:1}"p 2>/dev/null | awk -v port=":${port}" '$4 ~ port {print $7}' | head -n1 | cut -d'/' -f1
  else
    return 1
  fi
}

free_ports() {
  local ports=("80" "443")
  local proto="tcp"
  
  print_substep "Очистка портов 80/443..."
  
  for port in "${ports[@]}"; do
    local pid
    pid=$(get_process_on_port "$port" "$proto" || echo "")
    
    if [[ -z "$pid" || "$pid" == "1" || "$pid" == "-" ]]; then
      print_info "Порт ${port}/${proto} свободен"
      continue
    fi
    
    local proc_name
    if command -v ps &>/dev/null; then
      proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "PID ${pid}")
    else
      proc_name="PID ${pid}"
    fi
    
    print_warning "Порт ${port}/${proto} занят: ${proc_name} (PID ${pid})"
    
    local stopped=false
    for svc in nginx apache2 httpd caddy; do
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        print_info "Остановка ${svc}..."
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
        stopped=true
        break
      fi
    done
    
    if [[ "$stopped" == false ]]; then
      print_info "Принудительная остановка PID ${pid}..."
      kill -9 "$pid" 2>/dev/null || true
    fi
    
    local attempts=0
    while [[ -n "$(get_process_on_port "$port" "$proto" || echo "")" ]] && [[ $attempts -lt 5 ]]; do
      sleep 1
      ((attempts++))
    done
    
    if [[ -n "$(get_process_on_port "$port" "$proto" || echo "")" ]]; then
      print_error "Не удалось освободить порт ${port}/${proto}. Остановите процесс вручную: sudo kill -9 ${pid}"
    fi
    
    print_success "Порт ${port}/${proto} освобождён"
  done
}

# ============================================================================
# Системные оптимизации (без изменений)
# ============================================================================

optimize_swap() {
  print_substep "Настройка swap-пространства"
  
  local total_mem
  total_mem=$(free -m | awk '/^Mem:/ {print $2}')
  
  if [[ "$total_mem" -lt 2048 ]]; then
    if [[ ! -f /swapfile ]]; then
      local swap_size=$(( (2048 - total_mem) / 1024 + 1 ))
      print_info "Создание ${swap_size}G swap (RAM: ${total_mem}M)..."
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
# Безопасность (с уменьшенными таймаутами)
# ============================================================================

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
  
  # Таймаут уменьшен до 10 сек
  if ! timeout 10 ufw --force enable >/dev/null 2>&1; then
    print_warning "UFW активирован с предупреждениями"
  fi
  
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
  # Таймаут уменьшен до 8 сек
  if ! timeout 8 systemctl start fail2ban >/dev/null 2>&1; then
    print_warning "Fail2Ban запущен в фоне"
  fi
  
  sleep 1
  
  if systemctl is-active --quiet fail2ban; then
    print_success "Fail2Ban активен (защита SSH: 3 попытки → бан на 1 час)"
  else
    print_warning "Fail2Ban запущен в фоне (проверьте статус: systemctl status fail2ban)"
  fi
}

# ============================================================================
# Сайт для маскировки (с исправлением chown)
# ============================================================================

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

# ============================================================================
# Caddy (с исправлением URL)
# ============================================================================

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
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  fi
  
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
      > /etc/apt/sources.list.d/caddy-stable.list
  fi
  
  timeout 25 apt-get update >/dev/null 2>&1 || print_warning "apt update завершился с ошибкой, продолжаем"
  timeout 90 apt-get install -y caddy >/dev/null 2>&1 || print_error "Не удалось установить Caddy"
  
  print_success "Caddy установлен (версия: $(caddy version 2>/dev/null | head -n1 | cut -d' ' -f1))"
}

configure_caddy() {
  print_substep "Настройка Caddy (схема steal-itself)"
  
  if [[ -z "$DOMAIN" ]]; then
    print_error "Переменная DOMAIN не установлена"
  fi
  
  free_ports
  
  if [[ -f "$CADDYFILE" ]]; then
    cp "$CADDYFILE" "${CADDYFILE}.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  fi
  
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

${DOMAIN} {
  root * ${SITE_DIR}
  file_server
  encode zstd gzip
  log {
    output file /var/log/caddy/site.log
  }
}

http://127.0.0.1:8001 {
  root * ${SITE_DIR}
  file_server
  log {
    output file /var/log/caddy/fallback.log
  }
}
EOF
  
  print_info "Валидация конфигурации Caddy..."
  if ! caddy validate --config "$CADDYFILE" 2>&1; then
    print_error "Ошибка валидации Caddyfile"
  fi
  
  print_success "Конфигурация Caddy валидна"
  
  systemctl daemon-reload
  systemctl enable caddy --now >/dev/null 2>&1
  sleep 3
  
  if systemctl is-active --quiet caddy; then
    print_success "Caddy запущен (порты 80/443 активны)"
  else
    journalctl -u caddy -n 20 --no-pager > /tmp/caddy-errors.log 2>&1 || true
    print_error "Не удалось запустить Caddy. Проверьте логи: journalctl -u caddy -n 50"
  fi
}

# ============================================================================
# Xray (только официальный установщик)
# ============================================================================

install_xray() {
  print_substep "Установка Xray core (официальный установщик)"
  
  if command -v xray &>/dev/null; then
    local version
    version=$(xray version 2>/dev/null | head -n1 | cut -d' ' -f1-3 || echo "unknown")
    print_info "Xray уже установлен (версия: ${version})"
    return
  fi
  
  ensure_dependency "curl" "curl"
  
  print_info "Загрузка официального установщика Xray..."
  # Таймаут уменьшен до 45 сек
  if ! timeout 45 bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1; then
    print_error "Не удалось установить Xray официальным установщиком. Проверьте сетевое подключение."
  fi
  
  print_info "Установка геофайлов (geoip.dat, geosite.dat)..."
  # Таймаут уменьшен до 45 сек
  if ! timeout 45 bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata >/dev/null 2>&1; then
    print_warning "Не удалось установить геофайлы. Попытка повторной установки..."
    timeout 45 bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata || true
  fi
  
  local version
  version=$(xray version 2>/dev/null | head -n1 | cut -d' ' -f1-3 || echo "unknown")
  print_success "Xray установлен (версия: ${version})"
}

# ============================================================================
# ГЕНЕРАЦИЯ КЛЮЧЕЙ И UUID ТОЛЬКО ОФИЦИАЛЬНЫМИ СРЕДСТВАМИ
# ВАЖНО: ВСЕГДА НОВЫЙ UUID ПРИ КАЖДОЙ УСТАНОВКЕ
# ============================================================================
generate_xray_config() {
  print_substep "Генерация криптографических параметров"
  
  mkdir -p /usr/local/etc/xray
  mkdir -p "$XRAY_DAT_DIR"
  
  local secret_path uuid priv_key pub_key short_id
  
  # ============================================================================
  # ВАЖНО: ВСЕГДА ГЕНЕРИРУЕМ НОВЫЕ ПАРАМЕТРЫ ПРИ УСТАНОВКЕ
  # (даже если файлы существуют — это чистая переустановка)
  # ============================================================================
  
  secret_path=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
  
  # ГЕНЕРАЦИЯ НОВОГО UUID (всегда свежий!)
  uuid=$(cat /proc/sys/kernel/random/uuid)
  print_info "Сгенерирован новый UUID: ${uuid:0:8}..."
  
  # ============================================================================
  # ГЕНЕРАЦИЯ КЛЮЧЕЙ ТОЛЬКО ЧЕРЕЗ xray x25519 (без резервных ключей!)
  # ============================================================================
  
  print_info "Генерация X25519 ключей (таймаут: 15 секунд)..."
  
  local key_pair
  # Таймаут уменьшен до 15 секунд с визуальным отсчётом
  if ! countdown_with_spinner 15 "Генерация ключей Reality" && ! key_pair=$(timeout 15 xray x25519 2>&1); then
    print_error "Генерация ключей превысила таймаут (15 сек). Решение:
  sudo apt install haveged && sudo systemctl start haveged
  Затем повторите установку скрипта."
  fi
  
  # Извлечение ключей из вывода
  priv_key=$(echo "$key_pair" | grep -i "^PrivateKey" | awk '{print $NF}')
  pub_key=$(echo "$key_pair" | grep -i "^Password" | awk '{print $NF}')
  
  # Валидация ключей
  if [[ -z "$priv_key" || -z "$pub_key" ]]; then
    print_error "Не удалось извлечь ключи из вывода 'xray x25519'. Вывод:
${key_pair}"
  fi
  
  if [[ "${#priv_key}" -lt 40 || "${#pub_key}" -lt 40 ]]; then
    print_error "Некорректная длина ключей:
  PrivateKey (сервер): ${priv_key}
  Password/PublicKey (клиент): ${pub_key}"
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
  print_info "  • UUID: ${uuid:0:8}... (полный в ${XRAY_KEYS})"
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
  
  if systemctl is-active --quiet xray 2>/dev/null; then
    systemctl restart xray >/dev/null 2>&1
  else
    systemctl enable xray --now >/dev/null 2>&1
  fi
  
  sleep 3
  
  if systemctl is-active --quiet xray; then
    print_success "Xray запущен"
  else
    journalctl -u xray -n 20 --no-pager > /tmp/xray-errors.log 2>&1 || true
    print_error "Не удалось запустить Xray. Проверьте логи: journalctl -u xray -n 50"
  fi
}

# ============================================================================
# Автоматические обновления
# ============================================================================

setup_auto_updates() {
  print_step "Настройка автоматических обновлений"
  
  cat > /etc/systemd/system/xray-core-update.service <<'EOF_CORE_SERVICE'
[Unit]
Description=Update Xray Core to Latest Version
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s @ install'
User=root
StandardOutput=append:/var/log/xray-core-update.log
StandardError=append:/var/log/xray-core-update.log
EOF_CORE_SERVICE

  cat > /etc/systemd/system/xray-core-update.timer <<'EOF_CORE_TIMER'
[Unit]
Description=Weekly Xray Core Update (Official Installer)
After=network-online.target

[Timer]
OnCalendar=Sun 03:00
Persistent=true
Unit=xray-core-update.service

[Install]
WantedBy=timers.target
EOF_CORE_TIMER

  systemctl daemon-reload
  systemctl enable xray-core-update.timer --now >/dev/null 2>&1
  print_success "Автообновление ядра: каждое воскресенье 03:00"
  
  cat > /etc/systemd/system/xray-geo-update.service <<'EOF_GEO_SERVICE'
[Unit]
Description=Update Xray Geo Files (geoip.dat, geosite.dat)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s @ install-geodata'
User=root
StandardOutput=append:/var/log/xray-geo-update.log
StandardError=append:/var/log/xray-geo-update.log
EOF_GEO_SERVICE

  cat > /etc/systemd/system/xray-geo-update.timer <<'EOF_GEO_TIMER'
[Unit]
Description=Daily Xray Geo Files Update (Official Installer)
After=network-online.target

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=xray-geo-update.service

[Install]
WantedBy=timers.target
EOF_GEO_TIMER

  systemctl daemon-reload
  systemctl enable xray-geo-update.timer --now >/dev/null 2>&1
  print_success "Автообновление геофайлов: ежедневно 03:00"
  
  print_info "Ручное обновление ядра:   sudo systemctl start xray-core-update.service"
  print_info "Ручное обновление Geo:    sudo systemctl start xray-geo-update.service"
  print_info "Просмотр таймеров:        systemctl list-timers | grep xray"
  print_info "Логи обновлений:          /var/log/xray-*-update.log"
}

# ============================================================================
# Утилита управления пользователями (с генерацией нового UUID)
# ============================================================================

create_user_utility() {
  print_substep "Создание утилиты управления пользователями"
  
  ensure_dependency "qrencode" "qrencode"
  
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
    
    # ГЕНЕРАЦИЯ НОВОГО UUID ДЛЯ КАЖДОГО ПОЛЬЗОВАТЕЛЯ
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)
    
    jq --arg e "${email}" --arg u "${uuid}" '.inbounds[0].settings.clients += [{"id": $u, "email": $e}]' "${XRAY_CONFIG}" > /tmp/x.tmp && mv /tmp/x.tmp "${XRAY_CONFIG}"
    systemctl restart xray &>/dev/null || echo "Предупреждение: не удалось перезапустить xray"
    local link
    link=$(generate_link "${uuid}" "${email}")
    echo -e "\n✅ Пользователь '${email}' создан"
    echo -e "UUID: ${uuid}"
    echo -e "\nСсылка для подключения:\n${link}"
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
    echo "✅ Пользователь '${clients[$((num-1))]}' удалён"
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
    echo -e "\nСсылка для ${clients[$((num-1))]}:\n${link}"
    command -v qrencode &>/dev/null && { echo -e "\nQR-код:"; echo "${link}" | qrencode -t ansiutf8; }
    ;;
  help|*)
    cat <<HELP
Управление пользователями Xray:

  user list    Показать список клиентов
  user qr      QR-код основного пользователя
  user add     Добавить нового пользователя (с новым UUID)
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
  user add     Создать нового пользователя (всегда с новым UUID)
  user rm      Удалить пользователя
  user link    Сгенерировать ссылку подключения

АВТОМАТИЧЕСКИЕ ОБНОВЛЕНИЯ
  • Ядро Xray:   каждое воскресенье в 03:00
  • Геофайлы:    ежедневно в 03:00
  
  Ручное обновление ядра:   sudo systemctl start xray-core-update.service
  Ручное обновление Geo:    sudo systemctl start xray-geo-update.service
  Статус таймеров:          systemctl list-timers | grep xray
  Логи обновлений:          /var/log/xray-*-update.log

ВАЖНЫЕ ФАЙЛЫ
  Конфигурация:  /usr/local/etc/xray/config.json
  Ключи/Параметры: /usr/local/etc/xray/.keys (включая уникальный UUID)
  Geo-файлы:     /usr/local/share/xray/{geoip,geosite}.dat
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

КРИТИЧЕСКИ ВАЖНО: КЛЮЧИ REALITY
  • PrivateKey (вывод 'xray x25519'): приватный ключ → в конфиг сервера (privateKey)
  • Password (вывод 'xray x25519'): ПУБЛИЧНЫЙ ключ → для клиента (параметр pbk в ссылке)
  • Не путайте поля! Название "Password" в выводе вводит в заблуждение.

УНИКАЛЬНЫЙ UUID
  • При каждой установке генерируется НОВЫЙ UUID для основного пользователя
  • При добавлении пользователей через 'user add' также генерируется новый UUID
  • UUID хранится в /usr/local/etc/xray/.keys и /usr/local/etc/xray/config.json
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
  
  # ============================================================================
  # УСТАНОВКА HAVEGED С ОБРАТНЫМ ОТСЧЁТОМ
  # ============================================================================
  print_step "Подготовка системы (энтропия)"
  ensure_entropy
  
  # Глобальные переменные для apt
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
  
  # Обновление списка пакетов с таймаутом 25 сек
  countdown_with_spinner 25 "Обновление списка пакетов"
  if ! timeout 25 apt-get update >/dev/null 2>&1; then
    print_warning "apt update завершился с таймаутом, продолжаем с текущим кэшем"
  fi
  
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
  generate_xray_config  # ← Генерация НОВОГО UUID и ключей каждый раз
  
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
  echo -e "  Выполните: ${BOLD}user qr${RESET} для получения ссылки подключения"
  echo
  
  echo -e "${BOLD}Управление:${RESET}"
  echo -e "  ${MEDIUM_GRAY}user list${RESET}    # Список клиентов"
  echo -e "  ${MEDIUM_GRAY}user add${RESET}     # Создать пользователя (с новым UUID)"
  echo -e "  ${MEDIUM_GRAY}user qr${RESET}      # QR-код основного пользователя"
  echo -e "  ${MEDIUM_GRAY}cat ~/help${RESET}   # Полная документация"
  echo
  
  echo -e "${BOLD}Автоматические обновления:${RESET}"
  echo -e "  • Ядро Xray:   каждое воскресенье 03:00"
  echo -e "  • Геофайлы:    ежедневно 03:00"
  echo
  
  echo -e "${SOFT_YELLOW}⚠${RESET} SSL-сертификат будет автоматически получен при первом обращении к ${BOLD}https://${DOMAIN}${RESET}"
  echo
  echo -e "${LIGHT_GRAY}Лог установки: ${LOG_FILE}${RESET}"
  echo
}

main "$@"
