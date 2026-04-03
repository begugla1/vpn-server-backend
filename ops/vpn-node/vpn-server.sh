#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="vpn-server.sh"
SCRIPT_VERSION="1.4.4"

# =============================================================================
# VPN server bootstrap / update / backup
# Safe for production:
# - install: only on fresh server, aborts if 3X-UI DB already exists
# - update: never reinstalls 3X-UI, never changes existing 3X-UI panel settings
# - backup: backup only x-ui.db
#
# Usage:
#   sudo bash vpn-server.sh install
#   sudo bash vpn-server.sh update
#   sudo bash vpn-server.sh backup
# =============================================================================

# ----------------------------
# Config
# ----------------------------
X3UI_PORT="${X3UI_PORT:-65000}"
X3UI_SUB_PORT="${X3UI_SUB_PORT:-2096}"
X3UI_WEB_BASE_PATH="${X3UI_WEB_BASE_PATH:-/}"
X3UI_SUB_PATH="${X3UI_SUB_PATH:-/sub/}"
X3UI_USERNAME="${X3UI_USERNAME:-admin}"
X3UI_PASSWORD="${X3UI_PASSWORD:-}"
BACKEND_IP="${BACKEND_IP:-}"
ADMIN_IP="${ADMIN_IP:-}"
SSH_PORT="${SSH_PORT:-22}"
ENABLE_BBR="${ENABLE_BBR:-true}"
ENABLE_FIREWALL="${ENABLE_FIREWALL:-true}"
SQLITE_BUSY_TIMEOUT_MS="${SQLITE_BUSY_TIMEOUT_MS:-15000}"
SQLITE_RETRY_ATTEMPTS="${SQLITE_RETRY_ATTEMPTS:-5}"
PANEL_CERT_DAYS="${PANEL_CERT_DAYS:-825}"

XUI_DB="/etc/x-ui/x-ui.db"
XUI_ETC_DIR="/etc/x-ui"
XUI_BIN_DIR="/usr/local/x-ui"
XUI_BIN="/usr/local/x-ui/x-ui"
XUI_SERVICE="/etc/systemd/system/x-ui.service"
PANEL_CERT_DIR="/root/cert"
XUI_PANEL_CERT_PATH="${XUI_PANEL_CERT_PATH:-${PANEL_CERT_DIR}/x-ui.crt}"
XUI_PANEL_KEY_PATH="${XUI_PANEL_KEY_PATH:-${PANEL_CERT_DIR}/x-ui.key}"
XUI_INSTALL_LOG="/root/.vpn-server-3x-ui-install.log"

BACKUP_DIR="/root/x-ui-backups"
CREDS_FILE="/root/.vpn-server-credentials"

# ----------------------------
# Colors / logging
# ----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
section() {
  echo
  echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}$*${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
}

die() {
  log_error "$*"
  exit 1
}

trap 'log_error "Script failed on line $LINENO"' ERR

# ----------------------------
# Checks
# ----------------------------
require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 ..."
}

check_os() {
  grep -qi "ubuntu" /etc/os-release || log_warn "Script is optimized for Ubuntu"
}

usage() {
  cat <<EOF
Usage:
  sudo bash $0 install   # fresh server only
  sudo bash $0 update    # safe update, preserves x-ui DB and manual panel settings
  sudo bash $0 backup    # backup only x-ui.db
  sudo bash $0 version   # show script version

Environment overrides:
  X3UI_PORT=65000
  X3UI_SUB_PORT=2096
  X3UI_WEB_BASE_PATH=/
  X3UI_USERNAME=admin
  X3UI_PASSWORD=...
  X3UI_SUB_PATH=/sub/
  BACKEND_IP=1.2.3.4
  ADMIN_IP=1.2.3.5
  SSH_PORT=22
  ENABLE_BBR=true
  ENABLE_FIREWALL=true
  PANEL_CERT_DAYS=825
EOF
}

show_version() {
    echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
}

