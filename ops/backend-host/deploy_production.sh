#!/usr/bin/env bash

set -Eeuo pipefail

APP_PORT="${APP_PORT:-8000}"
SSH_PORT="${SSH_PORT:-22}"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

DOCKER_GPG_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.list"
DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
DOCKER_FIREWALL_SCRIPT="/usr/local/bin/vpn-backend-docker-firewall.sh"
DOCKER_FIREWALL_SERVICE="/etc/systemd/system/vpn-backend-docker-firewall.service"

DB_BACKUP_DIR="/var/backups/vpn-backend-postgres"
DB_BACKUP_SCRIPT="/usr/local/bin/backend-db-backup"
DB_BACKUP_CRON="/etc/cron.d/vpn-backend-db-backup"
DB_BACKUP_RETENTION_DAYS="${DB_BACKUP_RETENTION_DAYS:-14}"
DB_BACKUP_HOUR="${DB_BACKUP_HOUR:-3}"
DB_BACKUP_MINUTE="${DB_BACKUP_MINUTE:-15}"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Run this script as root."
    fi
}

require_apt() {
    command -v apt-get >/dev/null 2>&1 || die "This script supports Debian/Ubuntu hosts only."
}

require_file() {
    local path="$1"
    [[ -f "${path}" ]] || die "Required file not found: ${path}"
}

validate_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] || die "Port must be numeric: ${port}"
    (( port >= 1 && port <= 65535 )) || die "Port out of range: ${port}"
}

validate_uint_range() {
    local value="$1"
    local name="$2"
    local min_value="$3"
    local max_value="$4"

    [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} must be numeric: ${value}"
    (( value >= min_value && value <= max_value )) || die "${name} out of range: ${value}"
}

install_base_packages() {
    log "Updating OS packages"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    log "Installing base and security packages"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        apt-listchanges \
        ca-certificates \
        cron \
        curl \
        fail2ban \
        git \
        gnupg \
        gzip \
        htop \
        iproute2 \
        iptables \
        jq \
        logrotate \
        lsb-release \
        ufw \
        unattended-upgrades

    apt-get autoremove -y
    apt-get autoclean -y
}

apply_system_tuning() {
    log "Applying system tuning"

    cat > /etc/sysctl.d/99-vpn-backend.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.core.somaxconn = 4096
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
vm.swappiness = 10
EOF

    sysctl --system >/dev/null

    cat > /etc/security/limits.d/99-vpn-backend.conf <<'EOF'
*    soft nofile  1048576
*    hard nofile  1048576
root soft nofile  1048576
root hard nofile  1048576
EOF

    grep -q "pam_limits.so" /etc/pam.d/common-session 2>/dev/null || \
        echo "session required pam_limits.so" >> /etc/pam.d/common-session

    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

    systemctl daemon-reload
}

install_docker() {
    local distro_id
    local distro_codename
    local arch

    distro_id="$(. /etc/os-release && echo "${ID}")"
    distro_codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
    arch="$(dpkg --print-architecture)"

    log "Installing Docker Engine and Compose plugin"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" -o "${DOCKER_GPG_KEYRING}"
    chmod a+r "${DOCKER_GPG_KEYRING}"

    cat > "${DOCKER_REPO_FILE}" <<EOF
deb [arch=${arch} signed-by=${DOCKER_GPG_KEYRING}] https://download.docker.com/linux/${distro_id} ${distro_codename} stable
EOF

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin

    systemctl enable --now docker
    docker --version >/dev/null
    docker compose version >/dev/null
}

