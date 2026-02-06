#!/bin/bash
set -euo pipefail
# ============================================================================
# Xray VLESS/XHTTP/Reality Installer (v2.10 — исправлена генерация конфига)
# ============================================================================
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
  echo -e "
${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${SOFT_BLUE}▸ ${1}${RESET}"
  echo -e "${DARK_GRAY}───────────────────────────────────────────────────────────────────────────────${RESET}
"
}

print_success() { echo -e "${SOFT_GREEN}✓${RESET} ${1}"; }
print_warning() { echo -e "${SOFT_YELLOW}⚠${RESET} ${1}"; }
print_error() {
  echo -e "
${SOFT_RED}✗${RESET} ${BOLD}${1}${RESET}
" >&2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
  exit 1
}
print_info() { echo -e "${LIGHT_GRAY}ℹ${RESET} ${1}"; }
print_substep() { echo -e "${MEDIUM_GRAY}  →${RESET} ${1}"; }

run_with_spinner() {
  local cmd="$1"
  local label="${2:-Выполнение}"
  if [[ ! -t 1 ]]; then
    bash -c "$cmd" &>/dev/null || return $?
    return 0
  fi
  local spinners=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  local pid=""
  local output_file="/tmp/spinner_out_$$"
  touch "$output_file"
  bash -c "$cmd" &> "$output_file" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % ${#spinners[@]} ))
    printf "\r${LIGHT_GRAY}${label} ${spinners[$i]}${RESET}"
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
  local exit_code=$?
  printf "\r\033[K"
  if [[ $exit_code -eq 0 ]]; then
    echo -e "${SOFT_GREEN}✓${RESET} ${label}"
    rm -f "$output_file"
    return 0
  else
    echo -e "${SOFT_RED}✗${RESET} ${label}"
    if [[ -s "$output_file" ]]; then
      echo -e "
${SOFT_RED}Детали:${RESET}"
      tail -n 10 "$output_file" | sed "s/^/  ${MEDIUM_GRAY}│${RESET} /"
      echo
    fi
    rm -f "$output_file"
    return $exit_code
  fi
}

ensure_dependency() {
  local pkg="$1"
  local cmd="${2:-$pkg}"
  if [[ "$cmd" == "-" ]]; then
    dpkg -l | grep -q "^ii.* $pkg " 2>/dev/null && { print_info "✓ ${pkg}"; return 0; }
  else
    command -v "$cmd" &>/dev/null && { print_info "✓ ${pkg}"; return 0; }
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$pkg" &>/dev/null || \
    print_error "Не удалось установить ${pkg}"
  [[ "$cmd" != "-" ]] && ! command -v "$cmd" &>/dev/null && \
    print_error "Команда '${cmd}' недоступна после установки ${pkg}"
  print_success "${pkg}"
}

readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_KEYS="/usr/local/etc/xray/.keys"
readonly XRAY_DAT_DIR="/usr/local/share/xray"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly SITE_DIR="/var/www/html"
readonly HELP_FILE="${HOME}/help"

sed -i '100s/.*/DOMAIN="${DOMAIN:-}"\nexport DOMAIN/'
SERVER_IP=""

check_root() {
  [[ "$EUID" -eq 0 ]] || print_error "Запускайте от root (sudo)"
}

get_public_ip() {
  curl -4s https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}' | cut -d' ' -f1
}

update_system() {
  print_step "Обновление системы"
  run_with_spinner "apt-get update -qq" "Обновление списка пакетов" || \
    print_error "Не удалось обновить список пакетов"
  run_with_spinner "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'" "Установка обновлений" || \
    print_warning "Обновление завершилось с предупреждениями"
  if [[ -f /var/run/reboot-required ]]; then
    print_warning "Требуется перезагрузка после обновления ядра"
    echo -e "${SOFT_YELLOW}⚠${RESET} Выполните: ${BOLD}sudo reboot${RESET}"
    echo -e "${LIGHT_GRAY}Скрипт приостановлен. Запустите после перезагрузки.${RESET}"
    exit 0
  fi
  print_success "Система обновлена"
}

