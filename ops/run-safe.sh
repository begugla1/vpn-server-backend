#!/usr/bin/env bash

set -Eeuo pipefail

DEFAULT_LOG_DIR="/var/log"
DEFAULT_STATE_DIR="/var/tmp/ops-run-safe"
declare -a ENV_ASSIGNMENTS=()
declare -a COMMAND_ARGS=()

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  sudo ./ops/run-safe.sh [--name NAME] [--log PATH] -- command [args...]

Description:
  Starts a long-running command so it survives SSH disconnects.
  Prefers systemd-run when available and falls back to nohup.
  Stores a log file and a small metadata file for reconnecting later.

Options:
  --name NAME   Job name. Used for the systemd unit, log and metadata file.
  --log PATH    Absolute path to the log file. Default: /var/log/<name>.log
  -h, --help    Show this help.

Examples:
  sudo ./ops/run-safe.sh --name vpn-install -- \
    BACKEND_IP=203.0.113.10 bash ./ops/vpn-node/vpn-server.sh install

  sudo ./ops/run-safe.sh --name backend-deploy -- \
    APP_PORT=8000 bash ./ops/backend-host/deploy_production.sh
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

sanitize_name() {
    local raw="$1"
    raw="${raw//[^a-zA-Z0-9_.@-]/-}"
    raw="${raw#-}"
    raw="${raw%-}"
    printf '%s' "${raw}"
}

format_command_line() {
    local parts=()
    local arg

    for arg in "$@"; do
        printf -v arg '%q' "${arg}"
        parts+=("${arg}")
    done

    printf '%s' "${parts[*]}"
}

