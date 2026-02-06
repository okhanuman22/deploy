#!/bin/bash
set -euo pipefail

# ============================================================================
# Xray VLESS/XHTTP/Reality Installer
# Живая анимация • Корректный маппинг пакетов • Полная идемпотентность
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
# УЛУЧШЕННЫЙ СПИННЕР С ВРЕМЕНЕМ И ПРОГРЕССОМ
# ============================================================================
run_with_spinner() {
  local cmd="$1"
  local label="${2:-Выполнение}"
  local timeout_sec="${3:-0}"
  local show_progress="${4:-false}"
  
  # Если не терминал — без анимации
  if [[ ! -t 1 ]]; then
    bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"
    return $?
  fi
  
  local spinners=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local pid=""
  local output_file="/tmp/spinner_out_$$"
  local start_time=$(date +%s)
  touch "$output_file"
  
  # Запуск команды
  if [[ "$show_progress" == "true" ]]; then
    bash -c "$cmd" 2>&1 | tee "$output_file" &
  else
    bash -c "$cmd" &> "$output_file" &
  fi
  pid=$!
  
  # Анимация с отображением времени
  while kill -0 "$pid" 2>/dev/null; do
    local elapsed=$(( $(date +%s) - start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local time_str
    [[ $mins -gt 0 ]] && time_str="${mins}m${secs}s" || time_str="${secs}s"
    
    # Прогресс для apt
    local progress=""
    if [[ "$show_progress" == "true" ]]; then
      local pct=$(tail -n 30 "$output_file" 2>/dev/null | grep -oE '[0-9]+%' | tail -n1 || echo "")
      [[ -n "$pct" ]] && progress=" ${pct}"
    fi
    
    i=$(( (i + 1) % ${#spinners[@]} ))
    printf "\r${LIGHT_GRAY}${label} ${spinners[$i]}${progress} (${time_str})${RESET}"
    sleep 0.1
    
    # Таймаут
    if [[ "$timeout_sec" -gt 0 && $elapsed -ge $timeout_sec ]]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      printf "\r\033[K${SOFT_RED}✗${RESET} ${label} (таймаут ${timeout_sec}s)\n"
      return 1
    fi
  done
  
  wait "$pid" 2>/dev/null
  local exit_code=$?
  printf "\r\033[K"
  
  if [[ $exit_code -eq 0 ]]; then
    local elapsed=$(( $(date +%s) - start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local time_str
    [[ $mins -gt 0 ]] && time_str="${mins}m${secs}s" || time_str="${secs}s"
    
    echo -e "${SOFT_GREEN}✓${RESET} ${label} (${time_str})"
    rm -f "$output_file"
    return 0
  else
    echo -e "${SOFT_RED}✗${RESET} ${label}"
    
    # Детали ошибки
    if [[ -s "$output_file" ]]; then
      echo -e "\n${SOFT_RED}Детали:${RESET}"
      tail -n 15 "$output_file" | sed "s/^/  ${MEDIUM_GRAY}│${RESET} /"
      echo
    fi
    
    rm -f "$output_file"
    return $exit_code
  fi
}

# ============================================================================
# ИДЕМПОТЕНТНАЯ УСТАНОВКА ЗАВИСИМОСТЕЙ (КОРРЕКТНЫЙ МАППИНГ)
# ============================================================================
ensure_dependency() {
  local pkg="$1"
  local cmd="${2:-$pkg}"
  
  # Проверка для пакетов БЕЗ команды
  if [[ "$cmd" == "-" ]]; then
    if dpkg -l | grep -q "^ii.* $pkg "; then
      print_info "✓ ${pkg}"
      return 0
    fi
  else
    # Проверка для пакетов С командой
    if command -v "$cmd" &>/dev/null; then
      print_info "✓ ${pkg}"
      return 0
    fi
  fi
  
  # Установка
  if ! run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $pkg" "Установка ${pkg}" 120; then
    print_error "Не удалось установить ${pkg}"
  fi
  
  # Финальная проверка
  if [[ "$cmd" != "-" ]] && ! command -v "$cmd" &>/dev/null; then
    print_error "Команда '${cmd}' недоступна после установки ${pkg}"
  fi
  
  print_success "${pkg}"
}

# ============================================================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
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
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================================

check_root() {
  [[ "$EUID" -eq 0 ]] || print_error "Запускайте от root (sudo)"
}

get_public_ip() {
  curl -4s https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}' | cut -d' ' -f1
}

# ============================================================================
# ОБНОВЛЕНИЕ СИСТЕМЫ С ЖИВЫМ ПРОГРЕССОМ
# ============================================================================
update_system() {
  print_step "Обновление системы"
  
  # Проверка места на диске
  local free_mb
  free_mb=$(df / --output=avail | tail -n1 | awk '{print int($1/1024)}')
  if [[ "$free_mb" -lt 300 ]]; then
    print_warning "Мало места: ${free_mb} МБ (рекомендуется >300 МБ)"
    read -p "Продолжить? [y/N]: " confirm < /dev/tty 2>/dev/null || { echo; exit 1; }
    [[ ! "$confirm" =~ ^[Yy]$ ]] && print_error "Установка прервана"
  fi
  
  # Обновление списка пакетов
  run_with_spinner "apt-get update -q" "Обновление списка пакетов" 60 || \
    print_error "Не удалось обновить список пакетов"
  
  # Обновление системы с прогрессом
  print_info "Установка обновлений безопасности..."
  if ! run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'" "Установка обновлений" 600 "true"; then
    print_warning "Обновление завершилось с ошибками. Продолжаем установку."
  fi
  
  # Проверка перезагрузки
  if [[ -f /var/run/reboot-required ]]; then
    print_warning "Требуется перезагрузка после обновления ядра"
    echo -e "${SOFT_YELLOW}⚠${RESET} Выполните: ${BOLD}sudo reboot${RESET}"
    echo -e "${LIGHT_GRAY}Скрипт приостановлен. Запустите после перезагрузки.${RESET}"
    exit 0
  fi
  
  print_success "Система обновлена"
}

# ============================================================================
# ПОДГОТОВКА СИСТЕМЫ (ЭНТРОПИЯ)
# ============================================================================
prepare_system() {
  print_substep "Энтропия"
  
  local entropy_avail
  entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
  
  if [[ "$entropy_avail" -lt 200 ]] && ! command -v haveged &>/dev/null; then
    run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get install -y -q haveged" "Установка haveged" 30 || \
      print_error "Не удалось установить haveged"
    systemctl enable haveged --now &>/dev/null || true
    sleep 2
  fi
  
  entropy_avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo 0)
  if [[ "$entropy_avail" -ge 200 ]]; then
    print_success "Энтропия: ${entropy_avail}"
  else
    print_warning "Энтропия: ${entropy_avail} (низкая, но продолжаем)"
  fi
}

# ============================================================================
# ОПТИМИЗАЦИЯ SWAP (ПРАВИЛЬНАЯ ЛОГИКА)
# ============================================================================
optimize_swap() {
  print_substep "Swap"
  
  if swapon --show | grep -q .; then
    print_info "✓ Уже настроен"
    return 0
  fi
  
  local total_mem
  total_mem=$(free -m | awk '/^Mem:/ {print $2}')
  local swap_size_gb=0.5
  
  if [[ "$total_mem" -le 1024 ]]; then
    swap_size_gb=2
    print_info "RAM ≤ 1 ГБ → 2 ГБ swap"
  elif [[ "$total_mem" -le 2048 ]]; then
    swap_size_gb=1
    print_info "RAM ≤ 2 ГБ → 1 ГБ swap"
  elif [[ "$total_mem" -le 4096 ]]; then
    swap_size_gb=0.5
    print_info "RAM ≤ 4 ГБ → 512 МБ swap"
  else
    print_info "RAM > 4 ГБ → 512 МБ swap"
  fi
  
  if [[ ! -f /swapfile ]]; then
    local bs count
    if [[ "$swap_size_gb" == "0.5" ]]; then
      bs="512M"
      count=1
    else
      bs="1G"
      count="$swap_size_gb"
    fi
    
    run_with_spinner "dd if=/dev/zero of=/swapfile bs=$bs count=$count status=none 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile" "Создание swap" 60 || \
      print_error "Не удалось создать swap"
    
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    swapon /swapfile &>/dev/null || true
  fi
  
  print_success "Swap активен"
}

# ============================================================================
# ОПТИМИЗАЦИЯ СЕТИ (BBR)
# ============================================================================
optimize_network() {
  print_substep "Сеть (BBR)"
  
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')" == "bbr" ]]; then
    print_info "✓ Уже включён"
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
  
  run_with_spinner "sysctl -p /etc/sysctl.d/99-xray-tuning.conf &>/dev/null" "Применение настроек" 10 || \
    print_error "Не удалось применить сетевые настройки"
  
  print_success "BBR активен"
}

# ============================================================================
# ОПТИМИЗАЦИЯ SSD (TRIM ЧЕРЕЗ lsblk --discard)
# ============================================================================
configure_trim() {
  print_substep "TRIM (SSD)"
  
  local trim_supported=0
  if command -v lsblk &>/dev/null; then
    trim_supported=$(lsblk --discard -no DISC-GRAN 2>/dev/null | awk '$1 != "0B" && $1 != "" {count++} END {print count+0}' || echo 0)
  fi
  
  if [[ "$trim_supported" -eq 0 ]]; then
    print_info "Не поддерживается дисками"
    return 0
  fi
  
  if systemctl is-active --quiet fstrim.timer 2>/dev/null; then
    print_info "✓ Активен (${trim_supported} диск(а))"
    return 0
  fi
  
  run_with_spinner "systemctl enable fstrim.timer --now &>/dev/null" "Активация TRIM" 10 || \
    print_warning "Не удалось активировать TRIM"
  
  print_success "TRIM активирован"
}

# ============================================================================
# ФАЕРВОЛ (ИСПРАВЛЕНА ПРОВЕРКА ПОРТОВ)
# ============================================================================
configure_firewall() {
  print_substep "Фаервол (UFW)"
  
  if ! command -v ufw &>/dev/null; then
    ensure_dependency "ufw" "ufw"
  fi
  
  # Отключение IPv6 если недоступен
  if ! ip6tables -L &>/dev/null 2>&1 && grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null
  fi
  
  # НАДЕЖНАЯ ПРОВЕРКА ПОРТОВ (без синтаксических ошибок)
  local status_output
  status_output=$(ufw status verbose 2>/dev/null || echo "")
  
  local has_22=0 has_80=0 has_443=0
  [[ "$status_output" == *"22/tcp"*"ALLOW"* ]] && has_22=1
  [[ "$status_output" == *"80/tcp"*"ALLOW"* ]] && has_80=1
  [[ "$status_output" == *"443/tcp"*"ALLOW"* ]] && has_443=1
  
  if ufw status | grep -q "Status: active" && [[ $has_22 -eq 1 && $has_80 -eq 1 && $has_443 -eq 1 ]]; then
    print_info "✓ Активен (22/80/443 открыты)"
    return 0
  fi
  
  # Настройка правил
  ufw default deny incoming &>/dev/null || true
  ufw default allow outgoing &>/dev/null || true
  ufw allow 22/tcp comment "SSH" &>/dev/null || true
  ufw allow 80/tcp comment "HTTP" &>/dev/null || true
  ufw allow 443/tcp comment "HTTPS" &>/dev/null || true
  
  if ! ufw status | grep -q "Status: active"; then
    run_with_spinner "ufw --force enable &>/dev/null" "Активация UFW" 15 || true
  fi
  
  print_success "UFW активен"
}

# ============================================================================
# FAIL2BAN
# ============================================================================
configure_fail2ban() {
  print_substep "Fail2Ban"
  
  if ! command -v fail2ban-client &>/dev/null; then
    ensure_dependency "fail2ban" "fail2ban-client"
  fi
  
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    print_info "✓ Уже активен"
    return 0
  fi
  
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
  
  systemctl enable fail2ban &>/dev/null || true
  run_with_spinner "systemctl start fail2ban &>/dev/null" "Запуск Fail2Ban" 10 || true
  
  sleep 1
  if systemctl is-active --quiet fail2ban; then
    print_success "Fail2Ban активен"
  else
    print_warning "Fail2Ban запущен в фоне"
  fi
}

# ============================================================================
# МАСКИРОВОЧНЫЙ САЙТ (ОДНА СТРАНИЦА)
# ============================================================================
create_masking_site() {
  print_substep "Маскировочный сайт"
  
  mkdir -p "$SITE_DIR"
  
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
    document.addEventListener('DOMContentLoaded', () => {
      document.querySelectorAll('.card').forEach((card, i) => {
        setTimeout(() => {
          card.style.opacity = '0';
          card.style.transform = 'translateY(20px)';
          card.style.transition = 'opacity 0.5s, transform 0.5s';
          setTimeout(() => {
            card.style.opacity = '1';
            card.style.transform = 'translateY(0)';
          }, 100);
        }, 300 + i * 150);
      });
    });
  </script>
</body>
</html>
EOF_SITE

  echo -e "User-agent: *\nDisallow: /admin/" > "$SITE_DIR/robots.txt"
  printf '\x00' > "$SITE_DIR/favicon.ico" 2>/dev/null || true
  
  # ИСПРАВЛЕНО: опечатка www-www-data → www-data
  chown -R www-www-data "$SITE_DIR" 2>/dev/null || true
  chmod -R 755 "$SITE_DIR"
  
  print_success "Сайт создан"
}

# ============================================================================
# УСТАНОВКА CADDY (КОРРЕКТНЫЙ МАППИНГ ПАКЕТОВ)
# ============================================================================
install_caddy() {
  print_substep "Caddy"
  
  # Остановка конфликтующих сервисов
  for svc in nginx apache2 httpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      systemctl stop "$svc" &>/dev/null
      systemctl disable "$svc" &>/dev/null
    fi
  done
  
  # Проверка установки
  if command -v caddy &>/dev/null; then
    print_info "✓ Уже установлен ($(caddy version | head -n1 | cut -d' ' -f1))"
    return 0
  fi
  
  # УСТАНОВКА ЗАВИСИМОСТЕЙ С КОРРЕКТНЫМ МАППИНГОМ
  ensure_dependency "debian-keyring" "-"                # ← Пакет без команды
  ensure_dependency "debian-archive-keyring" "-"         # ← Пакет без команды
  ensure_dependency "apt-transport-https" "-"            # ← Пакет без команды
  ensure_dependency "curl" "curl"
  ensure_dependency "gnupg" "gpg"                        # ← gnupg → команда gpg
  
  # Импорт ключа Caddy
  if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
    run_with_spinner "curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" "Импорт ключа Caddy" 15 || \
      print_error "Не удалось импортировать ключ Caddy"
  fi
  
  # Настройка репозитория
  if [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]]; then
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy-stable.list
    run_with_spinner "apt-get update -qq" "Обновление списка пакетов" 30
  fi
  
  # Установка Caddy
  run_with_spinner "apt-get install -y -qq caddy" "Установка Caddy" 60 || \
    print_error "Не удалось установить Caddy"
  
  print_success "Caddy установлен ($(caddy version | head -n1 | cut -d' ' -f1))"
}

configure_caddy() {
  print_substep "Настройка Caddy"
  
  [[ -z "$DOMAIN" ]] && print_error "DOMAIN не установлен"
  
  # Очистка портов
  for port in 80 443; do
    local pid
    pid=$(ss -tlnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $7}' | head -n1 | cut -d',' -f2 | cut -d'=' -f2 || echo "")
    if [[ -n "$pid" && "$pid" != "1" && "$pid" != "-" ]]; then
      kill -9 "$pid" 2>/dev/null || true
      sleep 1
    fi
  done
  
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
}

http://127.0.0.1:8001 {
  root * ${SITE_DIR}
  file_server
}
EOF
  
  # Валидация
  if ! output=$(caddy validate --config "$CADDYFILE" 2>&1); then
    print_error "Ошибка валидации Caddyfile:\n$output"
  fi
  
  systemctl daemon-reload
  systemctl enable caddy --now &>/dev/null || true
  sleep 3
  
  if systemctl is-active --quiet caddy; then
    print_success "Caddy запущен"
  else
    print_error "Не удалось запустить Caddy (проверьте: journalctl -u caddy -n 20)"
  fi
}

# ============================================================================
# НАСТРОЙКА ДОМЕНА
# ============================================================================
prompt_domain() {
  print_step "Домен"
  
  # Переменная окружения
  if [[ -n "$DOMAIN" ]]; then
    validate_and_set_domain "$DOMAIN"
    return
  fi
  
  # Существующая конфигурация
  if [[ -f "$XRAY_CONFIG" ]] && command -v jq &>/dev/null; then
    local existing_domain
    existing_domain=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0] // empty' "$XRAY_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$existing_domain" && "$existing_domain" != "null" ]]; then
      DOMAIN="$existing_domain"
      SERVER_IP=$(get_public_ip)
      print_info "Используется домен из конфигурации: ${DOMAIN}"
      return
    fi
  fi
  
  # Интерактивный запрос
  echo -e "${BOLD}Домен${RESET} (wishnu.duckdns.org):"
  read -r DOMAIN < /dev/tty
  DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
  [[ -z "$DOMAIN" || ! "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && print_error "Неверный формат домена"
  
  validate_and_set_domain "$DOMAIN"
}

validate_and_set_domain() {
  local input_domain="$1"
  local ipv4
  ipv4=$(host -t A "$input_domain" 2>/dev/null | awk '/has address/ {print $4; exit}' || echo "")
  
  if [[ -z "$ipv4" ]]; then
    read -p "DNS не найден. Продолжить? [y/N]: " confirm < /dev/tty 2>/dev/null || { echo; exit 1; }
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
  fi
  
  SERVER_IP=$(get_public_ip)
  if [[ -n "$ipv4" && "$ipv4" != "$SERVER_IP" ]]; then
    read -p "DNS (${ipv4}) ≠ IP (${SERVER_IP}). Продолжить? [y/N]: " confirm < /dev/tty 2>/dev/null || { echo; exit 1; }
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
  fi
  
  DOMAIN="$input_domain"
  print_success "Домен: ${DOMAIN} → ${SERVER_IP}"
}

# ============================================================================
# УСТАНОВКА XRAY
# ============================================================================
install_xray() {
  print_substep "Xray Core"
  
  if command -v xray &>/dev/null; then
    print_info "✓ Уже установлен ($(xray version | head -n1 | cut -d' ' -f1-3))"
    return 0
  fi
  
  ensure_dependency "curl" "curl"
  
  run_with_spinner "bash -c \"\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install" "Установка Xray" 120 || \
    print_error "Не удалось установить Xray"
  
  run_with_spinner "bash -c \"\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install-geodata" "Установка геофайлов" 60 || true
  
  print_success "Xray установлен ($(xray version | head -n1 | cut -d' ' -f1-3))"
}

generate_xray_config() {
  print_substep "Генерация конфигурации"
  
  mkdir -p /usr/local/etc/xray "$XRAY_DAT_DIR"
  
  local secret_path uuid priv_key pub_key short_id
  
  if [[ -f "$XRAY_KEYS" ]]; then
    secret_path=$(grep "^path:" "$XRAY_KEYS" | awk '{print $2}' | sed 's|/||')
    uuid=$(grep "^uuid:" "$XRAY_KEYS" | awk '{print $2}')
    priv_key=$(grep "^private_key:" "$XRAY_KEYS" | awk '{print $2}')
    pub_key=$(grep "^public_key:" "$XRAY_KEYS" | awk '{print $2}')
    short_id=$(grep "^short_id:" "$XRAY_KEYS" | awk '{print $2}')
    print_info "Используются существующие параметры"
  else
    secret_path=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    
    # Генерация ключей с таймаутом
    local key_pair
    if ! key_pair=$(run_with_spinner "xray x25519 2>/dev/null" "Генерация ключей" 20); then
      print_error "Генерация ключей превысила 20 сек. Установите haveged и повторите."
    fi
    
    priv_key=$(echo "$key_pair" | grep -i "^PrivateKey" | awk '{print $NF}')
    pub_key=$(echo "$key_pair" | grep -i "^Password" | awk '{print $NF}')
    
    if [[ -z "$priv_key" || -z "$pub_key" || "${#priv_key}" -lt 40 || "${#pub_key}" -lt 40 ]]; then
      print_error "Некорректные ключи (PrivateKey: ${priv_key:0:12}..., PublicKey: ${pub_key:0:12}...)"
    fi
    
    short_id=$(openssl rand -hex 4)
    
    {
      echo "path: /${secret_path}"
      echo "uuid: ${uuid}"
      echo "private_key: ${priv_key}"
      echo "public_key: ${pub_key}"
      echo "short_id: ${short_id}"
    } > "$XRAY_KEYS"
    chmod 600 "$XRAY_KEYS"
    
    print_success "Сгенерированы новые параметры"
  fi
  
  # Генерация конфигурации
  cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
      {"type": "field", "ip": ["geoip:private", "geoip:cn"], "outboundTag": "block"}
    ]
  },
  "inbounds": [
    {
      "listen": "@xhttp",
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [{"id": "${uuid}", "email": "main"}]
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "${secret_path}"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    },
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "fallbacks": [{"dest": "@xhttp"}]
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
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF
  
  chown -R xray:xray /usr/local/etc/xray 2>/dev/null || true
  chmod 644 "$XRAY_CONFIG"
  
  # Валидация
  if ! output=$(xray test --config "$XRAY_CONFIG" 2>&1); then
    print_error "Ошибка валидации Xray:\n$output"
  fi
  
  # Запуск
  if systemctl is-active --quiet xray 2>/dev/null; then
    run_with_spinner "systemctl restart xray &>/dev/null" "Перезапуск Xray" 10 || \
      print_error "Не удалось перезапустить Xray"
  else
    run_with_spinner "systemctl enable xray --now &>/dev/null" "Запуск Xray" 10 || \
      print_error "Не удалось запустить Xray"
  fi
  
  sleep 3
  
  if systemctl is-active --quiet xray; then
    print_success "Xray запущен"
  else
    print_error "Не удалось запустить Xray (проверьте: journalctl -u xray -n 20)"
  fi
}

# ============================================================================
# АВТООБНОВЛЕНИЯ
# ============================================================================
setup_auto_updates() {
  print_step "Автообновления"
  
  cat > /etc/systemd/system/xray-core-update.service <<'EOF'
[Unit]
Description=Update Xray Core
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s @ install'
User=root
EOF
  
  cat > /etc/systemd/system/xray-core-update.timer <<'EOF'
[Unit]
Description=Weekly Xray Core Update
After=network-online.target
[Timer]
OnCalendar=Sun 03:00
Persistent=true
Unit=xray-core-update.service
[Install]
WantedBy=timers.target
EOF
  
  cat > /etc/systemd/system/xray-geo-update.service <<'EOF'
[Unit]
Description=Update Xray Geo Files
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s @ install-geodata'
User=root
EOF
  
  cat > /etc/systemd/system/xray-geo-update.timer <<'EOF'
[Unit]
Description=Daily Xray Geo Files Update
After=network-online.target
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=xray-geo-update.service
[Install]
WantedBy=timers.target
EOF
  
  systemctl daemon-reload
  systemctl enable xray-core-update.timer xray-geo-update.timer --now &>/dev/null || true
  
  print_success "Автообновления настроены"
}

# ============================================================================
# УТИЛИТА УПРАВЛЕНИЯ
# ============================================================================
create_user_utility() {
  print_substep "Утилита управления"
  
  if ! command -v qrencode &>/dev/null; then
    ensure_dependency "qrencode" "qrencode"
  fi
  
  cat > /usr/local/bin/user <<'EOF_SCRIPT'
#!/bin/bash
set -euo pipefail
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_KEYS="/usr/local/etc/xray/.keys"
ACTION="${1:-help}"
get_params() {
  local sp pk sid dom port ip
  sp=$(grep "^path:" "$XRAY_KEYS" | awk '{print $2}' | sed 's|/||' 2>/dev/null || echo "secret")
  pk=$(grep "^public_key:" "$XRAY_KEYS" | awk '{print $2}' 2>/dev/null || echo "pubkey")
  sid=$(grep "^short_id:" "$XRAY_KEYS" | awk '{print $2}' 2>/dev/null || echo "shortid")
  dom=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0] // "example.com"' "$XRAY_CONFIG" 2>/dev/null)
  port=$(jq -r '.inbounds[1].port // "443"' "$XRAY_CONFIG" 2>/dev/null)
  ip=$(curl -4s https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
  echo "${sp}|${pk}|${sid}|${dom}|${port}|${ip}"
}
generate_link() {
  local uuid="$1" email="$2"
  IFS='|' read -r sp pk sid dom port ip < <(get_params 2>/dev/null || echo "|||example.com|443|127.0.0.1")
  echo "vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${pk}&fp=chrome&sni=${dom}&sid=${sid}&type=xhttp&path=%2F${sp}&host=&spx=%2F#${email}"
}
case "$ACTION" in
  list) jq -r '.inbounds[0].settings.clients[] | "\(.email) (\(.id))"' "$XRAY_CONFIG" 2>/dev/null | nl -w3 -s'. ' || echo "Нет клиентов" ;;
  qr) uuid=$(jq -r '.inbounds[0].settings.clients[] | select(.email=="main") | .id' "$XRAY_CONFIG" 2>/dev/null || echo ""); [[ -z "$uuid" ]] && exit 1; link=$(generate_link "$uuid" "main"); echo -e "\nСсылка:\n$link\n"; command -v qrencode &>/dev/null && echo "QR:" && echo "$link" | qrencode -t ansiutf8 ;;
  add) read -p "Имя: " email < /dev/tty; [[ -z "$email" || "$email" =~ [^a-zA-Z0-9_-] ]] && exit 1; jq -e ".inbounds[0].settings.clients[] | select(.email==\"$email\")" "$XRAY_CONFIG" &>/dev/null && exit 1; uuid=$(cat /proc/sys/kernel/random/uuid); jq --arg e "$email" --arg u "$uuid" '.inbounds[0].settings.clients += [{"id": $u, "email": $e}]' "$XRAY_CONFIG" > /tmp/x.tmp && mv /tmp/x.tmp "$XRAY_CONFIG"; systemctl restart xray &>/dev/null || true; link=$(generate_link "$uuid" "$email"); echo -e "\n✅ ${email} создан\nUUID: ${uuid}\n\nСсылка:\n$link"; command -v qrencode &>/dev/null && echo -e "\nQR:" && echo "$link" | qrencode -t ansiutf8 ;;
  rm) mapfile -t cl < <(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG" 2>/dev/null || echo ""); [[ ${#cl[@]} -lt 2 ]] && exit 1; for i in "${!cl[@]}"; do echo "$((i+1)). ${cl[$i]}"; done; read -p "Номер: " n < /dev/tty; [[ ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 || "$n" -gt ${#cl[@]} || "${cl[$((n-1))]}" == "main" ]] && exit 1; jq --arg e "${cl[$((n-1))]}" '(.inbounds[0].settings.clients) |= map(select(.email != $e))' "$XRAY_CONFIG" > /tmp/x.tmp && mv /tmp/x.tmp "$XRAY_CONFIG"; systemctl restart xray &>/dev/null || true; echo "✅ ${cl[$((n-1))]} удалён" ;;
  link) mapfile -t cl < <(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONFIG" 2>/dev/null || echo ""); [[ ${#cl[@]} -eq 0 ]] && exit 1; for i in "${!cl[@]}"; do echo "$((i+1)). ${cl[$i]}"; done; read -p "Номер: " n < /dev/tty; [[ ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 || "$n" -gt ${#cl[@]} ]] && exit 1; uuid=$(jq -r --arg e "${cl[$((n-1))]}" '.inbounds[0].settings.clients[] | select(.email==$e) | .id' "$XRAY_CONFIG" 2>/dev/null || echo ""); [[ -z "$uuid" ]] && exit 1; link=$(generate_link "$uuid" "${cl[$((n-1))]}"); echo -e "\nСсылка:\n$link"; command -v qrencode &>/dev/null && echo -e "\nQR:" && echo "$link" | qrencode -t ansiutf8 ;;
  *) cat <<HELP
