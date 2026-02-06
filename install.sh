#!/bin/bash
set -euo pipefail

# ============================================================================
# Xray VLESS/XHTTP/Reality Installer
# Идемпотентная установка с обновлением системы + правильные оптимизации
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
  
  # Если вывод не в терминал — просто выполняем без анимации
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
      (head -n 5 "$output_file" 2>/dev/null | sed "s/^/  ${MEDIUM_GRAY}│${RESET} /" || echo ""); echo -e "  ${MEDIUM_GRAY}⋮${RESET}"; tail -n 15 "$output_file" 2>/dev/null | sed "s/^/  ${MEDIUM_GRAY}│${RESET} /"
      echo
    fi
    
    # Диагностика распространённых проблем
    if grep -qi "unable to locate package\|not found" "$output_file" 2>/dev/null; then
      echo -e "${SOFT_YELLOW}💡 Совет:${RESET} Обновите список пакетов: sudo apt update"
    elif grep -qi "connection timed out\|failed to fetch\|network is unreachable" "$output_file" 2>/dev/null; then
      echo -e "${SOFT_YELLOW}💡 Совет:${RESET} Проверьте сетевое подключение: ping -c 3 8.8.8.8"
    elif grep -qi "no space left\|disk full\|not enough disk space" "$output_file" 2>/dev/null; then
      echo -e "${SOFT_YELLOW}💡 Совет:${RESET} Освободите место на диске: df -h /"
    elif grep -qi "public key is not available\|NO_PUBKEY" "$output_file" 2>/dev/null; then
      echo -e "${SOFT_YELLOW}💡 Совет:${RESET} Импортируйте ключи: sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys <KEY_ID>"
    fi
    
    rm -f "$output_file"
    return $exit_code
  fi
}

# ============================================================================
# ИДЕМПОТЕНТНАЯ УСТАНОВКА ЗАВИСИМОСТЕЙ
# ============================================================================
ensure_dependency() {
  local pkg="$1"
  local cmd="${2:-$pkg}"
  
  # Проверка наличия команды или пакета
  if [[ "$cmd" != "-" ]]; then
    if command -v "$cmd" &>/dev/null; then
      print_info "Зависимость '${pkg}' уже установлена"
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
# Вспомогательные функции (определены ДО их использования)
# ============================================================================

check_root() {
  [[ "$EUID" -eq 0 ]] || print_error "Скрипт должен запускаться от имени root (используйте sudo)"
}

get_public_ip() {
  curl -4s https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}' | cut -d' ' -f1
}

# ============================================================================
# ИДЕМПОТЕНТНОЕ ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================================================
update_system() {
  print_step "Обновление системы"
  
  # Проверка места на диске
  local free_mb
  free_mb=$(df / --output=avail | tail -n1 | awk '{print int($1/1024)}')
  if [[ "$free_mb" -lt 300 ]]; then
    print_warning "Мало места на диске: ${free_mb} МБ (рекомендуется >300 МБ для обновлений)"
    read -p "Продолжить обновление? [y/N]: " confirm < /dev/tty 2>/dev/null || { echo; exit 1; }
    [[ ! "$confirm" =~ ^[Yy]$ ]] && print_error "Установка прервана из-за нехватки места на диске"
  fi
  
  # Обновление списка пакетов
  run_with_spinner "apt-get update -qq" "Обновление списка пакетов" 0 || \
    print_error "Не удалось обновить список пакетов. Проверьте сетевое подключение."
  
  # Обновление системы (без интерактивных запросов)
  print_info "Установка обновлений безопасности и пакетов..."
  if ! run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'" "Обновление системы" 0; then
    print_warning "Обновление системы завершилось с ошибками. Продолжаем установку Xray."
  fi
  
  # Проверка необходимости перезагрузки
  if [[ -f /var/run/reboot-required ]]; then
    print_warning "Требуется перезагрузка системы после обновления ядра или критических библиотек!"
    echo -e "${SOFT_YELLOW}⚠${RESET} Файл-маркер перезагрузки: /var/run/reboot-required"
    echo -e "${SOFT_YELLOW}⚠${RESET} Рекомендуется выполнить:"
    echo -e "      sudo reboot"
    echo
    echo -e "${LIGHT_GRAY}Скрипт приостановлен до перезагрузки.${RESET}"
    echo -e "${LIGHT_GRAY}После перезагрузки запустите скрипт повторно:${RESET}"
    echo -e "      sudo bash install.sh"
    echo
    exit 0
  else
    print_success "Система обновлена. Перезагрузка не требуется."
  fi
}