optimize_swap() {
  print_substep "Swap"
  swapon --show | grep -q . && { print_info "✓ Уже настроен"; return 0; }
  local total_mem
  total_mem=$(free -m | awk '/^Mem:/ {print $2}')
  local swap_size_gb=0.5
  [[ "$total_mem" -le 1024 ]] && swap_size_gb=2
  [[ "$total_mem" -le 2048 && "$total_mem" -gt 1024 ]] && swap_size_gb=1
  [[ "$total_mem" -le 4096 && "$total_mem" -gt 2048 ]] && swap_size_gb=0.5
  if [[ ! -f /swapfile ]]; then
    local bs count
    [[ "$swap_size_gb" == "0.5" ]] && { bs="512M"; count=1; } || { bs="1G"; count="$swap_size_gb"; }
    dd if=/dev/zero of=/swapfile bs=$bs count=$count status=none &>/dev/null
    chmod 600 /swapfile
    mkswap /swapfile &>/dev/null
    swapon /swapfile &>/dev/null
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    swapon /swapfile &>/dev/null || true
  fi
  print_success "Swap активен"
}

optimize_network() {
  print_substep "Сеть (BBR)"
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '')" == "bbr" ]] && \
    { print_info "✓ Уже включён"; return 0; }
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
  sysctl -p /etc/sysctl.d/99-xray-tuning.conf &>/dev/null || \
    print_error "Не удалось применить сетевые настройки"
  print_success "BBR активен"
}

configure_trim() {
  print_substep "TRIM (SSD)"
  command -v lsblk &>/dev/null || { print_info "lsblk недоступен"; return 0; }
  local trim_supported
  trim_supported=$(lsblk --discard -no DISC-GRAN 2>/dev/null | awk '$1 != "0B" && $1 != "" {count++} END {print count+0}' || echo 0)
  [[ "$trim_supported" -eq 0 ]] && { print_info "Не поддерживается"; return 0; }
  systemctl is-active --quiet fstrim.timer 2>/dev/null && \
    { print_info "✓ Активен (${trim_supported} диск(а))"; return 0; }
  systemctl enable fstrim.timer --now &>/dev/null || \
    print_warning "Не удалось активировать TRIM"
  print_success "TRIM активирован"
}

configure_firewall() {
  print_substep "Фаервол (UFW)"
  ! command -v ufw &>/dev/null && ensure_dependency "ufw" "ufw"
  ! ip6tables -L &>/dev/null 2>&1 && grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null && \
    sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null
  local status_output
  status_output=$(ufw status verbose 2>/dev/null | grep -v "^Status:" | grep -v "^Logging" | grep -v "^Default" || echo "")
  local has_22=0 has_80=0 has_443=0
  [[ "$status_output" == *"22/tcp"* ]] && has_22=1
  [[ "$status_output" == *"80/tcp"* ]] && has_80=1
  [[ "$status_output" == *"443/tcp"* ]] && has_443=1
  if ufw status | grep -q "Status: active" && [[ $has_22 -eq 1 && $has_80 -eq 1 && $has_443 -eq 1 ]]; then
    print_info "✓ Активен (22/80/443 открыты)"
    return 0
  fi
  ufw default deny incoming &>/dev/null || true
  ufw default allow outgoing &>/dev/null || true
  ufw allow 22/tcp comment "SSH" &>/dev/null || true
  ufw allow 80/tcp comment "HTTP" &>/dev/null || true
  ufw allow 443/tcp comment "HTTPS" &>/dev/null || true
  ! ufw status | grep -q "Status: active" && ufw --force enable &>/dev/null
  print_success "UFW активен"
}

configure_fail2ban() {
  print_substep "Fail2Ban"
  ! command -v fail2ban-client &>/dev/null && ensure_dependency "fail2ban" "fail2ban-client"
  systemctl is-active --quiet fail2ban 2>/dev/null && { print_info "✓ Уже активен"; return 0; }
  [[ ! -f /etc/fail2ban/jail.local ]] && cat > /etc/fail2ban/jail.local <<EOF
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
  systemctl enable fail2ban &>/dev/null || true
  systemctl start fail2ban &>/dev/null || true
  sleep 1
  systemctl is-active --quiet fail2ban && print_success "Fail2Ban активен" || \
    print_warning "Fail2Ban запущен в фоне"
}