user list    Список клиентов
user qr      QR основного пользователя
user add     Новый пользователь
user rm      Удалить пользователя
user link    Ссылка для клиента
HELP
    ;;
esac
EOF_SCRIPT
  
  chmod +x /usr/local/bin/user
  print_success "Утилита 'user' установлена"
}

create_help_file() {
  cat > "$HELP_FILE" <<'EOF_HELP'
Xray (VLESS/XHTTP/Reality) — управление
========================================

ОСНОВНЫЕ КОМАНДЫ
  user list    Список клиентов
  user qr      QR-код подключения
  user add     Новый пользователь (с уникальным UUID)
  user rm      Удалить пользователя

АВТООБНОВЛЕНИЯ
  • Ядро: каждое воскресенье 03:00
  • Геофайлы: ежедневно 03:00
  • Ручной запуск: systemctl start xray-core-update.service

ФАЙЛЫ
  Конфиг:      /usr/local/etc/xray/config.json
  Параметры:   /usr/local/etc/xray/.keys
  Сайт:        /var/www/html/index.html
  Логи:        /var/log/xray-installer.log

СЕРВИСЫ
  Xray:  systemctl {status|restart} xray
  Caddy: systemctl {status|restart} caddy

МАСКИРОВКА
  Схема: steal-itself
  • Публичные запросы → легитимный лендинг
  • Валидные XHTTP-пути → прямой доступ в интернет

КЛЮЧИ REALITY
  • PrivateKey → в конфиг сервера (privateKey)
  • Password (вывод x25519) → ПУБЛИЧНЫЙ ключ для клиента (pbk)
EOF_HELP
  
  chmod 644 "$HELP_FILE"
  print_success "Файл помощи: ${HELP_FILE}"
}