# ============================================================================
# ИДЕМПОТЕНТНАЯ ПОДГОТОВКА СИСТЕМЫ (энтропия)
# ============================================================================
prepare_system() {
  print_substep "Проверка энтропии"
  
  local entropy_avail
  entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
  print_info "Уровень энтропии: ${entropy_avail}"
  
  if [[ "$entropy_avail" -lt 200 ]] && ! command -v haveged &>/dev/null; then
    print_warning "Низкая энтропия (< 200). Устанавливаем haveged..."
    
    run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends haveged" "Установка haveged" 0 || \
      print_error "Не удалось установить haveged"
    
    systemctl enable haveged --now >/dev/null 2>&1 || true
    sleep 2
    
    entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
    print_info "Энтропия после haveged: ${entropy_avail}"
  elif [[ "$entropy_avail" -ge 200 ]]; then
    print_success "Энтропия достаточна (${entropy_avail})"
  else
    print_info "haveged уже установлен"
  fi
}

# ============================================================================
# ИДЕМПОТЕНТНАЯ ОПТИМИЗАЦИЯ SWAP (ПРАВИЛЬНАЯ ЛОГИКА)
# ============================================================================
optimize_swap() {
  print_substep "Настройка swap-пространства"
  
  # Проверка существования активного swap
  if swapon --show | grep -q .; then
    print_info "Swap уже настроен и активен"
    return 0
  fi
  
  local total_mem
  total_mem=$(free -m | awk '/^Mem:/ {print $2}')
  
  # ПРАВИЛЬНАЯ ЛОГИКА РАСЧЁТА РАЗМЕРА SWAP
  local swap_size_gb=0
  if [[ "$total_mem" -le 1024 ]]; then
    swap_size_gb=2
    print_info "RAM ≤ 1 ГБ → настройка 2 ГБ swap"
  elif [[ "$total_mem" -le 2048 ]]; then
    swap_size_gb=1
    print_info "RAM ≤ 2 ГБ → настройка 1 ГБ swap"
  elif [[ "$total_mem" -le 4096 ]]; then
    swap_size_gb=0.5
    print_info "RAM ≤ 4 ГБ → настройка 512 МБ swap"
  else
    swap_size_gb=0.5
    print_info "RAM > 4 ГБ → настройка 512 МБ swap (рекомендуется)"
  fi
  
  # Создание swap-файла
  if [[ ! -f /swapfile ]]; then
    print_info "Создание ${swap_size_gb}G swap (RAM: ${total_mem}M)..."
    
    local bs_size count
    if [[ "$swap_size_gb" == "0.5" ]]; then
      bs_size="512M"
      count=1
    else
      bs_size="1G"
      count="$swap_size_gb"
    fi
    
    if ! run_with_spinner "dd if=/dev/zero of=/swapfile bs=${bs_size} count=${count} status=none 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile" "Создание swap-файла" 0; then
      print_error "Не удалось создать swap-файл"
    fi
    
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    print_success "Swap настроен (${swap_size_gb}G)"
  else
    print_info "Swap-файл существует, активация..."
    swapon /swapfile 2>/dev/null || true
    print_success "Swap активирован"
  fi
}

# ============================================================================
# ИДЕМПОТЕНТНАЯ ОПТИМИЗАЦИЯ СЕТИ (BBR)
# ============================================================================
optimize_network() {
  print_substep "Оптимизация сетевого стека"
  
  local current_cc
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  
  if [[ "$current_cc" == "bbr" ]]; then
    print_info "BBR уже включён"
    return 0
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
  
  if ! run_with_spinner "sysctl -p /etc/sysctl.d/99-xray-tuning.conf" "Применение настроек сети" 0; then
    print_error "Не удалось применить сетевые настройки"
  fi
  
  print_success "Сетевой стек оптимизирован (BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown'))"
}