prompt_domain() {
  print_step "Домен"
  if [[ -n "$DOMAIN" ]]; then
    validate_and_set_domain "$DOMAIN"
    return
  fi
  if [[ -f "$XRAY_CONFIG" ]] && command -v jq &>/dev/null; then
    local existing_domain
    existing_domain=$(jq -r '.inbounds[1].streamSettings.realitySettings.serverNames[0] // ""' "$XRAY_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$existing_domain" && "$existing_domain" != "null" && "$existing_domain" != "example.com" && "$existing_domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      DOMAIN="$existing_domain"
      SERVER_IP=$(get_public_ip)
      print_info "Используется домен из конфигурации: ${DOMAIN}"
      return
    fi
  fi
  echo -e "${BOLD}Введите домен${RESET} (пример: wishnu.duckdns.org)"
  echo -e "${LIGHT_GRAY}Домен должен быть привязан к IP-адресу этого сервера${RESET}"
  local input_domain=""
  if ! read -r input_domain < /dev/tty 2>/dev/null; then
    print_error "Не удалось прочитать домен из терминала"
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
  # ИСПРАВЛЕНО: www-www-data → www-data
  chown -R www-data "$SITE_DIR" 2>/dev/null || true
  chmod -R 755 "$SITE_DIR"
  print_success "Сайт создан"
}

install_caddy() {
  print_substep "Caddy"
  for svc in nginx apache2 httpd; do
    systemctl is-active --quiet "$svc" 2>/dev/null && {
      systemctl stop "$svc" &>/dev/null
      systemctl disable "$svc" &>/dev/null
    }
  done
  # ОСВОБОЖДЕНИЕ ПОРТОВ 80/443
  for port in 80 443; do
    local pid
    pid=$(ss -tlnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print $7}' | head -n1 | cut -d',' -f2 | cut -d'=' -f2 || echo "")
    [[ -n "$pid" && "$pid" != "1" && "$pid" != "-" ]] && kill -9 "$pid" 2>/dev/null || true
  done
  sleep 2
  command -v caddy &>/dev/null && \
    { print_info "✓ Уже установлен ($(caddy version | head -n1 | cut -d' ' -f1))"; return 0; }
  ensure_dependency "debian-keyring" "-"
  ensure_dependency "debian-archive-keyring" "-"
  ensure_dependency "apt-transport-https" "-"
  ensure_dependency "curl" "curl"
  ensure_dependency "gnupg" "gpg"
  [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]] && \
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg &>/dev/null
  [[ ! -f /etc/apt/sources.list.d/caddy-stable.list ]] && \
    echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" > /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update -qq &>/dev/null
  apt-get install -y -qq caddy &>/dev/null || print_error "Не удалось установить Caddy"
  print_success "Caddy установлен ($(caddy version | head -n1 | cut -d' ' -f1))"
}

configure_caddy() {
  print_substep "Настройка Caddy"
  
  [[ -z "$DOMAIN" ]] && print_error "DOMAIN не установлен"
  
  # ИСПРАВЛЕНО: Создание директории логов с правильными правами
  mkdir -p /var/log/caddy
  chown -R caddy:caddy /var/log/caddy
  chmod 755 /var/log/caddy
  
  # ИСПРАВЛЕНО: Проверка существования пользователя caddy
  if ! id -u caddy &>/dev/null; then
    print_warning "Пользователь caddy не найден. Создание..."
    useradd -r -s /usr/sbin/nologin -d /var/lib/caddy -U caddy 2>/dev/null || true
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
}
http://127.0.0.1:8001 {
root * ${SITE_DIR}
file_server
}
EOF
  
  # Форматирование Caddyfile для устранения предупреждения
  if command -v caddy &>/dev/null; then
    caddy fmt --overwrite "$CADDYFILE" &>/dev/null || true
  fi
  
  if ! caddy validate --config "$CADDYFILE" &>/dev/null; then
    print_error "Ошибка валидации Caddyfile:\n$(caddy validate --config "$CADDYFILE" 2>&1)"
  fi
  
  # Установка прав на конфигурацию
  chown root:caddy "$CADDYFILE" 2>/dev/null || true
  chmod 644 "$CADDYFILE"
  
  systemctl daemon-reload
  systemctl stop caddy &>/dev/null || true
  systemctl reset-failed caddy &>/dev/null || true
  
  # Проверка возможности записи в лог перед запуском
  sudo -u caddy touch /var/log/caddy/access.log 2>/dev/null || {
    print_warning "Не удалось создать файл лога от имени caddy. Принудительная установка прав..."
    chown -R caddy:caddy /var/log/caddy
    chmod 755 /var/log/caddy
  }
  
  if ! systemctl start caddy &>/dev/null; then
    print_error "Не удалось запустить Caddy:\n$(journalctl -u caddy -n 20 --no-pager 2>/dev/null || echo 'Логи недоступны')"
  fi
  
  sleep 5
  
  if systemctl is-active --quiet caddy; then
    print_success "Caddy запущен"
  else
    journalctl -u caddy -n 30 --no-pager | tail -n 25 | sed "s/^/  ${MEDIUM_GRAY}│${RESET} /"
    print_error "Caddy не запущен (см. логи выше)"
  fi
}