# ============================================================================
# ОСНОВНОЕ ВЫПОЛНЕНИЕ
# ============================================================================

main() {
  echo -e "\n${BOLD}${SOFT_BLUE}Xray VLESS/XHTTP/Reality Installer${RESET}"
  echo -e "${LIGHT_GRAY}Живая анимация • Корректный маппинг пакетов • Полная идемпотентность${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  
  check_root
  
  # 1. Обновление системы
  update_system
  
  # 2. Подготовка системы
  prepare_system
  export DEBIAN_FRONTEND=noninteractive
  
  # 3. Системные оптимизации
  print_step "Системные оптимизации"
  optimize_swap
  optimize_network
  configure_trim
  
  # 4. Настройка домена
  prompt_domain
  
  # 5. Безопасность
  print_step "Безопасность"
  configure_firewall
  configure_fail2ban
  
  # 6. Установка зависимостей (КОРРЕКТНЫЙ МАППИНГ!)
  print_step "Зависимости"
  ensure_dependency "curl" "curl"
  ensure_dependency "jq" "jq"
  ensure_dependency "socat" "socat"
  ensure_dependency "git" "git"
  ensure_dependency "wget" "wget"
  ensure_dependency "gnupg" "gpg"          # ← gnupg → gpg (НЕ gnupg!)
  ensure_dependency "ca-certificates" "-"  # ← Пакет без команды
  ensure_dependency "unzip" "unzip"
  ensure_dependency "iproute2" "ss"        # ← iproute2 → ss (НЕ iproute2!)
  ensure_dependency "openssl" "openssl"
  ensure_dependency "haveged" "haveged"
  print_success "Все зависимости установлены"
  
  # 7. Маскировочный сайт
  print_step "Маскировка"
  create_masking_site
  
  # 8. Caddy
  print_step "Caddy"
  install_caddy
  configure_caddy
  
  # 9. Xray
  print_step "Xray"
  install_xray
  generate_xray_config
  
  # 10. Автообновления
  setup_auto_updates
  
  # 11. Утилиты
  print_step "Утилиты"
  create_user_utility
  create_help_file
  
  # ФИНАЛ
  echo -e "\n${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${SOFT_GREEN}✓ Установка завершена${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  
  echo -e "${BOLD}Домен:${RESET}  https://${DOMAIN}"
  echo -e "${BOLD}IP:${RESET}     ${SERVER_IP}"
  echo -e "${BOLD}UUID:${RESET}   $(grep '^uuid:' ${XRAY_KEYS} 2>/dev/null | awk '{print $2}' | cut -c1-8)..."
  echo
  echo -e "Подключение: ${BOLD}user qr${RESET}"
  echo -e "Документация: ${BOLD}cat ~/help${RESET}"
  echo
  echo -e "${SOFT_YELLOW}ℹ${RESET} SSL-сертификат будет получен автоматически при первом запросе к ${BOLD}https://${DOMAIN}${RESET}"
  echo
}

main "$@"