is_xui_installed() {
  [[ -f "$XUI_DB" ]] || [[ -x "$XUI_BIN" ]] || systemctl list-unit-files | grep -q '^x-ui\.service'
}

ensure_backup_dir() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Port must be numeric: $port"
  (( port >= 1 && port <= 65535 )) || die "Port out of range: $port"
}

validate_config() {
  validate_port "$X3UI_PORT"
  validate_port "$X3UI_SUB_PORT"
  validate_port "$SSH_PORT"
  [[ "$SQLITE_BUSY_TIMEOUT_MS" =~ ^[0-9]+$ ]] || die "SQLITE_BUSY_TIMEOUT_MS must be numeric"
  [[ "$SQLITE_RETRY_ATTEMPTS" =~ ^[0-9]+$ ]] || die "SQLITE_RETRY_ATTEMPTS must be numeric"
  [[ "$PANEL_CERT_DAYS" =~ ^[0-9]+$ ]] || die "PANEL_CERT_DAYS must be numeric"

  case "$ENABLE_BBR" in
    true|false) ;;
    *) die "ENABLE_BBR must be true or false" ;;
  esac

  case "$ENABLE_FIREWALL" in
    true|false) ;;
    *) die "ENABLE_FIREWALL must be true or false" ;;
  esac

  if [[ "$ENABLE_FIREWALL" == "true" && -z "$BACKEND_IP" ]]; then
    die "BACKEND_IP must be set when ENABLE_FIREWALL=true"
  fi
}

note_panel_bootstrap_mode() {
  log_info "3X-UI panel settings are no longer managed by this script."
  log_info "X3UI_* values are used only for firewall and credentials output unless you change them manually."
}

strip_ansi() {
  sed -r 's/\x1B\[[0-9;]*[[:alpha:]]//g'
}