# ============================================================================
# ИДЕМПОТЕНТНАЯ ОПТИМИЗАЦИЯ SSD (ПРОВЕРКА ЧЕРЕЗ lsblk --discard)
# ============================================================================
configure_trim() {
  print_substep "Проверка и настройка TRIM для SSD"
  
  # ПРОВЕРКА ПОДДЕРЖКИ TRIM ЧЕРЕЗ lsblk --discard
  local trim_supported=0
  if command -v lsblk &>/dev/null; then
    trim_supported=$(lsblk --discard -no DISC-GRAN 2>/dev/null | awk '$1 != "0B" && $1 != "" {count++} END {print count+0}')
  fi
  
  if [[ "$trim_supported" -eq 0 ]]; then
    print_info "TRIM не поддерживается дисками или требуется ручная настройка"
    return 0
  fi
  
  # Проверка статуса fstrim.timer
  if systemctl is-active --quiet fstrim.timer 2>/dev/null; then
    print_info "TRIM уже настроен и активен (обнаружено ${trim_supported} диск(а) с поддержкой TRIM)"
    return 0
  fi
  
  # Активация TRIM
  print_info "Обнаружено ${trim_supported} диск(а) с поддержкой TRIM"
  
  if ! run_with_spinner "systemctl enable fstrim.timer --now" "Активация TRIM" 0; then
    print_warning "Не удалось активировать TRIM (продолжаем без него)"
    return 0
  fi
  
  print_success "TRIM активирован для дисков с поддержкой"
}

# ============================================================================
# ИДЕМПОТЕНТНАЯ НАСТРОЙКА ФАЕРВОЛА (ИСПРАВЛЕНА ОШИБКА С ПОРТАМИ)
# ============================================================================
configure_firewall() {
  print_substep "Настройка фаервола UFW"
  
  # Проверка установки
  if ! command -v ufw &>/dev/null; then
    run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw" "Установка UFW" 0 || \
      print_error "Не удалось установить UFW"
  fi
  
  # Отключение IPv6 если недоступен
  if ! ip6tables -L &>/dev/null 2>&1; then
    if grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
      print_warning "IPv6 недоступен, отключаем поддержку IPv6 в UFW"
      sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
    fi
  fi
  
  # Проверка активности и необходимых портов (ИСПРАВЛЕНА ОШИБКА)
  if ufw status | grep -q "Status: active"; then
    print_info "UFW уже активен"
    
    # КОРРЕКТНАЯ ПРОВЕРКА ПОРТОВ (без синтаксической ошибки)
    local has_22=$(ufw status | grep -c "22/tcp.*ALLOW" || echo 0)
    local has_80=$(ufw status | grep -c "80/tcp.*ALLOW" || echo 0)
    local has_443=$(ufw status | grep -c "443/tcp.*ALLOW" || echo 0)
    
    if [[ $has_22 -gt 0 && $has_80 -gt 0 && $has_443 -gt 0 ]]; then
      print_success "Фаервол активен (порты 22/80/443 открыты)"
      return 0
    fi
    
    print_info "Добавление недостающих правил..."
  fi
  
  # Настройка правил
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  ufw allow 22/tcp comment "SSH" >/dev/null 2>&1 || true
  ufw allow 80/tcp comment "HTTP (ACME/Caddy)" >/dev/null 2>&1 || true
  ufw allow 443/tcp comment "HTTPS (Xray)" >/dev/null 2>&1 || true
  
  # Активация
  if ! ufw status | grep -q "Status: active"; then
    run_with_spinner "ufw --force enable" "Активация UFW" 0 || \
      print_warning "UFW активирован с предупреждениями"
  fi
  
  if ufw status | grep -q "Status: active"; then
    print_success "Фаервол активен (порты 22/80/443 открыты)"
  else
    print_warning "UFW активирован с предупреждениями"
  fi
}