install_xray() {
  print_substep "Xray Core"
  if command -v xray &>/dev/null; then
    local version
    version=$(xray version 2>/dev/null | head -n1 | cut -d' ' -f1-3 || echo "unknown")
    print_info "✓ Уже установлен (${version})"
    return 0
  fi
  ensure_dependency "curl" "curl"
  if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &>/dev/null; then
    print_error "Не удалось установить Xray"
  fi
  if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata &>/dev/null; then
    print_warning "Не удалось установить геофайлы (повторная попытка)..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata &>/dev/null || true
  fi
  local version
  version=$(xray version 2>/dev/null | head -n1 | cut -d' ' -f1-3 || echo "unknown")
  print_success "Xray установлен (${version})"
}

generate_uuid_safe() {
  print_substep "Проверка энтропии"
  local avail
  avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
  
  if [[ "$avail" -lt 200 ]]; then
    print_warning "Низкая энтропия (${avail} бит). Устанавливаем haveged..."
    ensure_dependency "haveged" "haveged"
    systemctl start haveged &>/dev/null || true
    sleep 2
    avail=$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo "0")
    print_info "Энтропия: ${avail} бит"
  else
    print_info "Энтропия достаточна (${avail} бит)"
  fi
  
  print_info "Генерация UUID через 'xray uuid' (таймаут 20 сек)..."
  local uuid
  if ! uuid=$(timeout 20 xray uuid 2>/dev/null); then
    print_error "Генерация UUID превысила 20 секунд.