normalize_web_base_path() {
  local path="${1:-/}"
  [[ -n "$path" ]] || path="/"
  [[ "$path" == /* ]] || path="/${path}"
  [[ "$path" == "/" ]] || path="${path%/}"
  printf '%s' "$path"
}

extract_label_from_file() {
  local label="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  strip_ansi < "$file" | awk -F': ' -v label="$label" '$1 == label {value=$2} END {print value}'
}

get_public_ip() {
  curl -fsS -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

wait_for_xui_ready() {
  local i

  for i in {1..30}; do
    if [[ -x "$XUI_BIN" ]] && systemctl is-active --quiet x-ui 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  return 1
}

read_credential_field() {
  local field="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0
  awk -F': ' -v field="$field" '$1 == field {value=$2} END {print value}' "$file"
}

extract_last_https_url_from_file() {
  local file="$1"

  [[ -f "$file" ]] || return 0
  strip_ansi < "$file" | grep -Eo 'https://[^[:space:]]+' | tail -n 1 || true
}

write_credentials_file() {
  local ip panel_url panel_path username password password_from_log password_from_creds username_from_log username_from_creds url_from_log url_from_creds

  ip="$(get_public_ip)"
  panel_path="$(normalize_web_base_path "$X3UI_WEB_BASE_PATH")"
  panel_url="https://${ip}:${X3UI_PORT}${panel_path}"
  username="$X3UI_USERNAME"
  password="$X3UI_PASSWORD"

  username_from_log="$(extract_label_from_file "Username" "$XUI_INSTALL_LOG" | tr -d '\r')"
  password_from_log="$(extract_label_from_file "Password" "$XUI_INSTALL_LOG" | tr -d '\r')"
  url_from_log="$(extract_last_https_url_from_file "$XUI_INSTALL_LOG" | tr -d '\r')"

  username_from_creds="$(read_credential_field "Username" "$CREDS_FILE" | tr -d '\r')"
  password_from_creds="$(read_credential_field "Password" "$CREDS_FILE" | tr -d '\r')"
  url_from_creds="$(read_credential_field "Panel URL" "$CREDS_FILE" | tr -d '\r')"

  [[ -n "$username_from_log" ]] && username="$username_from_log"
  [[ -n "$password_from_log" ]] && password="$password_from_log"
  [[ -n "$url_from_log" ]] && panel_url="$url_from_log"

  if [[ -z "$username" && -n "$username_from_creds" ]]; then
    username="$username_from_creds"
  fi

  if [[ -z "$password" && -n "$password_from_creds" && "$password_from_creds" != "not captured automatically; check ${XUI_INSTALL_LOG}" ]]; then
    password="$password_from_creds"
  fi

  if [[ -z "$url_from_log" && -n "$url_from_creds" ]]; then
    panel_url="$url_from_creds"
  fi

  [[ -n "$username" ]] || username="admin"
  [[ -n "$password" ]] || password="not captured automatically; check ${XUI_INSTALL_LOG}"

  cat > "$CREDS_FILE" <<EOF
Panel URL: ${panel_url}
Username: ${username}
Password: ${password}
Panel Port Hint: ${X3UI_PORT}
Web Base Path Hint: ${panel_path}
Subscription Port Hint: ${X3UI_SUB_PORT}
Subscription Path Hint: ${X3UI_SUB_PATH}
Backend IP allowed for panel/subscription: ${BACKEND_IP}
Admin IP allowed for panel: ${ADMIN_IP:-not set}
Panel Certificate: ${XUI_PANEL_CERT_PATH}
Panel Private Key: ${XUI_PANEL_KEY_PATH}
Generated: $(date)
EOF
  chmod 600 "$CREDS_FILE"
}

run_sqlite_with_retry() {
  local db_path="$1"
  local sql="$2"
  local attempt output

  for ((attempt = 1; attempt <= SQLITE_RETRY_ATTEMPTS; attempt++)); do
    output="$(
      sqlite3 "$db_path" <<EOF 2>&1
.timeout ${SQLITE_BUSY_TIMEOUT_MS}
${sql}
EOF
    )" && {
      printf '%s' "$output"
      return 0
    }

    if grep -qiE 'database is locked|database is busy' <<< "$output" && (( attempt < SQLITE_RETRY_ATTEMPTS )); then
      log_warn "SQLite DB is locked, retrying (${attempt}/${SQLITE_RETRY_ATTEMPTS})..."
      sleep 2
      continue
    fi

    log_error "$output"
    return 1
  done
}

# ----------------------------
# Backup
# ----------------------------
backup_xui_db() {
  section "Backup x-ui database"

  if [[ ! -f "$XUI_DB" ]]; then
    log_warn "Database not found: $XUI_DB"
    return 0
  fi

  ensure_backup_dir

  local ts out
  ts="$(date +%Y%m%d_%H%M%S)"
  out="${BACKUP_DIR}/x-ui-db-${ts}.db"

  # SQLite-safe backup if sqlite3 exists, else plain cp
  if command -v sqlite3 >/dev/null 2>&1; then
    run_sqlite_with_retry "$XUI_DB" ".backup '${out}'" >/dev/null
  else
    cp "$XUI_DB" "$out"
  fi

  chmod 600 "$out"
  log_success "Backup created: $out ($(du -h "$out" | awk '{print $1}'))"

  # Keep latest 30 DB backups
  ls -1t "${BACKUP_DIR}"/x-ui-db-*.db 2>/dev/null | tail -n +31 | xargs -r rm -f
}

install_base_packages() {
  section "System update and base packages"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get dist-upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"

  apt-get install -y \
    curl wget unzip tar gzip socat cron \
    htop iftop vnstat net-tools iotop nano jq \
    fail2ban certbot ca-certificates \
    ufw openssl logrotate unattended-upgrades apt-listchanges \
    sqlite3

  apt-get autoremove -y
  apt-get autoclean -y

  systemctl enable vnstat >/dev/null 2>&1 || true
  systemctl restart vnstat >/dev/null 2>&1 || true

  log_success "System packages updated"
}
# ----------------------------
# System tuning
# ----------------------------
apply_sysctl_tuning() {
  section "Kernel and network tuning"

  cat > /etc/sysctl.d/99-vpn-server-tuning.conf <<'EOF'
# VPN tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.optmem_max = 65536

net.ipv4.tcp_rmem = 4096 1048576 33554432
net.ipv4.tcp_wmem = 4096 1048576 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 1024 65535

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

net.netfilter.nf_conntrack_max = 2000000
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15

fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

vm.swappiness = 10
vm.overcommit_memory = 1

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

  modprobe nf_conntrack 2>/dev/null || true
  sysctl --load /etc/sysctl.d/99-vpn-server-tuning.conf >/dev/null

  cat > /etc/security/limits.d/99-vpn-server.conf <<'EOF'
*    soft nofile  1048576
*    hard nofile  1048576
root soft nofile  1048576
root hard nofile  1048576
*    soft nproc   65535
*    hard nproc   65535
EOF

  grep -q "pam_limits.so" /etc/pam.d/common-session 2>/dev/null || \
    echo "session required pam_limits.so" >> /etc/pam.d/common-session

  mkdir -p /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF

  systemctl daemon-reload
  log_success "Kernel tuning applied"
}

enable_bbr_if_needed() {
  section "TCP BBR"

  if [[ "$ENABLE_BBR" != "true" ]]; then
    log_warn "BBR disabled by config"
    return 0
  fi

  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf || true
  log_success "Current CC: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
}

# ----------------------------
# 3X-UI
# ----------------------------
fresh_install_3xui() {
  section "Install 3X-UI (fresh only)"
  local install_script

  if is_xui_installed; then
    die "Existing 3X-UI detected. install mode is only for fresh servers. Use: $0 update"
  fi

  install_script="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh -o "$install_script"

  bash "$install_script" <<'EOF' 2>&1 | tee "$XUI_INSTALL_LOG"
y
EOF
  rm -f "$install_script"

  sleep 3

  [[ -x "$XUI_BIN" ]] || die "3X-UI binary not found after install"
  wait_for_xui_ready || log_warn "x-ui service did not become active immediately after install"
  log_success "3X-UI installed"
}

setup_self_signed_panel_certificate() {
  local mode="${1:-preserve}"
  local host_name public_ip cert_cn openssl_cfg

  section "Self-signed HTTPS certificate for 3X-UI"

  [[ -x "$XUI_BIN" ]] || die "3X-UI binary not found: $XUI_BIN"

  if [[ "$mode" != "force" && -f "$XUI_PANEL_CERT_PATH" && -f "$XUI_PANEL_KEY_PATH" ]]; then
    log_info "Existing panel certificate preserved: $XUI_PANEL_CERT_PATH"
    return 0
  fi

  install -d -m 700 "$PANEL_CERT_DIR"
  host_name="$(hostname -f 2>/dev/null || hostname)"
  public_ip="$(get_public_ip)"
  cert_cn="${host_name:-x-ui.local}"
  openssl_cfg="$(mktemp)"

  cat > "$openssl_cfg" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
x509_extensions = v3_req
distinguished_name = dn

[dn]
CN = ${cert_cn}
O = Self-Signed
OU = x-ui

[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = localhost
DNS.2 = ${host_name:-localhost}
IP.1 = 127.0.0.1
EOF

  if [[ -n "$public_ip" ]]; then
    echo "IP.2 = ${public_ip}" >> "$openssl_cfg"
  fi

  openssl req -x509 -nodes -newkey rsa:2048 \
    -days "$PANEL_CERT_DAYS" \
    -keyout "$XUI_PANEL_KEY_PATH" \
    -out "$XUI_PANEL_CERT_PATH" \
    -config "$openssl_cfg" >/dev/null 2>&1
  rm -f "$openssl_cfg"

  chmod 600 "$XUI_PANEL_KEY_PATH"
  chmod 644 "$XUI_PANEL_CERT_PATH"

  "$XUI_BIN" cert -webCert "$XUI_PANEL_CERT_PATH" -webCertKey "$XUI_PANEL_KEY_PATH" >/dev/null 2>&1 \
    || die "Failed to configure x-ui certificate paths"

  systemctl restart x-ui
  wait_for_xui_ready || log_warn "x-ui service did not become active immediately after certificate update"
  log_success "Self-signed certificate configured at ${XUI_PANEL_CERT_PATH}"
}

# ----------------------------
# systemd service
# ----------------------------
setup_xui_systemd() {
  section "Systemd service"

  [[ -x "$XUI_BIN" ]] || {
    log_warn "3X-UI binary not found, skip systemd setup"
    return 0
  }

  cat > "$XUI_SERVICE" <<'EOF'
[Unit]
Description=3X-UI Service
Documentation=https://github.com/MHSanaei/3x-ui
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/usr/local/x-ui/
ExecStart=/usr/local/x-ui/x-ui
Restart=always
RestartSec=5
StartLimitBurst=10
StartLimitIntervalSec=60
LimitNOFILE=1048576
LimitNPROC=65535
LimitCORE=infinity
StandardOutput=journal
StandardError=journal
SyslogIdentifier=x-ui
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui || true

  if systemctl is-active --quiet x-ui; then
    log_success "x-ui service active"
  else
    log_warn "x-ui service is not active; inspect: journalctl -u x-ui -f"
  fi
}

# ----------------------------
# Firewall / Fail2Ban / logs
# ----------------------------
setup_firewall() {
  section "UFW firewall"

  if [[ "$ENABLE_FIREWALL" != "true" ]]; then
    log_warn "Firewall disabled by config"
    return 0
  fi

  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming
  ufw default allow outgoing

  ufw limit "${SSH_PORT}/tcp" comment 'SSH'
  ufw allow from "${BACKEND_IP}" to any port "${X3UI_PORT}" proto tcp comment '3X-UI Panel from backend'
  if [[ -n "${ADMIN_IP}" && "${ADMIN_IP}" != "${BACKEND_IP}" ]]; then
    ufw allow from "${ADMIN_IP}" to any port "${X3UI_PORT}" proto tcp comment '3X-UI Panel from admin'
  fi
  ufw allow from "${BACKEND_IP}" to any port "${X3UI_SUB_PORT}" proto tcp comment '3X-UI Subscription from backend'
  ufw allow 443/tcp comment 'HTTPS/VLESS/Trojan'

  ufw --force enable >/dev/null 2>&1
  log_success "Firewall applied"
}

setup_fail2ban() {
  section "Fail2Ban"

  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
maxretry = 3
bantime = 86400
EOF

  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  log_success "Fail2Ban configured"
}

setup_logrotate() {
  section "Log rotation"

  cat > /etc/logrotate.d/x-ui <<'EOF'
/var/log/x-ui/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
}
EOF

  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=7day
EOF

  systemctl restart systemd-journald
  log_success "Log rotation configured"
}

# ----------------------------
# Monitoring helper
# ----------------------------
create_monitoring_script() {
  section "Monitoring helper"

  cat > /usr/local/bin/vpn-status <<EOF
#!/usr/bin/env bash
set -u
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}=== VPN SERVER STATUS ===${NC}"

echo -e "\n${GREEN}System${NC}"
echo "Uptime: \$(uptime -p)"
echo "Load:   \$(awk '{print \$1, \$2, \$3}' /proc/loadavg)"

echo -e "\n${GREEN}Memory${NC}"
free -h | awk '/^Mem:/ {printf "RAM: total=%s used=%s free=%s\n", \$2, \$3, \$4}'
free -h | awk '/^Swap:/ {printf "Swap: total=%s used=%s\n", \$2, \$3}'

echo -e "\n${GREEN}Disk${NC}"
df -h / | awk 'NR==2 {printf "/: total=%s used=%s (%s) free=%s\n", \$2, \$3, \$5, \$4}'

echo -e "\n${GREEN}Connections${NC}"
echo "ESTABLISHED: \$(ss -t state established | wc -l)"
echo "TIME-WAIT:   \$(ss -t state time-wait | wc -l)"
if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
  echo "Conntrack:   \$(cat /proc/sys/net/netfilter/nf_conntrack_count) / \$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
fi

echo -e "\n${GREEN}Services${NC}"
for svc in x-ui fail2ban ufw; do
  if systemctl is-active --quiet "\$svc" 2>/dev/null; then
    echo -e "\$svc: ${GREEN}active${NC}"
  else
    echo -e "\$svc: ${RED}inactive${NC}"
  fi
done

echo -e "\n${GREEN}Xray${NC}"
if pgrep -x xray >/dev/null; then
  pid="\$(pgrep -x xray | head -1)"
  mem="\$(ps -o rss= -p "\$pid" | awk '{printf "%.1f MB", \$1/1024}')"
  echo "running: PID=\$pid RAM=\$mem FD=\$(ls /proc/\$pid/fd 2>/dev/null | wc -l)"
else
  echo "not running"
fi
EOF

  chmod +x /usr/local/bin/vpn-status
  log_success "Created: /usr/local/bin/vpn-status"
}

# ----------------------------
# Auto security updates
# ----------------------------
setup_unattended_upgrades() {
  section "Automatic security updates"

  local distro_id
  local distro_codename
  distro_id="$(. /etc/os-release && echo "${ID}")"
  distro_codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  systemctl enable unattended-upgrades >/dev/null 2>&1 || true
  systemctl restart unattended-upgrades
  log_success "Automatic security updates configured"
}

# ----------------------------
# Optional periodic DB backup
# ----------------------------
setup_periodic_db_backup_job() {
  section "Periodic DB backup job"

  cat > /usr/local/bin/backup-x-ui <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
BACKUP_DIR="${BACKUP_DIR}"
DB="${XUI_DB}"
SQLITE_BUSY_TIMEOUT_MS="${SQLITE_BUSY_TIMEOUT_MS}"
SQLITE_RETRY_ATTEMPTS="${SQLITE_RETRY_ATTEMPTS}"
mkdir -p "\$BACKUP_DIR"
if [[ ! -f "\$DB" ]]; then
  exit 0
fi
TS=\$(date +%Y%m%d_%H%M%S)
OUT="\$BACKUP_DIR/x-ui-db-\$TS.db"
if command -v sqlite3 >/dev/null 2>&1; then
  attempt=1
  while true; do
    if sqlite3 "\$DB" <<SQLITE_EOF >/dev/null 2>&1
.timeout \$SQLITE_BUSY_TIMEOUT_MS
.backup '\$OUT'
SQLITE_EOF
    then
      break
    fi

    if (( attempt >= SQLITE_RETRY_ATTEMPTS )); then
      exit 1
    fi

    sleep 2
    attempt=\$((attempt + 1))
  done
else
  cp "\$DB" "\$OUT"
fi
chmod 600 "\$OUT"
ls -1t "\$BACKUP_DIR"/x-ui-db-*.db 2>/dev/null | tail -n +31 | xargs -r rm -f
EOF
  chmod +x /usr/local/bin/backup-x-ui

  local job='0 */6 * * * /usr/local/bin/backup-x-ui >> /var/log/x-ui-backup.log 2>&1'
  local current
  current="$(crontab -l 2>/dev/null || true)"
  if ! grep -Fq "/usr/local/bin/backup-x-ui" <<< "$current"; then
    (printf "%s\n%s\n" "$current" "$job" | sed '/^$/d') | crontab -
    log_success "Cron backup job added: every 6 hours"
  else
    log_success "Cron backup job already exists"
  fi
}

# ----------------------------
# Summaries
# ----------------------------
show_install_summary() {
  local panel_url username password

  panel_url="$(read_credential_field "Panel URL" "$CREDS_FILE")"
  username="$(read_credential_field "Username" "$CREDS_FILE")"
  password="$(read_credential_field "Password" "$CREDS_FILE")"

  section "Install completed"

  echo "Panel URL: ${panel_url}"
  echo "Username:  ${username}"
  echo "Password:  ${password}"
  echo
  echo "Backend IP for panel/subscription: ${BACKEND_IP}"
  echo "Admin IP for panel:                ${ADMIN_IP:-not set}"
  echo "Panel port hint:                   ${X3UI_PORT}/tcp (backend + admin IP)"
  echo "Subscription port hint:            ${X3UI_SUB_PORT}/tcp (backend IP only)"
  echo "Panel cert:                        ${XUI_PANEL_CERT_PATH}"
  echo "VPN public ports:                  443/tcp"
  echo
  echo "Credentials file:   ${CREDS_FILE}"
  echo "3X-UI install log:  ${XUI_INSTALL_LOG}"
  echo "Backup dir:         ${BACKUP_DIR}"
  echo "Monitoring:         vpn-status"
  echo
  echo "IMPORTANT: panel settings were not auto-customized. Configure panel/web path/subscription manually in 3X-UI."
}

show_update_summary() {
  local panel_url

  panel_url="$(read_credential_field "Panel URL" "$CREDS_FILE")"

  section "Update completed"
  echo "3X-UI DB preserved: yes"
  echo "3X-UI panel settings preserved: yes"
  echo "3X-UI reinstall performed: no"
  echo "Panel URL: ${panel_url}"
  echo "Panel port hint in firewall: ${X3UI_PORT}/tcp"
  echo "Panel access allowed from backend IP: ${BACKEND_IP}"
  echo "Panel access allowed from admin IP:   ${ADMIN_IP:-not set}"
  echo
  echo "Latest backups:"
  ls -1t "${BACKUP_DIR}"/x-ui-db-*.db 2>/dev/null | head -3 || true
  echo
  echo "Credentials file: ${CREDS_FILE}"
  echo "Monitoring:       vpn-status"
}

# ----------------------------
# Commands
# ----------------------------
cmd_install() {
  section "Mode: INSTALL"
  is_xui_installed && die "Existing 3X-UI detected. Refusing install. Use update instead."
  note_panel_bootstrap_mode

  install_base_packages
  apply_sysctl_tuning
  enable_bbr_if_needed
  fresh_install_3xui
  setup_xui_systemd
  setup_self_signed_panel_certificate force
  write_credentials_file
  setup_firewall
  setup_fail2ban
  setup_logrotate
  create_monitoring_script
  setup_unattended_upgrades
  setup_periodic_db_backup_job
  backup_xui_db
  show_install_summary
}

cmd_update() {
  section "Mode: UPDATE"
  is_xui_installed || die "3X-UI installation not found. Use install mode on a fresh server."
  note_panel_bootstrap_mode

  backup_xui_db
  install_base_packages
  apply_sysctl_tuning
  enable_bbr_if_needed

  # IMPORTANT:
  # no reinstall of 3X-UI
  # no changing x-ui username/password/port/path

  setup_xui_systemd
  setup_self_signed_panel_certificate preserve
  write_credentials_file
  setup_firewall
  setup_fail2ban
  setup_logrotate
  create_monitoring_script
  setup_unattended_upgrades
  setup_periodic_db_backup_job
  show_update_summary
}

cmd_backup() {
  section "Mode: BACKUP"
  backup_xui_db
}

main() {
  require_root
  check_os
  validate_config

  [[ $# -eq 1 ]] || { usage; exit 1; }

  case "$1" in
    install) cmd_install ;;
    update)  cmd_update ;;
    backup)  cmd_backup ;;
    version) show_version ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
