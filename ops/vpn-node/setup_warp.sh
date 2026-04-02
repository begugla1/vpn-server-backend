#!/usr/bin/env bash

set -Eeuo pipefail

WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
DB_PATH="${XUI_DB:-/etc/x-ui/x-ui.db}"
BACKUP_DIR="${BACKUP_DIR:-/root/x-ui-backups}"
SQLITE_BUSY_TIMEOUT_MS="${SQLITE_BUSY_TIMEOUT_MS:-15000}"
SQLITE_RETRY_ATTEMPTS="${SQLITE_RETRY_ATTEMPTS:-5}"
KEYRING_PATH="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
REPO_PATH="/etc/apt/sources.list.d/cloudflare-client.list"
WARP_DOMAINS_JSON='[
  "geosite:openai",
  "domain:chatgpt.com",
  "domain:chat.openai.com",
  "domain:openai.com",
  "domain:auth.openai.com",
  "domain:oaistatic.com",
  "domain:anthropic.com",
  "domain:claude.ai"
]'

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

validate_port() {
  [[ "${WARP_PROXY_PORT}" =~ ^[0-9]+$ ]] || die "WARP_PROXY_PORT must be numeric."
  (( WARP_PROXY_PORT >= 1 && WARP_PROXY_PORT <= 65535 )) || die "WARP_PROXY_PORT out of range."
  [[ "${SQLITE_BUSY_TIMEOUT_MS}" =~ ^[0-9]+$ ]] || die "SQLITE_BUSY_TIMEOUT_MS must be numeric."
  [[ "${SQLITE_RETRY_ATTEMPTS}" =~ ^[0-9]+$ ]] || die "SQLITE_RETRY_ATTEMPTS must be numeric."
}

require_xui_db() {
  [[ -f "${DB_PATH}" ]] || die "3X-UI database not found: ${DB_PATH}"
}

reset_cloudflare_repo_state() {
  if [[ -f "${REPO_PATH}" ]] || [[ -f "${KEYRING_PATH}" ]]; then
    log "Removing stale Cloudflare APT repo state"
  fi

  rm -f "${REPO_PATH}"
  rm -f "${KEYRING_PATH}"
}

run_sqlite_with_retry() {
  local sql="$1"
  local attempt
  local output

  for ((attempt = 1; attempt <= SQLITE_RETRY_ATTEMPTS; attempt++)); do
    output="$(
      sqlite3 "${DB_PATH}" <<EOF 2>&1
.timeout ${SQLITE_BUSY_TIMEOUT_MS}
${sql}
EOF
    )" && {
      printf '%s' "${output}"
      return 0
    }

    if grep -qiE 'database is locked|database is busy' <<< "${output}" && (( attempt < SQLITE_RETRY_ATTEMPTS )); then
      log "SQLite DB is locked, retrying (${attempt}/${SQLITE_RETRY_ATTEMPTS})"
      sleep 2
      continue
    fi

    log "ERROR: ${output}"
    return 1
  done
}

install_prerequisites() {
  log "Installing WARP prerequisites"
  reset_cloudflare_repo_state
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    jq \
    lsb-release \
    sqlite3
}

configure_cloudflare_repo() {
  local distro_codename

  distro_codename="$(lsb_release -cs)"
  install -d -m 0755 /usr/share/keyrings

  curl -fsSL "https://pkg.cloudflareclient.com/pubkey.gpg" \
    | gpg --yes --dearmor --output "${KEYRING_PATH}"
  chmod a+r "${KEYRING_PATH}"

  cat > "${REPO_PATH}" <<EOF
deb [signed-by=${KEYRING_PATH}] https://pkg.cloudflareclient.com/ ${distro_codename} main
EOF

  apt-get update
}

install_warp() {
  log "Installing Cloudflare WARP"
  DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
}

ensure_warp_registration() {
  local registration_output

  registration_output="$(warp-cli --accept-tos registration show 2>/dev/null || true)"
  if [[ -z "${registration_output}" ]] || grep -qiE "missing|not registered|error" <<< "${registration_output}"; then
    log "Registering WARP client"
    warp-cli --accept-tos registration new
  else
    log "WARP client is already registered"
  fi
}

configure_warp_proxy() {
  local status_output
  local attempt

  log "Configuring WARP proxy mode on 127.0.0.1:${WARP_PROXY_PORT}"

  warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
  warp-cli --accept-tos mode proxy
  warp-cli --accept-tos proxy port "${WARP_PROXY_PORT}"
  warp-cli --accept-tos connect

  for attempt in {1..10}; do
    sleep 2
    status_output="$(warp-cli --accept-tos status 2>/dev/null || true)"
    if grep -qi "Connected" <<< "${status_output}"; then
      log "WARP connected successfully"
      return 0
    fi
  done

  die "WARP did not reach Connected state."
}

backup_xui_db() {
  local timestamp
  local backup_file

  mkdir -p "${BACKUP_DIR}"
  timestamp="$(date +%Y%m%d_%H%M%S)"
  backup_file="${BACKUP_DIR}/x-ui-db-warp-${timestamp}.db"

  if command -v sqlite3 >/dev/null 2>&1; then
    run_sqlite_with_retry ".backup '${backup_file}'" >/dev/null
  else
    cp "${DB_PATH}" "${backup_file}"
  fi

  chmod 600 "${backup_file}"
  log "3X-UI DB backup created: ${backup_file}"
}

update_xray_template() {
  local current_config
  local new_config
  local safe_new_config
  local changes_output

  current_config="$(run_sqlite_with_retry "SELECT value FROM settings WHERE key='xrayTemplateConfig' LIMIT 1;")"
  [[ -n "${current_config}" ]] || die "xrayTemplateConfig was not found in ${DB_PATH}"

  new_config="$(printf '%s' "${current_config}" | jq \
    --argjson warp_port "${WARP_PROXY_PORT}" \
    --argjson warp_domains "${WARP_DOMAINS_JSON}" '
      .outbounds = ((.outbounds // []) | map(select(.tag != "warp")) + [{
        "tag": "warp",
        "protocol": "socks",
        "settings": {
          "servers": [
            {
              "address": "127.0.0.1",
              "port": $warp_port
            }
          ]
        }
      }]) |
      .routing = (.routing // {}) |
      .routing.rules = ((.routing.rules // []) | map(select((.outboundTag // "") != "warp"))) |
      .routing.rules = [{
        "type": "field",
        "outboundTag": "warp",
        "domain": $warp_domains
      }] + .routing.rules
    ')" || die "Failed to patch xrayTemplateConfig JSON."

  safe_new_config="$(printf '%s' "${new_config}" | sed "s/'/''/g")"
  changes_output="$(run_sqlite_with_retry "$(cat <<EOF
UPDATE settings
SET value='${safe_new_config}'
WHERE key='xrayTemplateConfig';
SELECT changes();
EOF
)")"

  if [[ "$(printf '%s' "${changes_output}" | tail -n1)" != "1" ]]; then
    die "Failed to update xrayTemplateConfig in ${DB_PATH}"
  fi

  log "Updated xrayTemplateConfig with WARP outbound and routing rules"
}

restart_xui() {
  log "Restarting x-ui"
  systemctl restart x-ui
}

main() {
  require_root
  validate_port
  require_xui_db
  install_prerequisites
  configure_cloudflare_repo
  install_warp
  ensure_warp_registration
  configure_warp_proxy
  backup_xui_db
  update_xray_template
  restart_xui
  log "WARP routing is ready. OpenAI/Anthropic traffic will use 127.0.0.1:${WARP_PROXY_PORT}."
}

main "$@"