configure_docker_daemon() {
    local tmp_config

    log "Configuring Docker daemon defaults"
    install -m 0755 -d /etc/docker
    tmp_config="$(mktemp)"

    if [[ -s "${DOCKER_DAEMON_CONFIG}" ]]; then
        cp "${DOCKER_DAEMON_CONFIG}" "${DOCKER_DAEMON_CONFIG}.bak.$(date +%s)"
        jq '
            ."live-restore" = true
            | ."log-driver" = "json-file"
            | ."log-opts" = ((."log-opts" // {}) + {
                "max-size": "50m",
                "max-file": "5"
            })
        ' "${DOCKER_DAEMON_CONFIG}" > "${tmp_config}"
    else
        cat > "${tmp_config}" <<'EOF'
{
  "live-restore": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
EOF
    fi

    mv "${tmp_config}" "${DOCKER_DAEMON_CONFIG}"
    systemctl restart docker
}

configure_ufw() {
    log "Configuring UFW"
    ufw --force reset >/dev/null 2>&1
    ufw --force default deny incoming
    ufw --force default allow outgoing
    ufw limit "${SSH_PORT}/tcp"
    ufw allow "${APP_PORT}/tcp"
    ufw --force enable >/dev/null 2>&1
}

setup_fail2ban() {
    log "Configuring Fail2Ban"

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
}

setup_log_management() {
    log "Configuring journald limits"

    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=7day
EOF

    systemctl restart systemd-journald
}

setup_unattended_upgrades() {
    local distro_id
    local distro_codename

    distro_id="$(. /etc/os-release && echo "${ID}")"
    distro_codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

    log "Configuring unattended upgrades"

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
}

create_monitoring_script() {
    log "Creating backend monitoring helper"

    cat > /usr/local/bin/backend-status <<'EOF'
#!/usr/bin/env bash
set -u
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}=== BACKEND SERVER STATUS ===${NC}"

echo -e "\n${GREEN}System${NC}"
echo "Uptime: $(uptime -p)"
echo "Load:   $(awk '{print $1, $2, $3}' /proc/loadavg)"

echo -e "\n${GREEN}Memory${NC}"
free -h | awk '/^Mem:/ {printf "RAM: total=%s used=%s free=%s\n", $2, $3, $4}'
free -h | awk '/^Swap:/ {printf "Swap: total=%s used=%s\n", $2, $3}'

echo -e "\n${GREEN}Disk${NC}"
df -h / | awk 'NR==2 {printf "/: total=%s used=%s (%s) free=%s\n", $2, $3, $5, $4}'

echo -e "\n${GREEN}Services${NC}"
for svc in docker fail2ban ufw; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo -e "$svc: ${GREEN}active${NC}"
  else
    echo -e "$svc: ${RED}inactive${NC}"
  fi
done

echo -e "\n${GREEN}Containers${NC}"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo "docker ps unavailable"
EOF

    chmod +x /usr/local/bin/backend-status
}

setup_postgres_backups() {
    log "Configuring daily PostgreSQL backups"

    install -d -m 0700 "${DB_BACKUP_DIR}"

    cat > "${DB_BACKUP_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR}"
BACKUP_DIR="${DB_BACKUP_DIR}"
RETENTION_DAYS="${DB_BACKUP_RETENTION_DAYS}"

cd "\${PROJECT_DIR}"
set -a
. "\${PROJECT_DIR}/.env"
set +a

timestamp="\$(date +%Y%m%d_%H%M%S)"
backup_file="\${BACKUP_DIR}/postgres-\${timestamp}.sql.gz"
tmp_file="\${backup_file}.tmp"

mkdir -p "\${BACKUP_DIR}"
chmod 700 "\${BACKUP_DIR}"

docker compose ps --status running db >/dev/null 2>&1

docker compose exec -T -e PGPASSWORD="\${POSTGRES_PASSWORD}" db \
    pg_dump -U "\${POSTGRES_USER}" "\${POSTGRES_DB}" | gzip -9 > "\${tmp_file}"

mv "\${tmp_file}" "\${backup_file}"
chmod 600 "\${backup_file}"

find "\${BACKUP_DIR}" -maxdepth 1 -type f -name 'postgres-*.sql.gz' -mtime +"\${RETENTION_DAYS}" -delete
EOF

    chmod 0755 "${DB_BACKUP_SCRIPT}"

    cat > "${DB_BACKUP_CRON}" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${DB_BACKUP_MINUTE} ${DB_BACKUP_HOUR} * * * root ${DB_BACKUP_SCRIPT} >> /var/log/vpn-backend-db-backup.log 2>&1
EOF

    chmod 0644 "${DB_BACKUP_CRON}"
    systemctl restart cron >/dev/null 2>&1 || true
}

