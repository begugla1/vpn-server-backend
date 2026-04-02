#!/usr/bin/env bash

set -Eeuo pipefail

WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
DB_PATH="${XUI_DB:-/etc/x-ui/x-ui.db}"
BACKUP_DIR="${BACKUP_DIR:-/root/x-ui-backups}"
SQLITE_BUSY_TIMEOUT_MS="${SQLITE_BUSY_TIMEOUT_MS:-15000}"
SQLITE_RETRY_ATTEMPTS="${SQLITE_RETRY_ATTEMPTS:-5}"
KEYRING_PATH="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
REPO_PATH="/etc/apt/sources.list.d/cloudflare-client.list"
XUI_SERVICE_NAME="${XUI_SERVICE_NAME:-x-ui}"
XRAY_EXPECT_PORT="${XRAY_EXPECT_PORT:-443}"
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

validate_inputs() {
  [[ "${WARP_PROXY_PORT}" =~ ^[0-9]+$ ]] || die "WARP_PROXY_PORT must be numeric."
  (( WARP_PROXY_PORT >= 1 && WARP_PROXY_PORT <= 65535 )) || die "WARP_PROXY_PORT out of range."

  [[ "${SQLITE_BUSY_TIMEOUT_MS}" =~ ^[0-9]+$ ]] || die "SQLITE_BUSY_TIMEOUT_MS must be numeric."
  [[ "${SQLITE_RETRY_ATTEMPTS}" =~ ^[0-9]+$ ]] || die "SQLITE_RETRY_ATTEMPTS must be numeric."
  (( SQLITE_RETRY_ATTEMPTS >= 1 )) || die "SQLITE_RETRY_ATTEMPTS must be >= 1."

  [[ "${XRAY_EXPECT_PORT}" =~ ^[0-9]+$ ]] || die "XRAY_EXPECT_PORT must be numeric."
  (( XRAY_EXPECT_PORT >= 1 && XRAY_EXPECT_PORT <= 65535 )) || die "XRAY_EXPECT_PORT out of range."

  printf '%s' "${WARP_DOMAINS_JSON}" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || die "WARP_DOMAINS_JSON must be a valid JSON array."
}

require_xui_db() {
  [[ -f "${DB_PATH}" ]] || die "3X-UI database not found: ${DB_PATH}"
}