split_command_spec() {
    local arg
    local parsing_env="true"

    ENV_ASSIGNMENTS=()
    COMMAND_ARGS=()

    for arg in "$@"; do
        if [[ "${parsing_env}" == "true" && "${arg}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
            ENV_ASSIGNMENTS+=("${arg}")
            continue
        fi

        parsing_env="false"
        COMMAND_ARGS+=("${arg}")
    done

    ((${#COMMAND_ARGS[@]} > 0)) || die "Command is required after environment assignments."
}

write_metadata() {
    local meta_path="$1"
    local mode="$2"
    local unit_name="$3"
    local log_path="$4"
    local cwd="$5"
    local command_string="$6"
    local runner_path="$7"

    install -d -m 0700 "${DEFAULT_STATE_DIR}"

    {
        printf 'MODE=%q\n' "${mode}"
        printf 'UNIT=%q\n' "${unit_name}"
        printf 'LOG=%q\n' "${log_path}"
        printf 'CWD=%q\n' "${cwd}"
        printf 'COMMAND=%q\n' "${command_string}"
        printf 'RUNNER=%q\n' "${runner_path}"
        printf 'CREATED_AT=%q\n' "$(date '+%F %T %z')"
    } > "${meta_path}"

    chmod 0600 "${meta_path}"
}

print_followup() {
    local mode="$1"
    local unit_name="$2"
    local log_path="$3"
    local meta_path="$4"
    local runner_path="$5"

    log "Job started in detached mode."
    log "Unit: ${unit_name}"
    log "Log file: ${log_path}"
    log "Metadata: ${meta_path}"
    log "Runner: ${runner_path}"

    if [[ "${mode}" == "systemd" ]]; then
        log "Reconnect checks:"
        log "  cat ${meta_path}"
        log "  systemctl status ${unit_name}"
        log "  tail -f ${log_path}"
    else
        log "Reconnect checks:"
        log "  cat ${meta_path}"
        log "  tail -f ${log_path}"
        log "  ps -fp \"\$(awk -F= '/^PID=/{print \$2}' ${meta_path})\""
    fi
}

create_runner_script() {
    local runner_path="$1"
    local log_path="$2"
    local cwd="$3"
    local command_string="$4"
    local assignment
    local arg

    install -d -m 0700 "${DEFAULT_STATE_DIR}"

    {
        printf '#!/usr/bin/env bash\n'
        printf '\n'
        printf 'set -Eeuo pipefail\n'
        printf 'cd %q\n' "${cwd}"
        printf 'umask 077\n'
        printf 'exec >>%q 2>&1\n' "${log_path}"
        printf 'printf '"'"'[%s] Detached command started\n'"'"' "$(date '"'"'+%%F %%T'"'"')"\n'
        printf 'printf '"'"'[%s] Command: %s\n'"'"' "$(date '"'"'+%%F %%T'"'"')" %q\n' "${command_string}"

        for assignment in "${ENV_ASSIGNMENTS[@]}"; do
            printf 'export %q\n' "${assignment}"
        done

        printf 'set +e\n'
        for arg in "${COMMAND_ARGS[@]}"; do
            printf '%q ' "${arg}"
        done
        printf '\n'
        printf 'exit_code=$?\n'
        printf 'set -e\n'
        printf 'printf '"'"'[%s] Detached command finished with exit code %s\n'"'"' "$(date '"'"'+%%F %%T'"'"')" "$exit_code"\n'
        printf 'exit "$exit_code"\n'
    } > "${runner_path}"

    chmod 0700 "${runner_path}"
}

start_with_systemd() {
    local unit_name="$1"
    local runner_path="$2"

    systemd-run \
        --unit "${unit_name}" \
        --description "Detached ops job ${unit_name}" \
        --service-type=exec \
        /bin/bash "${runner_path}" >/dev/null
}

start_with_nohup() {
    local runner_path="$1"

    nohup /bin/bash "${runner_path}" >/dev/null 2>&1 &
    printf '%s' "$!"
}

main() {
    local name=""
    local log_path=""
    local cwd
    local command_string
    local unit_name=""
    local mode=""
    local meta_path=""
    local runner_path=""
    local pid=""
    local run_id=""

    cwd="$(pwd)"

    while (($# > 0)); do
        case "$1" in
            --name)
                [[ $# -ge 2 ]] || die "--name requires a value."
                name="$2"
                shift 2
                ;;
            --log)
                [[ $# -ge 2 ]] || die "--log requires a value."
                log_path="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    (($# > 0)) || die "Command is required. Use -- before the command."
    require_root

    if [[ -z "${name}" ]]; then
        name="$(basename "$1")-$(date +%Y%m%d-%H%M%S)"
    fi

    name="$(sanitize_name "${name}")"
    [[ -n "${name}" ]] || die "Resolved empty job name."

    if [[ -z "${log_path}" ]]; then
        log_path="${DEFAULT_LOG_DIR}/${name}.log"
    fi

    [[ "${log_path}" = /* ]] || die "--log must be an absolute path."

    install -d -m 0755 "$(dirname "${log_path}")"
    touch "${log_path}"
    chmod 0600 "${log_path}"

    split_command_spec "$@"
    command_string="$(format_command_line "$@")"
    run_id="$(date +%Y%m%d-%H%M%S)"
    unit_name="ops-${name}-${run_id}"
    meta_path="${DEFAULT_STATE_DIR}/${name}.env"
    runner_path="${DEFAULT_STATE_DIR}/${name}-${run_id}.sh"
    create_runner_script "${runner_path}" "${log_path}" "${cwd}" "${command_string}"

    if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        mode="systemd"
        start_with_systemd "${unit_name}" "${runner_path}"
        write_metadata "${meta_path}" "${mode}" "${unit_name}" "${log_path}" "${cwd}" "${command_string}" "${runner_path}"
    else
        mode="nohup"
        pid="$(start_with_nohup "${runner_path}")"
        write_metadata "${meta_path}" "${mode}" "${unit_name}" "${log_path}" "${cwd}" "${command_string}" "${runner_path}"
        printf 'PID=%q\n' "${pid}" >> "${meta_path}"
    fi

    print_followup "${mode}" "${unit_name}" "${log_path}" "${meta_path}" "${runner_path}"
}

main "$@"