Возможные причины:
• Недостаток энтропии (установлен haveged, но требуется время)
• Проблемы с /dev/random
Решение: выполните вручную 'xray uuid' и перезапустите скрипт"
  fi
  
  if [[ -z "$uuid" || ! "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    print_error "Некорректный UUID: '$uuid'
Проверьте вывод: xray uuid"
  fi
  
  echo "$uuid"
}

# ============================================================================
# ГЕНЕРАЦИЯ КОНФИГУРАЦИИ (ИСПРАВЛЕНА — КРИТИЧЕСКИ ВАЖНО)
# ============================================================================
generate_xray_config() {
  print_substep "Генерация конфигурации"
  mkdir -p /usr/local/etc/xray "$XRAY_DAT_DIR"
  local secret_path uuid priv_key pub_key short_id
  if [[ -f "$XRAY_KEYS" ]]; then
    secret_path=$(grep "^path:" "$XRAY_KEYS" | awk '{print $2}' | sed 's|/||' 2>/dev/null || echo "")
    uuid=$(grep "^uuid:" "$XRAY_KEYS" | awk '{print $2}' 2>/dev/null || echo "")
    priv_key=$(grep "^private_key:" "$XRAY_KEYS" | awk '{print $2}' 2>/dev/null || echo "")
    pub_key=$(grep "^public_key:" "$XRAY_KEYS" | awk '{print $2}' 2>/dev/null || echo "")
    short_id=$(grep "^short_id:" "$XRAY_KEYS" | awk '{print $2}' 2>/dev/null || echo "")
    if [[ -n "$secret_path" && -n "$uuid" && -n "$priv_key" && -n "$pub_key" && -n "$short_id" ]]; then
      print_info "Используются существующие параметры из ${XRAY_KEYS}"
    else
      print_warning "Неполные параметры в ${XRAY_KEYS}, генерируем новые"
      rm -f "$XRAY_KEYS"
    fi
  fi
  if [[ ! -f "$XRAY_KEYS" || ! -s "$XRAY_KEYS" ]]; then
    secret_path=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)
    print_info "Генерация UUID через 'xray uuid'..."
    uuid=$(generate_uuid_safe)
    print_success "UUID сгенерирован: ${uuid:0:8}..."
    print_info "Генерация X25519 ключей..."
    local key_pair
    key_pair=$(xray x25519 2>&1) || print_error "Не удалось сгенерировать ключи Reality"
    priv_key=$(echo "$key_pair" | grep -i "^PrivateKey" | awk '{print $NF}' | head -n1)
    pub_key=$(echo "$key_pair" | grep -i "^Password" | awk '{print $NF}' | head -n1)
    if [[ -z "$priv_key" || -z "$pub_key" || "${#priv_key}" -lt 40 || "${#pub_key}" -lt 40 ]]; then
      print_error "Некорректные ключи Reality"
    fi
    short_id=$(openssl rand -hex 4 2>/dev/null || echo "a1b2c3d4")
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
  if [[ -z "$secret_path" || -z "$uuid" || -z "$priv_key" || -z "$pub_key" || -z "$short_id" ]]; then
    print_error "Отсутствуют критические параметры"
  fi
  
  # ИСПРАВЛЕНО: ГЕНЕРАЦИЯ ЧЕРЕЗ ВРЕМЕННЫЙ ФАЙЛ С ПРАВИЛЬНЫМ HEREDOC
  local tmp_config="/tmp/xray-config-$$-${RANDOM}.json"
  
  # Экранирование спецсимволов для безопасности JSON
  local escaped_uuid="${uuid//\"/\\\"}"
  local escaped_domain="${DOMAIN//\"/\\\"}"
  local escaped_priv_key="${priv_key//\"/\\\"}"
  local escaped_short_id="${short_id//\"/\\\"}"
  local escaped_secret_path="${secret_path//\"/\\\"}"
  
  # ИСПРАВЛЕНО: ИСПОЛЬЗУЕМ 'EOF' БЕЗ КАВЫЧЕК ДЛЯ РАСКРЫТИЯ ПЕРЕМЕННЫХ
  cat > "$tmp_config" <<EOF
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
"clients": [{"id": "${escaped_uuid}", "email": "main"}]
},
"streamSettings": {
"network": "xhttp",
"xhttpSettings": {"path": "/${escaped_secret_path}"}
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
"serverNames": ["${escaped_domain}"],
"privateKey": "${escaped_priv_key}",
"shortIds": ["${escaped_short_id}"]
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
  
  # Проверка валидности JSON
  if ! command -v jq &>/dev/null; then
    ensure_dependency "jq" "jq"
  fi
  
  if ! jq empty "$tmp_config" &>/dev/null; then
    print_error "Невалидный JSON в конфигурации:\n$(cat "$tmp_config")"
  fi
  
  # Атомарное перемещение
  mv "$tmp_config" "$XRAY_CONFIG" || print_error "Не удалось переместить конфиг"
  chown root:root "$XRAY_CONFIG" 2>/dev/null || true
  chmod 644 "$XRAY_CONFIG"
  
  # Проверка размера файла
  if [[ $(stat -c%s "$XRAY_CONFIG" 2>/dev/null || echo 0) -lt 100 ]]; then
    print_error "Файл конфигурации слишком мал (<100 байт):\n$(cat "$XRAY_CONFIG")"
  fi
  
  print_info "Валидация конфигурации Xray..."
  if ! xray run -test -c "$XRAY_CONFIG" &>/dev/null; then
    xray run -test -c "$XRAY_CONFIG" 2>&1 | tee -a "$LOG_FILE"
    print_error "Ошибка валидации конфигурации Xray"
  fi
  print_success "Конфигурация Xray валидна"
  if systemctl is-active --quiet xray 2>/dev/null; then
    systemctl restart xray &>/dev/null || print_error "Не удалось перезапустить Xray"
  else
    systemctl enable xray --now &>/dev/null || print_error "Не удалось запустить Xray"
  fi
  sleep 3
  if systemctl is-active --quiet xray; then
    print_success "Xray запущен"
  else
    print_error "Не удалось запустить Xray"
  fi
}

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