require_commands() {
  local cmd
  for cmd in systemctl grep sed awk cp rm sleep ls pgrep ss; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
  done
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

is_xray_template_json() {
  local value="${1:-}"

  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}" | jq -e '
    type == "object"
    and (.outbounds | type == "array")
    and ((.routing // {}) | type == "object")
  ' >/dev/null 2>&1
}

find_xray_template_key() {
  local key
  local value
  local settings_dump
  local candidate_key
  local candidate_value
  local -a candidate_keys=()
  local -a preferred_keys=(
    "xrayTemplateConfig"
    "xrayTemplate"
    "templateConfig"
    "xrayConfigTemplate"
    "xrayConfig"
  )

  for key in "${preferred_keys[@]}"; do
    value="$(run_sqlite_with_retry "SELECT value FROM settings WHERE key='${key}' LIMIT 1;")"
    if is_xray_template_json "${value}"; then
      printf '%s' "${key}"
      return 0
    fi
  done

  settings_dump="$(
    sqlite3 "${DB_PATH}" <<EOF 2>/dev/null
.timeout ${SQLITE_BUSY_TIMEOUT_MS}
.mode tabs
SELECT key, value FROM settings;
EOF
  )"

  while IFS=$'\t' read -r candidate_key candidate_value; do
    [[ -n "${candidate_key}" ]] || continue
    if is_xray_template_json "${candidate_value}"; then
      candidate_keys+=("${candidate_key}")
    fi
  done <<< "${settings_dump}"

  if ((${#candidate_keys[@]} == 0)); then
    return 1
  fi

  if ((${#candidate_keys[@]} > 1)); then
    log "Multiple candidate Xray template keys found: ${candidate_keys[*]}. Using: ${candidate_keys[0]}"
  else
    log "Detected Xray template settings key: ${candidate_keys[0]}"
  fi

  printf '%s' "${candidate_keys[0]}"
}

build_warp_enabled_config() {
  local source_config="$1"

  printf '%s' "${source_config}" | jq \
    --argjson warp_port "${WARP_PROXY_PORT}" \
    --argjson warp_domains "${WARP_DOMAINS_JSON}" '
      .outbounds = (
        (.outbounds // [])
        | map(select(.tag != "warp"))
        + [{
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
          }]
      ) |
      .routing = (.routing // {}) |
      .routing.rules = ((.routing.rules // []) | map(select((.outboundTag // "") != "warp"))) |
      .routing.rules = (
        if ((.routing.rules // []) | length) > 0 then
          [(.routing.rules[0])] + [{
            "type": "field",
            "outboundTag": "warp",
            "domain": $warp_domains
          }] + (.routing.rules[1:] // [])
        else
          [{
            "type": "field",
            "outboundTag": "warp",
            "domain": $warp_domains
          }]
        end
      )
    '
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

  for attempt in {1..15}; do
    sleep 2
    status_output="$(warp-cli --accept-tos status 2>/dev/null || true)"
    if grep -qi "Connected" <<< "${status_output}"; then
      log "WARP connected successfully"
      return 0
    fi
  done

  die "WARP did not reach Connected state."
}

verify_warp_proxy_reachability() {
  local warp_ip

  warp_ip="$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:${WARP_PROXY_PORT}" https://ifconfig.me 2>/dev/null || true)"
  [[ -n "${warp_ip}" ]] || die "WARP SOCKS5 proxy is not reachable on 127.0.0.1:${WARP_PROXY_PORT}"

  log "Verified WARP SOCKS5 proxy. Exit IP: ${warp_ip}"
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

latest_backup_file() {
  ls -1t "${BACKUP_DIR}"/x-ui-db-warp-*.db 2>/dev/null | head -1 || true
}

generate_clean_base_template() {
  cat <<'TEMPLATE_EOF'
{
  "api": {
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ],
    "tag": "api"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "policy": {
    "system": {
      "statsInboundDownlink": true,
      "statsInboundUplink": true,
      "statsOutboundDownlink": true,
      "statsOutboundUplink": true
    }
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": ["geoip:private"]
      }
    ]
  },
  "stats": {}
}
TEMPLATE_EOF
}

update_xray_template() {
  local template_key
  local current_config
  local new_config
  local safe_new_config
  local changes_output

  template_key="$(find_xray_template_key || true)"

  if [[ -n "${template_key}" ]]; then
    log "Using existing Xray template key: ${template_key}"
  fi

  if [[ -z "${template_key}" ]]; then
    log "No Xray template key found in DB. Creating clean base template."

    current_config="$(generate_clean_base_template)"
    template_key="xrayTemplateConfig"

    local safe_config
    safe_config="$(printf '%s' "${current_config}" | sed "s/'/''/g")"

    local seed_result
    seed_result="$(run_sqlite_with_retry "$(cat <<EOF
INSERT OR REPLACE INTO settings (key, value)
VALUES ('xrayTemplateConfig', '${safe_config}');
SELECT changes();
EOF
)")"

    if [[ "$(printf '%s' "${seed_result}" | tail -n1)" != "1" ]]; then
      die "Failed to seed xrayTemplateConfig"
    fi

    log "Seeded clean xrayTemplateConfig in DB"
  fi

  current_config="$(run_sqlite_with_retry "SELECT value FROM settings WHERE key='${template_key}' LIMIT 1;")"
  is_xray_template_json "${current_config}" || die "Xray template '${template_key}' has unexpected format"

  log "Current template size: $(printf '%s' "${current_config}" | wc -c | awk '{print $1}') bytes"

  new_config="$(build_warp_enabled_config "${current_config}")" || die "Failed to patch Xray template JSON"
  is_xray_template_json "${new_config}" || die "Patched Xray template JSON is invalid"

  log "Patched template size: $(printf '%s' "${new_config}" | wc -c | awk '{print $1}') bytes"

  safe_new_config="$(printf '%s' "${new_config}" | sed "s/'/''/g")"

  changes_output="$(run_sqlite_with_retry "$(cat <<EOF
UPDATE settings
SET value='${safe_new_config}'
WHERE key='${template_key}';
SELECT changes();
EOF
)")"

  if [[ "$(printf '%s' "${changes_output}" | tail -n1)" != "1" ]]; then
    die "Failed to update '${template_key}'"
  fi

  log "Updated '${template_key}' with WARP outbound and routing rules"
}

is_xray_healthy() {
  pgrep -x xray >/dev/null 2>&1 || return 1

  if [[ -n "${XRAY_EXPECT_PORT:-}" ]]; then
    ss -tlnp 2>/dev/null | grep -q ":${XRAY_EXPECT_PORT} " || return 1
  fi

  return 0
}

restart_xui() {
  log "Restarting ${XUI_SERVICE_NAME}"
  systemctl restart "${XUI_SERVICE_NAME}"
  sleep 5

  if systemctl is-active --quiet "${XUI_SERVICE_NAME}" && is_xray_healthy; then
    log "${XUI_SERVICE_NAME} restarted successfully and xray is healthy"
    return 0
  fi

  log "ERROR: ${XUI_SERVICE_NAME}/xray is not healthy after config change"
  log "Attempting automatic rollback"

  local latest_backup
  latest_backup="$(latest_backup_file)"

  if [[ -z "${latest_backup}" ]]; then
    die "No backup found for rollback. Manual intervention required."
  fi

  log "Stopping ${XUI_SERVICE_NAME} before rollback"
  systemctl stop "${XUI_SERVICE_NAME}" || true

  log "Restoring DB from backup: ${latest_backup}"
  cp "${latest_backup}" "${DB_PATH}"

  log "Starting ${XUI_SERVICE_NAME} after rollback"
  systemctl start "${XUI_SERVICE_NAME}"
  sleep 5

  if systemctl is-active --quiet "${XUI_SERVICE_NAME}" && is_xray_healthy; then
    log "Rollback successful. WARP changes reverted."
    die "${XUI_SERVICE_NAME}/xray did not start with WARP config. Rolled back to previous state."
  fi

  die "Rollback also failed. Manual intervention required: journalctl -u ${XUI_SERVICE_NAME} -f"
}

main() {
  require_root
  validate_inputs
  require_commands
  require_xui_db

  install_prerequisites
  configure_cloudflare_repo
  install_warp
  ensure_warp_registration
  configure_warp_proxy
  verify_warp_proxy_reachability

  backup_xui_db
  update_xray_template
  restart_xui

  log "WARP routing is ready. OpenAI/Anthropic traffic will use 127.0.0.1:${WARP_PROXY_PORT}."
}

main "$@"