# ============================================================================
# ИДЕМПОТЕНТНАЯ НАСТРОЙКА FAIL2BAN
# ============================================================================
configure_fail2ban() {
  print_substep "Настройка Fail2Ban"
  
  # Проверка установки
  if ! command -v fail2ban-client &>/dev/null; then
    run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fail2ban" "Установка Fail2Ban" 0 || \
      print_error "Не удалось установить Fail2Ban"
  fi
  
  # Проверка активности
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    print_info "Fail2Ban уже активен"
    return 0
  fi
  
  # Создание конфигурации если отсутствует
  if [[ ! -f /etc/fail2ban/jail.local ]]; then
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
  fi
  
  # Активация
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

# ============================================================================
# СОЗДАНИЕ МАСКИРОВОЧНОГО САЙТА (ОДНА СТРАНИЦА)
# ============================================================================
create_masking_site() {
  print_substep "Создание маскировочного сайта (одна страница)"
  
  mkdir -p "$SITE_DIR"
  
  # Современный лендинг с инлайн CSS/JS — всё в одном файле
  cat > "$SITE_DIR/index.html" <<'EOF_SITE'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Cloud Infrastructure Services</title>
  <meta name="description" content="Enterprise-grade cloud infrastructure with 99.9% uptime guarantee">
  <style>
    :root{--primary:#5f87ff;--secondary:#7171ff;--light:#f8f9fa;--dark:#212529;--gray:#6c757d}
    *{margin:0;padding:0;box-sizing:border-box}
    body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;line-height:1.6;color:var(--dark);background:var(--light)}
    .container{width:100%;max-width:1200px;margin:0 auto;padding:0 2rem}
    header{background:linear-gradient(135deg,var(--primary),var(--secondary));color:#fff;padding:3rem 0;text-align:center}
    header h1{font-size:2.5rem;margin-bottom:1rem}
    header p{font-size:1.25rem;max-width:650px;margin:0 auto;color:rgba(255,255,255,0.9)}
    .features{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:2rem;margin:4rem 0}
    .card{background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 10px 30px rgba(0,0,0,0.08);transition:transform .3s ease,box-shadow .3s ease}
    .card:hover{transform:translateY(-8px);box-shadow:0 15px 40px rgba(0,0,0,0.15)}
    .card-icon{height:6rem;background:linear-gradient(135deg,var(--primary),var(--secondary));display:flex;align-items:center;justify-content:center;color:#fff;font-size:2rem}
    .card-content{padding:2rem}
    .card h2{color:var(--primary);margin-bottom:1rem;font-size:1.5rem}
    .card p{color:var(--gray);margin-bottom:1.5rem}
    .card a{display:inline-block;background:var(--primary);color:#fff;text-decoration:none;padding:0.75rem 1.5rem;border-radius:8px;font-weight:500;transition:background .2s ease}
    .card a:hover{background:var(--secondary)}
    footer{background:var(--dark);color:#adb5bd;padding:2.5rem 0;text-align:center;margin-top:4rem}
    footer p{margin-bottom:1rem}
    footer .legal{font-size:0.9rem;color:#6c757d}
    @media (max-width:768px){
      header h1{font-size:2rem}
      header p{font-size:1.1rem}
      .container{padding:0 1.5rem}
      .features{grid-template-columns:1fr}
    }
  </style>
</head>
<body>
  <header>
    <div class="container">
      <h1>Cloud Infrastructure Services</h1>
      <p>Enterprise-grade cloud solutions with 99.9% uptime guarantee and DDoS protection</p>
    </div>
  </header>
  
  <div class="container">
    <section class="features">
      <div class="card">
        <div class="card-icon">⚡</div>
        <div class="card-content">
          <h2>High Performance</h2>
          <p>NVMe storage and 10Gbps network for maximum throughput and minimal latency.</p>
          <a href="#learn-more">Learn More</a>
        </div>
      </div>
      
      <div class="card">
        <div class="card-icon">🛡️</div>
        <div class="card-content">
          <h2>Advanced Security</h2>
          <p>Multi-layer DDoS protection and end-to-end encryption for all your traffic.</p>
          <a href="#security">Security Details</a>
        </div>
      </div>
      
      <div class="card">
        <div class="card-icon">⚙️</div>
        <div class="card-content">
          <h2>24/7 Support</h2>
          <p>Round-the-clock technical support with average response time under 15 minutes.</p>
          <a href="#support">Contact Us</a>
        </div>
      </div>
    </section>
  </div>
  
  <footer>
    <div class="container">
      <p>© 2026 Cloud Infrastructure Services. All rights reserved.</p>
      <p class="legal">This is a legitimate business website hosting cloud infrastructure services.</p>
    </div>
  </footer>
  
  <script>
    // Простая анимация для повышения легитимности
    document.addEventListener('DOMContentLoaded', () => {
      const cards = document.querySelectorAll('.card');
      cards.forEach((card, index) => {
        setTimeout(() => {
          card.style.opacity = '0';
          card.style.transform = 'translateY(20px)';
          card.style.transition = 'opacity 0.5s ease, transform 0.5s ease';
          
          setTimeout(() => {
            card.style.opacity = '1';
            card.style.transform = 'translateY(0)';
          }, 100 + index * 150);
        }, 300);
      });
    });
  </script>
</body>
</html>
EOF_SITE

  # Минимальные дополнительные файлы для легитимности
  echo -e "User-agent: *\nDisallow: /admin/\nDisallow: /wp-admin/" > "$SITE_DIR/robots.txt"
  printf '\x00' > "$SITE_DIR/favicon.ico" 2>/dev/null || true
  
  # ИСПРАВЛЕНО: опечатка www-www-data → www-data
  chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || true
  chmod -R 755 "$SITE_DIR"
  
  print_success "Маскировочный сайт создан (${SITE_DIR}/index.html)"
}

# ============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================
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
# УСТАНОВКА И НАСТРОЙКА CADDY (идемпотентная)
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
  
  # Проверка установки
  if command -v caddy &>/dev/null; then
    print_info "Caddy уже установлен (версия: $(caddy version 2>/dev/null | head -n1 | cut -d' ' -f1))"
    return 0
  fi
  
  # Установка зависимостей
  for pkg in debian-keyring debian-archive-keyring apt-transport-https curl gnupg; do
    ensure_dependency "$pkg" "-"
  done
  
  # Импорт ключа
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    run_with_spinner "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" "Импорт ключа Caddy" 0 || \
      print_error "Не удалось импортировать ключ Caddy"
  fi
  
  # Настройка репозитория
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
      > /etc/apt/sources.list.d/caddy-stable.list
    run_with_spinner "apt-get update -qq" "Обновление списка пакетов (Caddy)" 0 || true
  fi
  
  # Установка Caddy
  run_with_spinner "apt-get install -y caddy" "Установка Caddy" 0 || \
    print_error "Не удалось установить Caddy"
  
  print_success "Caddy установлен (версия: $(caddy version 2>/dev/null | head -n1 | cut -d' ' -f1))"
}

configure_caddy() {
  print_substep "Настройка Caddy (схема steal-itself)"
  
  if [[ -z "$DOMAIN" ]]; then
    print_error "Переменная DOMAIN не установлена"
  fi
  
  # Очистка портов
  free_ports
  
  # Резервная копия существующего конфига
  if [[ -f "$CADDYFILE" ]]; then
    cp "$CADDYFILE" "${CADDYFILE}.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  fi
  
  # Генерация конфигурации
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
  
  # Валидация
  print_info "Валидация конфигурации Caddy..."
  if ! run_with_spinner "caddy validate --config $CADDYFILE" "Валидация Caddyfile" 0; then
    print_error "Ошибка валидации Caddyfile"
  fi
  
  # Запуск
  systemctl daemon-reload
  systemctl enable caddy --now >/dev/null 2>&1 || true
  sleep 3
  
  if systemctl is-active --quiet caddy; then
    print_success "Caddy запущен (порты 80/443 активны)"
  else
    journalctl -u caddy -n 20 --no-pager > /tmp/caddy-errors.log 2>&1 || true
    print_error "Не удалось запустить Caddy. Проверьте логи: journalctl -u caddy -n 50"
  fi
}

# ============================================================================
# НАСТРОЙКА ДОМЕНА
# ============================================================================
prompt_domain() {
  print_step "Настройка домена"
  
  # 1. Переменная окружения
  if [[ -n "$DOMAIN" ]]; then
    print_info "Домен из переменной окружения: ${DOMAIN}"
    validate_and_set_domain "$DOMAIN"
    return
  fi
  
  # 2. Существующая конфигурация
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
  
  # 3. Интерактивный запрос
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
# УСТАНОВКА XRAY (идемпотентная, но с новым UUID при чистой установке)
# ============================================================================
install_xray() {
  print_substep "Установка Xray core (официальный установщик)"
  
  # Проверка установки
  if command -v xray &>/dev/null; then
    local version
    version=$(xray version 2>/dev/null | head -n1 | cut -d' ' -f1-3 || echo "unknown")
    print_info "Xray уже установлен (версия: ${version})"
    return 0
  fi
  
  # Установка curl если отсутствует
  ensure_dependency "curl" "curl"
  
  # Установка Xray
  print_info "Загрузка официального установщика Xray..."
  if ! run_with_spinner "bash -c \"\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install" "Установка Xray core" 0; then
    print_error "Не удалось установить Xray официальным установщиком"
  fi
  
  # Установка геофайлов
  print_info "Установка геофайлов (geoip.dat, geosite.dat)..."
  if ! run_with_spinner "bash -c \"\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install-geodata" "Установка геофайлов" 0; then
    print_warning "Не удалось установить геофайлы. Повторная попытка..."
    run_with_spinner "bash -c \"\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install-geodata" "Повторная установка геофайлов" 0 || true
  fi
  
  local version
  version=$(xray version 2>/dev/null | head -n1 | cut -d' ' -f1-3 || echo "unknown")
  print_success "Xray установлен (версия: ${version})"
}

generate_xray_config() {
  print_substep "Генерация криптографических параметров"
  
  mkdir -p /usr/local/etc/xray
  mkdir -p "$XRAY_DAT_DIR"
  
  local secret_path uuid priv_key pub_key short_id
  
  # Проверка существования параметров
  if [[ -f "$XRAY_KEYS" ]]; then
    print_info "Использование существующих параметров из ${XRAY_KEYS}"
    secret_path=$(grep "^path:" "$XRAY_KEYS" | awk '{print $2}' | sed 's|/||')
    uuid=$(grep "^uuid:" "$XRAY_KEYS" | awk '{print $2}')
    priv_key=$(grep "^private_key:" "$XRAY_KEYS" | awk '{print $2}')
    pub_key=$(grep "^public_key:" "$XRAY_KEYS" | awk '{print $2}')
    short_id=$(grep "^short_id:" "$XRAY_KEYS" | awk '{print $2}')
  else
    # ГЕНЕРАЦИЯ НОВЫХ ПАРАМЕТРОВ (чистая установка)
    secret_path=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    print_info "Сгенерирован новый UUID: ${uuid:0:8}..."
    
    # Генерация ключей с таймаутом 20 сек
    print_info "Генерация X25519 ключей..."
    local key_pair
    if ! key_pair=$(run_with_spinner "xray x25519" "Генерация ключей Reality" 20); then
      print_error "Генерация ключей превысила лимит (20 сек). Установите haveged и повторите."
    fi
    
    # Извлечение ключей
    priv_key=$(echo "$key_pair" | grep -i "^PrivateKey" | awk '{print $NF}')
    pub_key=$(echo "$key_pair" | grep -i "^Password" | awk '{print $NF}')
    
    if [[ -z "$priv_key" || -z "$pub_key" || "${#priv_key}" -lt 40 || "${#pub_key}" -lt 40 ]]; then
      print_error "Некорректные ключи (PrivateKey: ${priv_key:0:12}..., PublicKey: ${pub_key:0:12}...)"
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
    
    print_success "Сгенерированы новые параметры:"
  fi
  
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
  
  # Валидация
  print_info "Валидация конфигурации Xray..."
  if ! run_with_spinner "xray test --config $XRAY_CONFIG" "Валидация конфигурации" 0; then
    print_error "Ошибка валидации конфигурации Xray"
  fi
  
  print_success "Конфигурация Xray валидна"
  
  # Запуск
  if systemctl is-active --quiet xray 2>/dev/null; then
    run_with_spinner "systemctl restart xray" "Перезапуск Xray" 0 || \
      print_error "Не удалось перезапустить Xray"
  else
    run_with_spinner "systemctl enable xray --now" "Запуск Xray" 0 || \
      print_error "Не удалось запустить Xray"
  fi
  
  if systemctl is-active --quiet xray; then
    print_success "Xray запущен"
  else
    journalctl -u xray -n 20 --no-pager > /tmp/xray-errors.log 2>&1 || true
    print_error "Не удалось запустить Xray. Проверьте: journalctl -u xray -n 50"
  fi
}

# ============================================================================
# АВТОМАТИЧЕСКИЕ ОБНОВЛЕНИЯ
# ============================================================================
setup_auto_updates() {
  print_step "Настройка автоматических обновлений"
  
  # Еженедельное обновление ядра
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

  # Ежедневное обновление геофайлов
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

  # Активация таймеров
  systemctl daemon-reload
  systemctl enable xray-core-update.timer --now >/dev/null 2>&1 || true
  systemctl enable xray-geo-update.timer --now >/dev/null 2>&1 || true
  
  print_success "Автообновление ядра: каждое воскресенье 03:00"
  print_success "Автообновление геофайлов: ежедневно 03:00"
  
  print_info "Ручное обновление ядра:   sudo systemctl start xray-core-update.service"
  print_info "Ручное обновление Geo:    sudo systemctl start xray-geo-update.service"
  print_info "Просмотр таймеров:        systemctl list-timers | grep xray"
}

# ============================================================================
# УТИЛИТА УПРАВЛЕНИЯ ПОЛЬЗОВАТЕЛЯМИ
# ============================================================================
create_user_utility() {
  print_substep "Создание утилиты управления пользователями"
  
  # Установка qrencode если отсутствует
  if ! command -v qrencode &>/dev/null; then
    ensure_dependency "qrencode" "qrencode"
  fi
  
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
    
    # ГЕНЕРАЦИЯ НОВОГО UUID
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
  Сайт маскировки: /var/www/html/index.html (единая страница)

СЕРВИСЫ
  Xray:   systemctl {start|stop|restart|status} xray
  Caddy:  systemctl {start|stop|restart|status} caddy
  Логи:   journalctl -u xray -f

СИСТЕМНЫЕ ОПТИМИЗАЦИИ
  • BBR: включён для максимальной скорости передачи
  • Сетевой стек: настроен для высокой нагрузки
  • Fail2Ban: защищает SSH (3 попытки → бан на 1 час)
  • UFW: фаервол активен (порты 22/80/443)
  • TRIM: активирован для дисков с поддержкой (проверка через lsblk --discard)
  • Swap: настроен по правилам:
      ≤ 1 ГБ RAM → 2 ГБ swap
      ≤ 2 ГБ RAM → 1 ГБ swap
      ≤ 4 ГБ RAM → 512 МБ swap
      > 4 ГБ RAM → 512 МБ swap

МАСКИРОВКА ТРАФИКА (схема steal-itself)
  • Публичные запросы → профессиональный лендинг (единая страница)
  • Невалидные XHTTP-пути → тот же лендинг через fallback
  • Валидные XHTTP-пути → прямой доступ в интернет
  • Весь трафик выглядит как легитимные посещения сайта

КРИТИЧЕСКИ ВАЖНО: КЛЮЧИ REALITY
  • PrivateKey (вывод 'xray x25519'): приватный ключ → в конфиг сервера (privateKey)
  • Password (вывод 'xray x25519'): ПУБЛИЧНЫЙ ключ → для клиента (параметр pbk в ссылке)
  • Не путайте поля! Название "Password" в выводе вводит в заблуждение.

УНИКАЛЬНЫЙ UUID
  • При чистой установке (отсутствует /usr/local/etc/xray/.keys) генерируется НОВЫЙ UUID
  • При повторном запуске скрипта сохраняются существующие параметры (идемпотентность)
  • При добавлении пользователей через 'user add' генерируется новый уникальный UUID
EOF_HELP
  
  chmod 644 "$HELP_FILE"
  print_success "Файл справки создан (${HELP_FILE})"
}

# ============================================================================
# ОСНОВНОЕ ВЫПОЛНЕНИЕ
# ============================================================================

main() {
  echo -e "\n${BOLD}${SOFT_BLUE}Xray VLESS/XHTTP/Reality Installer${RESET}"
  echo -e "${LIGHT_GRAY}Идемпотентная установка с обновлением системы${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  echo -e "${LIGHT_GRAY}Лог установки: ${LOG_FILE}${RESET}\n"
  
  check_root
  
  # ============================================================================
  # 1. ОБНОВЛЕНИЕ СИСТЕМЫ (с проверкой перезагрузки)
  # ============================================================================
  update_system
  
  # ============================================================================
  # 2. ПОДГОТОВКА СИСТЕМЫ
  # ============================================================================
  prepare_system
  
  export DEBIAN_FRONTEND=noninteractive
  export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1
  
  # ============================================================================
  # 3. СИСТЕМНЫЕ ОПТИМИЗАЦИИ (идемпотентные)
  # ============================================================================
  print_step "Системные оптимизации"
  optimize_swap
  optimize_network
  configure_trim
  
  # ============================================================================
  # 4. НАСТРОЙКА ДОМЕНА
  # ============================================================================
  prompt_domain
  
  # ============================================================================
  # 5. БЕЗОПАСНОСТЬ (идемпотентная)
  # ============================================================================
  print_step "Безопасность системы"
  configure_firewall
  configure_fail2ban
  
  # ============================================================================
  # 6. УСТАНОВКА ЗАВИСИМОСТЕЙ (все функции уже определены!)
  # ============================================================================
  print_step "Установка зависимостей"
  
  local deps=("curl" "jq" "socat" "git" "wget" "gnupg" "ca-certificates" "unzip" "iproute2" "openssl")
  for dep in "${deps[@]}"; do
    ensure_dependency "$dep" "$dep"
  done
  
  print_success "Все зависимости установлены"
  
  # ============================================================================
  # 7. МАСКИРОВОЧНЫЙ САЙТ (одна страница)
  # ============================================================================
  print_step "Сайт для маскировки трафика"
  create_masking_site
  
  # ============================================================================
  # 8. ВЕБ-СЕРВЕР CADDY
  # ============================================================================
  print_step "Веб-сервер Caddy"
  install_caddy
  configure_caddy
  
  # ============================================================================
  # 9. XRAY CORE
  # ============================================================================
  print_step "Xray Core"
  install_xray
  generate_xray_config
  
  # ============================================================================
  # 10. АВТОМАТИЧЕСКИЕ ОБНОВЛЕНИЯ
  # ============================================================================
  print_step "Автоматические обновления"
  setup_auto_updates
  
  # ============================================================================
  # 11. УТИЛИТЫ УПРАВЛЕНИЯ
  # ============================================================================
  print_step "Утилиты управления"
  create_user_utility
  create_help_file
  
  # ============================================================================
  # ФИНАЛЬНЫЙ ОТЧЁТ
  # ============================================================================
  echo -e "\n${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${SOFT_GREEN}Установка завершена успешно${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  
  echo -e "${BOLD}Домен:${RESET}       ${DOMAIN}"
  echo -e "${BOLD}IP-адрес:${RESET}    ${SERVER_IP}"
  echo -e "${BOLD}Сайт:${RESET}        https://${DOMAIN}"
  echo
  
  echo -e "${BOLD}Основной пользователь:${RESET}"
  if [[ -f "$XRAY_KEYS" ]]; then
    echo -e "  UUID: $(grep '^uuid:' ${XRAY_KEYS} 2>/dev/null | awk '{print $2}' | cut -c1-8)..."
  fi
  echo -e "  Ссылка: ${BOLD}user qr${RESET}"
  echo
  
  echo -e "${BOLD}Управление:${RESET}"
  echo -e "  ${MEDIUM_GRAY}user list${RESET}    # Список клиентов"
  echo -e "  ${MEDIUM_GRAY}user add${RESET}     # Новый пользователь (с уникальным UUID)"
  echo -e "  ${MEDIUM_GRAY}user qr${RESET}      # QR-код подключения"
  echo -e "  ${MEDIUM_GRAY}cat ~/help${RESET}   # Документация"
  echo
  
  echo -e "${BOLD}Системные оптимизации:${RESET}"
  echo -e "  • BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown')"
  echo -e "  • TRIM: $(systemctl is-active fstrim.timer 2>/dev/null || echo 'неактивен')"
  echo -e "  • Swap: $(swapon --show | grep -c '^' || echo '0') активных устройства(й)"
  echo
  
  echo -e "${SOFT_YELLOW}ℹ${RESET} SSL-сертификат будет получен автоматически при первом запросе к ${BOLD}https://${DOMAIN}${RESET}"
  echo -e "${LIGHT_GRAY}Полный лог: ${LOG_FILE}${RESET}"
  echo
  
  echo -e "${SOFT_GREEN}✓${RESET} ${BOLD}Готово!${RESET} Для проверки работы:"
  echo -e "  • Статус Xray:   ${MEDIUM_GRAY}systemctl status xray${RESET}"
  echo -e "  • Статус Caddy:  ${MEDIUM_GRAY}systemctl status caddy${RESET}"
  echo -e "  • Тест подключения: ${MEDIUM_GRAY}curl -I https://${DOMAIN}${RESET}"
  echo
}

main "$@"