create_user_utility() {
  print_substep "Утилита управления"
  ! command -v qrencode &>/dev/null && ensure_dependency "qrencode" "qrencode"
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
  echo "vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${pk}&fp=chrome&sni=${dom}&sid=${sid}&type=xhttp&path=%2F${sp}%2F#${email}"
}
case "$ACTION" in
  list) jq -r '.inbounds[0].settings.clients[] | "\(.email) (\(.id))"' "$XRAY_CONFIG" 2>/dev/null | nl -w3 -s'. ' || echo "Нет клиентов" ;;
  qr) uuid=$(jq -r '.inbounds[0].settings.clients[] | select(.email=="main") | .id' "$XRAY_CONFIG" 2>/dev/null || echo ""); [[ -z "$uuid" ]] && exit 1; link=$(generate_link "$uuid" "main"); echo -e "\nСсылка:\n$link\n"; command -v qrencode &>/dev/null && echo "QR:" && echo "$link" | qrencode -t ansiutf8 ;;
  add) read -p "Имя: " email < /dev/tty; [[ -z "$email" || "$email" =~ [^a-zA-Z0-9_-] ]] && exit 1; jq -e ".inbounds[0].settings.clients[] | select(.email==\"$email\")" "$XRAY_CONFIG" &>/dev/null && exit 1; uuid=$(xray uuid); jq --arg e "$email" --arg u "$uuid" '.inbounds[0].settings.clients += [{"id": $u, "email": $e}]' "$XRAY_CONFIG" > /tmp/x.tmp && mv /tmp/x.tmp "$XRAY_CONFIG"; systemctl restart xray &>/dev/null || true; link=$(generate_link "$uuid" "$email"); echo -e "\n✅ ${email} создан\nUUID: ${uuid}\nСсылка:\n$link"; command -v qrencode &>/dev/null && echo -e "\nQR:" && echo "$link" | qrencode -t ansiutf8 ;;
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

ГЕНЕРАЦИЯ UUID
• Официальный метод: xray uuid
• Для именованного UUID: xray uuid -i "имя_пользователя"

ВАЛИДАЦИЯ КОНФИГУРАЦИИ
• Правильная команда: xray run -test -c /path/to/config.json
EOF_HELP
  chmod 644 "$HELP_FILE"
  print_success "Файл помощи: ${HELP_FILE}"
}

main() {
  echo -e "
${BOLD}${SOFT_BLUE}Xray VLESS/XHTTP/Reality Installer${RESET}"
  echo -e "${LIGHT_GRAY}Исправлено: генерация конфига • Экранирование переменных • Валидация JSON${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
"
  check_root
  update_system
  export DEBIAN_FRONTEND=noninteractive
  print_step "Системные оптимизации"
  optimize_swap
  optimize_network
  configure_trim
  prompt_domain
  print_step "Безопасность"
  configure_firewall
  configure_fail2ban
  print_step "Зависимости"
  ensure_dependency "curl" "curl"
  ensure_dependency "jq" "jq"
  ensure_dependency "socat" "socat"
  ensure_dependency "git" "git"
  ensure_dependency "wget" "wget"
  ensure_dependency "gnupg" "gpg"
  ensure_dependency "ca-certificates" "-"
  ensure_dependency "unzip" "unzip"
  ensure_dependency "iproute2" "ss"
  ensure_dependency "openssl" "openssl"
  ensure_dependency "haveged" "haveged"
  print_success "Все зависимости установлены"
  print_step "Маскировка"
  create_masking_site
  print_step "Caddy"
  install_caddy
  configure_caddy
  print_step "Xray"
  install_xray
  generate_xray_config  # <-- ИСПРАВЛЕНА ГЕНЕРАЦИЯ
  setup_auto_updates
  print_step "Утилиты"
  create_user_utility
  create_help_file
  echo -e "
${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${SOFT_GREEN}✓ Установка завершена${RESET}"
  echo -e "${DARK_GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}
"
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