install_docker_user_firewall() {
    local external_iface

    external_iface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
    [[ -n "${external_iface}" ]] || die "Could not detect the external network interface."

    log "Installing DOCKER-USER firewall guard for published ports"
    cat > "${DOCKER_FIREWALL_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

EXT_IFACE="${external_iface}"
APP_PORT="${APP_PORT}"

iptables -N DOCKER-USER 2>/dev/null || true

iptables -C DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -I DOCKER-USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

iptables -C DOCKER-USER -i "\${EXT_IFACE}" -p tcp --dport "\${APP_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I DOCKER-USER 2 -i "\${EXT_IFACE}" -p tcp --dport "\${APP_PORT}" -j ACCEPT

iptables -C DOCKER-USER -i "\${EXT_IFACE}" -j DROP 2>/dev/null || \
    iptables -A DOCKER-USER -i "\${EXT_IFACE}" -j DROP
EOF
    chmod 0755 "${DOCKER_FIREWALL_SCRIPT}"

    cat > "${DOCKER_FIREWALL_SERVICE}" <<EOF
[Unit]
Description=Restrict Docker published ports for VPN backend
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${DOCKER_FIREWALL_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$(basename "${DOCKER_FIREWALL_SERVICE}")"
}

deploy_stack() {
    log "Deploying Docker Compose stack"
    cd "${PROJECT_DIR}"

    docker compose up -d --build db
    docker compose run --rm backend alembic upgrade head
    docker compose up -d --build
}

run_initial_db_backup() {
    log "Creating initial PostgreSQL backup"
    "${DB_BACKUP_SCRIPT}"
}

print_summary() {
    log "Deployment completed"
    log "Open inbound ports: TCP ${SSH_PORT}, TCP ${APP_PORT}"
    log "Security features enabled: UFW, DOCKER-USER guard, Fail2Ban, unattended-upgrades, journald limits, Docker log limits"
    log "Monitoring helper: /usr/local/bin/backend-status"
    log "Database backups: daily at ${DB_BACKUP_HOUR}:$(printf '%02d' "${DB_BACKUP_MINUTE}") -> ${DB_BACKUP_DIR}"
    log "Useful checks:"
    log "  docker compose ps"
    log "  docker compose logs -f backend"
    log "  backend-status"
    log "  ${DB_BACKUP_SCRIPT}"
    log "  curl -H 'Authorization: Bearer <BACKEND_API_TOKEN>' <your_backend_url>/health"
}

main() {
    require_root
    require_apt
    validate_port "${APP_PORT}"
    validate_port "${SSH_PORT}"
    validate_uint_range "${DB_BACKUP_RETENTION_DAYS}" "DB_BACKUP_RETENTION_DAYS" 1 3650
    validate_uint_range "${DB_BACKUP_HOUR}" "DB_BACKUP_HOUR" 0 23
    validate_uint_range "${DB_BACKUP_MINUTE}" "DB_BACKUP_MINUTE" 0 59
    require_file "${PROJECT_DIR}/docker-compose.yml"
    require_file "${PROJECT_DIR}/.env"

    install_base_packages
    apply_system_tuning
    install_docker
    configure_docker_daemon
    configure_ufw
    setup_fail2ban
    setup_log_management
    create_monitoring_script
    setup_postgres_backups
    setup_unattended_upgrades
    install_docker_user_firewall
    deploy_stack
    run_initial_db_backup
    print_summary
}

main "$@"
