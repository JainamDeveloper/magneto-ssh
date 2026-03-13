#!/usr/bin/env bash
# =============================================================================
# magneto-ssh — SSH connection manager for Magento environments
# Pure Bash. Zero dependencies beyond openssl, ssh, and sshpass (for passwords)
# =============================================================================

set -euo pipefail

# ── Version ───────────────────────────────────────────────────────────────────
VERSION="1.2.0"

# ── Paths ─────────────────────────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.magneto-ssh"
SERVERS_DIR="${CONFIG_DIR}/servers"
KEYS_DIR="${CONFIG_DIR}/keys"
VERIFY_FILE="${CONFIG_DIR}/.verify"

# ── ANSI colors ───────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' NC=''
fi

# ── Output helpers ────────────────────────────────────────────────────────────
ok()   { printf "${GREEN}✓${NC} %b\n"   "$*"; }
err()  { printf "${RED}✗${NC} %b\n"    "$*" >&2; }
warn() { printf "${YELLOW}!${NC} %b\n" "$*"; }
die()  { err "$*"; exit 1; }

# ── Directory setup ───────────────────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "${SERVERS_DIR}" "${KEYS_DIR}"
    chmod 700 "${CONFIG_DIR}" "${SERVERS_DIR}" "${KEYS_DIR}"
}

# ── Encryption helpers ────────────────────────────────────────────────────────
# _MSSH_PASS is used as env var to safely pass passwords with special characters.
# Both functions return 1 on failure instead of triggering set -e.

encrypt_value() {
    local plaintext="$1" password="$2"
    [[ -z "${plaintext}" ]] && return 0
    export _MSSH_PASS="${password}"
    local result
    result=$(printf '%s' "${plaintext}" \
        | openssl enc -aes-256-cbc -pbkdf2 -iter 310000 -salt \
            -pass env:_MSSH_PASS -base64 -A 2>/dev/null) \
        || { unset _MSSH_PASS; return 1; }
    unset _MSSH_PASS
    printf '%s' "${result}"
}

decrypt_value() {
    local encrypted="$1" password="$2"
    [[ -z "${encrypted}" ]] && return 0
    export _MSSH_PASS="${password}"
    local result
    result=$(printf '%s' "${encrypted}" \
        | openssl enc -aes-256-cbc -pbkdf2 -iter 310000 -d \
            -pass env:_MSSH_PASS -base64 -A 2>/dev/null) \
        || { unset _MSSH_PASS; return 1; }
    unset _MSSH_PASS
    printf '%s' "${result}"
}

is_initialized() {
    [[ -f "${VERIFY_FILE}" ]]
}

require_init() {
    is_initialized || die "Not initialised. Run: magneto-ssh init"
}

# Prompt for and verify master password. Stores result in global MASTER_PW.
prompt_master_password() {
    require_init
    printf "  Master password: "
    read -rs MASTER_PW; printf '\n'
    local stored result
    stored=$(cat "${VERIFY_FILE}")
    result=$(decrypt_value "${stored}" "${MASTER_PW}") \
        || die "Incorrect master password."
    [[ "${result}" == "magneto-ssh-verified-v1" ]] \
        || die "Incorrect master password."
}

# ── Config field I/O ──────────────────────────────────────────────────────────

server_file()   { printf '%s' "${SERVERS_DIR}/$1"; }
server_exists() { [[ -f "$(server_file "$1")" ]]; }

read_field() {
    local file="$1" key="$2"
    grep "^${key}=" "${file}" 2>/dev/null | head -1 | cut -d'=' -f2- || true
}

write_server() {
    local name="$1"
    local file; file=$(server_file "${name}")
    ensure_dirs
    cat > "${file}"
    chmod 600 "${file}"
}

list_server_names() {
    find "${SERVERS_DIR}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
}

# ── TCP reachability (uses bash built-in /dev/tcp, no nc required) ────────────
tcp_check() {
    local host="$1" port="$2" timeout="${3:-5}"
    timeout "${timeout}" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

# =============================================================================
# Commands
# =============================================================================

cmd_init() {
    ensure_dirs

    if is_initialized; then
        printf "Already initialised. Re-initialise? This invalidates all stored passwords. [y/N] "
        read -r confirm
        [[ "${confirm,,}" == "y" ]] || exit 0
    fi

    printf "\n${BOLD}magneto-ssh setup${NC}\n"
    printf "${DIM}The master password encrypts SSH passwords and other secrets.\n"
    printf "There is no recovery — do not forget it.\n\n${NC}"

    local pw1 pw2
    printf "  Master password: ";  read -rs pw1; printf '\n'
    printf "  Confirm password: "; read -rs pw2; printf '\n'

    [[ -n "${pw1}" ]]          || die "Password cannot be empty."
    [[ "${pw1}" == "${pw2}" ]] || die "Passwords do not match."

    local token
    token=$(encrypt_value "magneto-ssh-verified-v1" "${pw1}") \
        || die "openssl failed. Is openssl installed?"
    printf '%s\n' "${token}" > "${VERIFY_FILE}"
    chmod 600 "${VERIFY_FILE}"

    printf '\n'; ok "Master password set. magneto-ssh is ready.\n"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_add() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh add <name>"

    if server_exists "${name}"; then
        printf "Server '%s' already exists. Overwrite? [y/N] " "${name}"
        read -r confirm
        [[ "${confirm,,}" == "y" ]] || exit 0
    fi

    printf "\n${BOLD}Adding server:${NC} ${CYAN}%s${NC}\n\n" "${name}"

    # ── Required fields ───────────────────────────────────────────────────────
    local host port user auth_type
    printf "  Host (IP or domain): "; read -r host
    [[ -n "${host}" ]] || die "Host is required."

    printf "  Port [22]: "; read -r port; port="${port:-22}"
    [[ "${port}" =~ ^[0-9]+$ && "${port}" -ge 1 && "${port}" -le 65535 ]] \
        || die "Invalid port: ${port}"

    printf "  SSH user: "; read -r user
    [[ -n "${user}" ]] || die "User is required."

    printf "  Auth type:\n    1) password\n    2) ssh_key\n"
    printf "  Select [1/2]: "; read -r auth_choice
    [[ "${auth_choice}" == "2" ]] && auth_type="ssh_key" || auth_type="password"

    # ── Auth credentials (collect raw first, no master password yet) ──────────
    local raw_pw="" ssh_key=""
    if [[ "${auth_type}" == "password" ]]; then
        printf "  SSH password: "; read -rs raw_pw; printf '\n'
    else
        printf "  Path to SSH key [~/.ssh/id_rsa]: "; read -r ssh_key
        ssh_key="${ssh_key:-~/.ssh/id_rsa}"
    fi

    # ── Optional metadata ─────────────────────────────────────────────────────
    printf "\n${DIM}  Optional fields — press Enter to skip:${NC}\n"

    local project_dir admin_url admin_user raw_admin_pw frontend_url raw_git_token
    printf "  Project directory: ";  read -r project_dir
    printf "  Admin URL: ";          read -r admin_url
    printf "  Admin username: ";     read -r admin_user

    raw_admin_pw=""
    if [[ -n "${admin_user}" ]]; then
        printf "  Admin password: "; read -rs raw_admin_pw; printf '\n'
    fi

    printf "  Frontend URL: ";  read -r frontend_url
    printf "  Git token: ";     read -rs raw_git_token; printf '\n'

    # ── Database (optional) ──────────────────────────────────────────────────
    local db_host db_port db_name db_user raw_db_pw tunnel_local_port
    printf "\n${DIM}  Database (optional — for SSH tunnel / DBeaver):${NC}\n"
    printf "  DB host [127.0.0.1]: ";   read -r db_host;          db_host="${db_host:-127.0.0.1}"
    printf "  DB port [3306]: ";        read -r db_port;           db_port="${db_port:-3306}"
    printf "  DB name: ";               read -r db_name
    printf "  DB user: ";               read -r db_user
    raw_db_pw=""
    if [[ -n "${db_user}" ]]; then
        printf "  DB password: ";       read -rs raw_db_pw; printf "\n"
    fi
    printf "  Local tunnel port [13306]: "; read -r tunnel_local_port
    tunnel_local_port="${tunnel_local_port:-13306}"

    # ── Ask master password only if there is something to encrypt ─────────────
    local password_enc="" admin_password_enc="" git_token_enc="" db_password_enc=""
    local needs_encrypt=false
    [[ -n "${raw_pw}" || -n "${raw_admin_pw}" || -n "${raw_git_token}" ]] \
        && needs_encrypt=true

    if [[ "${needs_encrypt}" == true ]]; then
        printf '\n'
        prompt_master_password
        [[ -n "${raw_pw}" ]]         && password_enc=$(encrypt_value "${raw_pw}" "${MASTER_PW}")
        [[ -n "${raw_admin_pw}" ]]   && admin_password_enc=$(encrypt_value "${raw_admin_pw}" "${MASTER_PW}")
        [[ -n "${raw_git_token}" ]]  && git_token_enc=$(encrypt_value "${raw_git_token}" "${MASTER_PW}")
    fi

    # ── Save ──────────────────────────────────────────────────────────────────
    write_server "${name}" <<EOF
HOST=${host}
PORT=${port}
USER=${user}
AUTH_TYPE=${auth_type}
PASSWORD=${password_enc}
SSH_KEY=${ssh_key}
PROJECT_DIR=${project_dir}
ADMIN_URL=${admin_url}
ADMIN_USER=${admin_user}
ADMIN_PASSWORD=${admin_password_enc}
FRONTEND_URL=${frontend_url}
GIT_TOKEN=${git_token_enc}
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password_enc}
TUNNEL_LOCAL_PORT=${tunnel_local_port}
EOF

    printf '\n'; ok "Server ${CYAN}${name}${NC} saved.\n"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_update() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh update <name>"
    server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"

    local file; file=$(server_file "${name}")

    # Load all existing values
    local cur_host cur_port cur_user cur_auth_type cur_password_enc
    local cur_ssh_key cur_project_dir cur_admin_url cur_admin_user
    local cur_admin_password_enc cur_frontend_url cur_git_token_enc

    cur_host=$(read_field "${file}" HOST)
    cur_port=$(read_field "${file}" PORT)
    cur_user=$(read_field "${file}" USER)
    cur_auth_type=$(read_field "${file}" AUTH_TYPE)
    cur_password_enc=$(read_field "${file}" PASSWORD)
    cur_ssh_key=$(read_field "${file}" SSH_KEY)
    cur_project_dir=$(read_field "${file}" PROJECT_DIR)
    cur_admin_url=$(read_field "${file}" ADMIN_URL)
    cur_admin_user=$(read_field "${file}" ADMIN_USER)
    cur_admin_password_enc=$(read_field "${file}" ADMIN_PASSWORD)
    cur_frontend_url=$(read_field "${file}" FRONTEND_URL)
    cur_git_token_enc=$(read_field "${file}" GIT_TOKEN)
    local cur_db_host cur_db_port cur_db_name cur_db_user cur_db_password_enc cur_tunnel_local_port
    cur_db_host=$(read_field "${file}" DB_HOST)
    cur_db_port=$(read_field "${file}" DB_PORT)
    cur_db_name=$(read_field "${file}" DB_NAME)
    cur_db_user=$(read_field "${file}" DB_USER)
    cur_db_password_enc=$(read_field "${file}" DB_PASSWORD)
    cur_tunnel_local_port=$(read_field "${file}" TUNNEL_LOCAL_PORT)

    printf "\n${BOLD}Updating server:${NC} ${CYAN}%s${NC}\n" "${name}"
    printf "${DIM}Press Enter to keep the current value shown in [ ]${NC}\n\n"

    # ── Rename ────────────────────────────────────────────────────────────────
    local new_name
    printf "  Server name [%s]: " "${name}"; read -r new_name
    new_name="${new_name:-${name}}"
    if [[ "${new_name}" != "${name}" ]] && server_exists "${new_name}"; then
        printf "Server '%s' already exists. Overwrite? [y/N] " "${new_name}"
        read -r confirm
        [[ "${confirm,,}" == "y" ]] || exit 0
    fi

    # ── Non-secret fields ─────────────────────────────────────────────────────
    local host port user auth_type
    printf "  Host [%s]: " "${cur_host}";  read -r host;  host="${host:-${cur_host}}"
    [[ -n "${host}" ]] || die "Host is required."

    printf "  Port [%s]: " "${cur_port}";  read -r port;  port="${port:-${cur_port}}"
    [[ "${port}" =~ ^[0-9]+$ && "${port}" -ge 1 && "${port}" -le 65535 ]] \
        || die "Invalid port: ${port}"

    printf "  SSH user [%s]: " "${cur_user}"; read -r user; user="${user:-${cur_user}}"
    [[ -n "${user}" ]] || die "User is required."

    printf "  Auth type (current: %s):\n    1) password\n    2) ssh_key\n" "${cur_auth_type}"
    printf "  Select [Enter to keep]: "; read -r auth_choice
    case "${auth_choice}" in
        1) auth_type="password" ;;
        2) auth_type="ssh_key"  ;;
        *) auth_type="${cur_auth_type}" ;;
    esac

    # ── Auth credentials ──────────────────────────────────────────────────────
    local raw_pw="" ssh_key=""
    if [[ "${auth_type}" == "password" ]]; then
        printf "  SSH password [Enter to keep current]: "; read -rs raw_pw; printf '\n'
        ssh_key=""
    else
        printf "  Path to SSH key [%s]: " "${cur_ssh_key}"; read -r ssh_key
        ssh_key="${ssh_key:-${cur_ssh_key}}"
    fi

    # ── Optional metadata ─────────────────────────────────────────────────────
    printf "\n${DIM}  Optional fields — press Enter to keep current value:${NC}\n"

    local project_dir admin_url admin_user raw_admin_pw frontend_url raw_git_token
    printf "  Project directory [%s]: " "${cur_project_dir}"; read -r project_dir
    project_dir="${project_dir:-${cur_project_dir}}"

    printf "  Admin URL [%s]: " "${cur_admin_url}"; read -r admin_url
    admin_url="${admin_url:-${cur_admin_url}}"

    printf "  Admin username [%s]: " "${cur_admin_user}"; read -r admin_user
    admin_user="${admin_user:-${cur_admin_user}}"

    raw_admin_pw=""
    printf "  Admin password [Enter to keep current]: "; read -rs raw_admin_pw; printf '\n'

    printf "  Frontend URL [%s]: " "${cur_frontend_url}"; read -r frontend_url
    frontend_url="${frontend_url:-${cur_frontend_url}}"

    raw_git_token=""
    printf "  Git token [Enter to keep current]: "; read -rs raw_git_token; printf '\n'

    printf "\n${DIM}  Database — press Enter to keep current:${NC}\n"
    local db_host db_port db_name db_user raw_db_pw tunnel_local_port
    printf "  DB host [%s]: " "${cur_db_host:-127.0.0.1}"; read -r db_host
    db_host="${db_host:-${cur_db_host:-127.0.0.1}}"
    printf "  DB port [%s]: " "${cur_db_port:-3306}"; read -r db_port
    db_port="${db_port:-${cur_db_port:-3306}}"
    printf "  DB name [%s]: " "${cur_db_name}"; read -r db_name
    db_name="${db_name:-${cur_db_name}}"
    printf "  DB user [%s]: " "${cur_db_user}"; read -r db_user
    db_user="${db_user:-${cur_db_user}}"
    raw_db_pw=""
    printf "  DB password [Enter to keep current]: "; read -rs raw_db_pw; printf '\n'
    printf "  Tunnel local port [%s]: " "${cur_tunnel_local_port:-13306}"; read -r tunnel_local_port
    tunnel_local_port="${tunnel_local_port:-${cur_tunnel_local_port:-13306}}"

    # ── Only ask master password if a secret field is being changed ───────────
    local password_enc="${cur_password_enc}"
    local admin_password_enc="${cur_admin_password_enc}"
    local git_token_enc="${cur_git_token_enc}"
    local db_password_enc="${cur_db_password_enc}"

    local needs_encrypt=false
    [[ -n "${raw_pw}" || -n "${raw_admin_pw}" || -n "${raw_git_token}" || -n "${raw_db_pw}" ]] \
        && needs_encrypt=true

    if [[ "${needs_encrypt}" == true ]]; then
        printf '\n'
        prompt_master_password
        [[ -n "${raw_pw}" ]]        && password_enc=$(encrypt_value "${raw_pw}" "${MASTER_PW}")
        [[ -n "${raw_admin_pw}" ]]  && admin_password_enc=$(encrypt_value "${raw_admin_pw}" "${MASTER_PW}")
        [[ -n "${raw_git_token}" ]] && git_token_enc=$(encrypt_value "${raw_git_token}" "${MASTER_PW}")
        [[ -n "${raw_db_pw}" ]]     && db_password_enc=$(encrypt_value "${raw_db_pw}" "${MASTER_PW}")
    fi

    # If auth_type switched away from password, clear the stored password
    [[ "${auth_type}" == "ssh_key" ]] && password_enc=""

    # ── Save ──────────────────────────────────────────────────────────────────
    write_server "${new_name}" <<EOF
HOST=${host}
PORT=${port}
USER=${user}
AUTH_TYPE=${auth_type}
PASSWORD=${password_enc}
SSH_KEY=${ssh_key}
PROJECT_DIR=${project_dir}
ADMIN_URL=${admin_url}
ADMIN_USER=${admin_user}
ADMIN_PASSWORD=${admin_password_enc}
FRONTEND_URL=${frontend_url}
GIT_TOKEN=${git_token_enc}
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password_enc}
TUNNEL_LOCAL_PORT=${tunnel_local_port}
EOF

    if [[ "${new_name}" != "${name}" ]]; then
        rm "$(server_file "${name}")"
        printf '\n'; ok "Server ${CYAN}${name}${NC} renamed to ${CYAN}${new_name}${NC} and updated."
    else
        printf '\n'; ok "Server ${CYAN}${new_name}${NC} updated."
    fi
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_ssh() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh ssh <name>"
    server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"

    local file; file=$(server_file "${name}")

    local host port user auth_type password_enc ssh_key project_dir
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    password_enc=$(read_field "${file}" PASSWORD)
    ssh_key=$(read_field "${file}" SSH_KEY)
    project_dir=$(read_field "${file}" PROJECT_DIR)

    local remote_cmd="exec \$SHELL"
    [[ -n "${project_dir}" ]] && remote_cmd="cd ${project_dir} && exec \$SHELL"

    printf "\n${DIM}Connecting to${NC} ${CYAN}%s${NC} ${DIM}→ %s@%s:%s${NC}\n\n" \
        "${name}" "${user}" "${host}" "${port}"

    local ssh_opts=(-p "${port}"
                    -o StrictHostKeyChecking=accept-new
                    -o ConnectTimeout=10)

    if [[ "${auth_type}" == "password" ]]; then
        prompt_master_password
        local password
        password=$(decrypt_value "${password_enc}" "${MASTER_PW}") \
            || die "Failed to decrypt password. Was the master password changed?"
        command -v sshpass &>/dev/null \
            || die "sshpass not installed. Run: sudo apt install sshpass"
        exec sshpass -p "${password}" \
            ssh "${ssh_opts[@]}" "${user}@${host}" -t "${remote_cmd}"
    else
        local expanded_key="${ssh_key/#\~/${HOME}}"
        [[ -f "${expanded_key}" ]] || die "SSH key not found: ${ssh_key}"
        exec ssh "${ssh_opts[@]}" -i "${expanded_key}" "${user}@${host}" -t "${remote_cmd}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_list() {
    ensure_dirs
    local servers
    mapfile -t servers < <(list_server_names)

    if [[ ${#servers[@]} -eq 0 ]]; then
        warn "No servers configured. Use: magneto-ssh add <name>"
        return
    fi

    printf '\n'
    printf "${BOLD}${CYAN}%-30s %-22s %-14s %-6s %-10s %s${NC}\n" \
        "NAME" "HOST" "USER" "PORT" "AUTH" "PROJECT DIR"
    printf '%0.s─' {1..95}; printf '\n'

    for name in "${servers[@]}"; do
        local file; file=$(server_file "${name}")
        local host user port auth_type project_dir
        host=$(read_field "${file}" HOST)
        user=$(read_field "${file}" USER)
        port=$(read_field "${file}" PORT)
        auth_type=$(read_field "${file}" AUTH_TYPE)
        project_dir=$(read_field "${file}" PROJECT_DIR)
        printf "%-30s %-22s %-14s %-6s %-10s %s\n" \
            "${name}" "${host}" "${user}" "${port}" \
            "${auth_type}" "${project_dir:--}"
    done
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_info() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh info <name>"
    server_exists "${name}" || die "Server '${name}' not found."

    local file; file=$(server_file "${name}")

    printf "\n${BOLD}${CYAN}%s${NC}\n" "${name}"

    local -A labels=(
        [HOST]="Host" [PORT]="Port" [USER]="User" [AUTH_TYPE]="Auth type"
        [SSH_KEY]="SSH key" [PROJECT_DIR]="Project dir"
        [ADMIN_URL]="Admin URL" [ADMIN_USER]="Admin user" [FRONTEND_URL]="Frontend URL"
    )
    local field_order=(HOST PORT USER AUTH_TYPE SSH_KEY PROJECT_DIR
                       ADMIN_URL ADMIN_USER FRONTEND_URL)

    for field in "${field_order[@]}"; do
        local val; val=$(read_field "${file}" "${field}")
        [[ -n "${val}" ]] && printf "  %-16s %s\n" "${labels[$field]}" "${val}"
    done

    local -A secret_labels=([PASSWORD]="SSH password" [ADMIN_PASSWORD]="Admin pass" [GIT_TOKEN]="Git token")
    for field in PASSWORD ADMIN_PASSWORD GIT_TOKEN; do
        local val; val=$(read_field "${file}" "${field}")
        [[ -n "${val}" ]] && printf "  %-16s ${DIM}[encrypted]${NC}\n" "${secret_labels[$field]}"
    done
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_remove() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh remove <name>"
    server_exists "${name}" || die "Server '${name}' not found."

    printf "Remove server '%s'? [y/N] " "${name}"
    read -r confirm
    [[ "${confirm,,}" == "y" ]] || exit 0

    rm "$(server_file "${name}")"
    ok "Server ${CYAN}${name}${NC} removed.\n"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_validate() {
    ensure_dirs

    local timeout=5
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout|-t) timeout="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local servers
    mapfile -t servers < <(list_server_names)
    [[ ${#servers[@]} -eq 0 ]] && { warn "No servers configured."; return; }

    local needs_master=false
    for name in "${servers[@]}"; do
        local file; file=$(server_file "${name}")
        local auth_type pw
        auth_type=$(read_field "${file}" AUTH_TYPE)
        pw=$(read_field "${file}" PASSWORD)
        [[ "${auth_type}" == "password" && -n "${pw}" ]] && { needs_master=true; break; }
    done

    MASTER_PW=""
    [[ "${needs_master}" == true ]] && prompt_master_password

    printf "\n${BOLD}Checking servers...${NC}\n\n"

    local pad=0
    for name in "${servers[@]}"; do (( ${#name} > pad )) && pad=${#name}; done
    (( pad += 4 ))

    local ok_count=0 fail_count=0

    for name in "${servers[@]}"; do
        local file; file=$(server_file "${name}")
        local host port user auth_type password_enc ssh_key
        host=$(read_field "${file}" HOST)
        port=$(read_field "${file}" PORT)
        user=$(read_field "${file}" USER)
        auth_type=$(read_field "${file}" AUTH_TYPE)
        password_enc=$(read_field "${file}" PASSWORD)
        ssh_key=$(read_field "${file}" SSH_KEY)

        local padded; padded=$(printf "%-${pad}s" "${name}")

        if [[ "${auth_type}" == "password" ]]; then
            if [[ -z "${password_enc}" || -z "${MASTER_PW}" ]]; then
                if tcp_check "${host}" "${port}" "${timeout}"; then
                    printf "  %s ${GREEN}✓${NC}  TCP reachable (no password to test)\n" "${padded}"
                    (( ++ok_count ))
                else
                    printf "  %s ${RED}✗${NC}  unreachable\n" "${padded}"
                    (( ++fail_count ))
                fi
                continue
            fi

            local password
            password=$(decrypt_value "${password_enc}" "${MASTER_PW}") \
                || { printf "  %s ${RED}✗${NC}  decryption failed\n" "${padded}"; (( ++fail_count )); continue; }

            if ! command -v sshpass &>/dev/null; then
                if tcp_check "${host}" "${port}" "${timeout}"; then
                    printf "  %s ${YELLOW}!${NC}  TCP reachable (sshpass not installed)\n" "${padded}"
                    (( ++ok_count ))
                else
                    printf "  %s ${RED}✗${NC}  unreachable\n" "${padded}"
                    (( ++fail_count ))
                fi
                continue
            fi

            if sshpass -p "${password}" ssh \
                    -p "${port}" \
                    -o StrictHostKeyChecking=accept-new \
                    -o ConnectTimeout="${timeout}" \
                    -o BatchMode=no \
                    "${user}@${host}" "exit" &>/dev/null 2>&1; then
                printf "  %s ${GREEN}✓${NC}  connected\n" "${padded}"
                (( ++ok_count ))
            else
                printf "  %s ${RED}✗${NC}  connection failed\n" "${padded}"
                (( ++fail_count ))
            fi
        else
            local expanded_key="${ssh_key/#\~/${HOME}}"
            if ssh -i "${expanded_key}" -p "${port}" \
                    -o StrictHostKeyChecking=accept-new \
                    -o ConnectTimeout="${timeout}" \
                    -o BatchMode=yes \
                    "${user}@${host}" "exit" &>/dev/null 2>&1; then
                printf "  %s ${GREEN}✓${NC}  connected\n" "${padded}"
                (( ++ok_count ))
            else
                printf "  %s ${RED}✗${NC}  connection failed\n" "${padded}"
                (( ++fail_count ))
            fi
        fi
    done

    printf '\n'
    local total=$(( ok_count + fail_count ))
    if [[ ${fail_count} -eq 0 ]]; then
        ok "All ${total} server(s) reachable.\n"
    else
        warn "${ok_count}/${total} reachable, ${fail_count} failed.\n"
    fi
}


cmd_filezilla() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh filezilla <name>"
    local file="${SERVERS_DIR}/${name}"
    [[ -f "${file}" ]] || die "Server not found: ${name}"

    prompt_master_password
    local pass="${MASTER_PW}"

    local host port user auth_type ssh_pass project_dir
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    project_dir=$(read_field "${file}" PROJECT_DIR)

    local uri
    if [[ "${auth_type}" == "password" ]]; then
        local enc_pass raw_pass
        enc_pass=$(read_field "${file}" PASSWORD)
        raw_pass=$(decrypt_value "${enc_pass}" "${pass}") \
            || die "Failed to decrypt SSH password. Wrong master password?"
        # URL-encode the password for the URI
        local encoded_pass
        encoded_pass=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "${raw_pass}")
        uri="sftp://${user}:${encoded_pass}@${host}:${port}"
    else
        uri="sftp://${user}@${host}:${port}"
    fi

    [[ -n "${project_dir}" ]] && uri="${uri}/${project_dir#/}"

    if ! command -v filezilla &>/dev/null; then
        die "FileZilla not found. Install it with: sudo apt install filezilla"
    fi

    ok "Launching FileZilla → ${name} (${host}:${port})"
    filezilla "${uri}" &
    disown
}


cmd_tunnel() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh tunnel <name>"
    local file="${SERVERS_DIR}/${name}"
    [[ -f "${file}" ]] || die "Server not found: ${name}"

    prompt_master_password
    local pass="${MASTER_PW}"

    local host port user auth_type db_host db_port tunnel_local_port
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    db_host=$(read_field "${file}" DB_HOST)
    db_port=$(read_field "${file}" DB_PORT)
    tunnel_local_port=$(read_field "${file}" TUNNEL_LOCAL_PORT)

    db_host="${db_host:-127.0.0.1}"
    db_port="${db_port:-3306}"
    tunnel_local_port="${tunnel_local_port:-13306}"

    # Kill any existing tunnel on the same local port
    local existing_pid
    existing_pid=$(lsof -ti "tcp:${tunnel_local_port}" 2>/dev/null || true)
    if [[ -n "${existing_pid}" ]]; then
        kill "${existing_pid}" 2>/dev/null || true
        warn "Killed existing tunnel on port ${tunnel_local_port}."
    fi

    ok "Opening SSH tunnel: localhost:${tunnel_local_port} → ${db_host}:${db_port} via ${host}"

    if [[ "${auth_type}" == "password" ]]; then
        local enc_pass raw_pass
        enc_pass=$(read_field "${file}" PASSWORD)
        raw_pass=$(decrypt_value "${enc_pass}" "${pass}") \
            || die "Failed to decrypt SSH password. Wrong master password?"
        export SSHPASS="${raw_pass}"
        sshpass -e ssh -f -N \
            -o StrictHostKeyChecking=accept-new \
            -o ExitOnForwardFailure=yes \
            -L "${tunnel_local_port}:${db_host}:${db_port}" \
            -p "${port}" "${user}@${host}"
        unset SSHPASS
    else
        local key_path
        key_path=$(read_field "${file}" SSH_KEY)
        local key_args=()
        [[ -n "${key_path}" ]] && key_args=(-i "${key_path}")
        ssh -f -N \
            "${key_args[@]}" \
            -o StrictHostKeyChecking=accept-new \
            -o ExitOnForwardFailure=yes \
            -L "${tunnel_local_port}:${db_host}:${db_port}" \
            -p "${port}" "${user}@${host}"
    fi

    local db_name db_user
    db_name=$(read_field "${file}" DB_NAME)
    db_user=$(read_field "${file}" DB_USER)

    printf "\n"
    ok "Tunnel active on localhost:${tunnel_local_port}"
    printf "  ${BOLD}Host:${NC}      127.0.0.1\n"
    printf "  ${BOLD}Port:${NC}      ${tunnel_local_port}\n"
    printf "  ${BOLD}Database:${NC}  ${db_name:-<not set>}\n"
    printf "  ${BOLD}User:${NC}      ${db_user:-<not set>}\n"
    printf "\nClose tunnel:  kill \$(lsof -ti tcp:${tunnel_local_port})\n"
}


cmd_dbeaver() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh dbeaver <name>"
    local file="${SERVERS_DIR}/${name}"
    [[ -f "${file}" ]] || die "Server not found: ${name}"

    if ! command -v dbeaver &>/dev/null && ! command -v dbeaver-ce &>/dev/null; then
        die "DBeaver not found. Install it from https://dbeaver.io"
    fi

    # Open the tunnel first
    cmd_tunnel "${name}"

    local tunnel_local_port db_name db_user db_password_enc
    tunnel_local_port=$(read_field "${file}" TUNNEL_LOCAL_PORT)
    tunnel_local_port="${tunnel_local_port:-13306}"
    db_name=$(read_field "${file}" DB_NAME)
    db_user=$(read_field "${file}" DB_USER)
    db_password_enc=$(read_field "${file}" DB_PASSWORD)

    local pass="${MASTER_PW}"

    local db_pass=""
    if [[ -n "${db_password_enc}" ]]; then
        db_pass=$(decrypt_value "${db_password_enc}" "${pass}") \
            || warn "Could not decrypt DB password — you may need to enter it in DBeaver."
    fi

    local con_str="driver=mysql8|host=127.0.0.1|port=${tunnel_local_port}"
    [[ -n "${db_name}" ]] && con_str="${con_str}|database=${db_name}"
    [[ -n "${db_user}" ]] && con_str="${con_str}|user=${db_user}"
    [[ -n "${db_pass}"  ]] && con_str="${con_str}|password=${db_pass}"
    con_str="${con_str}|name=${name}|save=true|connect=true"

    ok "Launching DBeaver → ${name} (127.0.0.1:${tunnel_local_port})"
    local dbeaver_bin
    dbeaver_bin=$(command -v dbeaver 2>/dev/null || command -v dbeaver-ce)
    "${dbeaver_bin}" -con "${con_str}" &
    disown
}


cmd_import() {
    local xml_file="${1:-}"
    [[ -n "${xml_file}" ]] || die "Usage: magneto-ssh import <filezilla_export.xml>"
    [[ -f "${xml_file}" ]] || die "File not found: ${xml_file}"
    command -v python3 &>/dev/null || die "python3 is required for XML import."

    printf "\n${BOLD}Parsing FileZilla XML:${NC} %s\n\n" "${xml_file}"

    # Parse with python3 stdlib — outputs TSV lines:
    # slug \t host \t port \t user \t auth_type \t raw_pw \t keyfile \t project_dir \t orig_name
    local parsed_data
    parsed_data=$(python3 -c "
import base64, xml.etree.ElementTree as ET, re, sys

def parse_dir(s):
    if not s: return ''
    p = s.split()
    if len(p) < 2: return ''
    idx, segs = 2, []
    while idx + 1 < len(p):
        segs.append(p[idx+1]); idx += 2
    return ('/' if p[0]=='1' else '') + '/'.join(segs)

def slug(n):
    s = re.sub(r'[^a-z0-9]+', '_', n.lower().strip())
    return re.sub(r'_+', '_', s).strip('_')

tree = ET.parse(sys.argv[1])
for s in tree.getroot().iter('Server'):
    host = (s.findtext('Host') or '').strip()
    port = (s.findtext('Port') or '22').strip()
    user = (s.findtext('User') or '').strip()
    name = (s.findtext('Name') or '').strip()
    lt   = (s.findtext('Logontype') or '1').strip()
    kf   = (s.findtext('Keyfile') or '').strip()
    rd   = parse_dir(s.findtext('RemoteDir') or '')
    pw   = ''
    pe   = s.find('Pass')
    if pe is not None and pe.get('encoding')=='base64' and pe.text:
        try: pw = base64.b64decode(pe.text).decode('utf-8')
        except: pass
    auth = 'ssh_key' if (lt=='5' or kf) else 'password'
    sl   = slug(name) if name else slug(host)
    row  = [sl, host, port, user, auth, pw, kf, rd, name]
    print('\x01'.join(f.replace('\x01',' ').replace('\n',' ') for f in row))
" "${xml_file}" 2>&1) || die "XML parse failed: ${parsed_data}"

    [[ -n "${parsed_data}" ]] || { warn "No servers found in XML."; return; }

    # ── Count servers and check for passwords ─────────────────────────────────
    local total=0 has_password=false
    while IFS=$'\x01' read -r sl host port user auth pw kf rd name; do
        (( ++total ))
        [[ -n "${pw}" ]] && has_password=true
    done <<< "${parsed_data}"

    # ── Preview table ─────────────────────────────────────────────────────────
    printf "${BOLD}Found %d servers to import:${NC}\n\n" "${total}"
    printf "${BOLD}${CYAN}%-32s %-24s %-6s %-14s %-10s %s${NC}\n" \
        "NAME" "HOST" "PORT" "USER" "AUTH" "PROJECT DIR"
    printf '%0.s─' {1..100}; printf '\n'

    while IFS=$'\x01' read -r sl host port user auth pw kf rd name; do
        local pw_flag=""
        [[ -n "${pw}" ]] && pw_flag=" ${DIM}[has pw]${NC}"
        [[ -n "${kf}" ]] && pw_flag=" ${DIM}[key: $(basename "${kf}")]${NC}"
        printf "%-32s %-24s %-6s %-14s %-10s %b\n" \
            "${sl}" "${host}" "${port}" "${user}" "${auth}" "${rd:--}${pw_flag}"
    done <<< "${parsed_data}"

    # ── Confirm ───────────────────────────────────────────────────────────────
    printf '\n'
    local overwrite_all=false
    printf "Import %d servers? [y/N] " "${total}"; read -r confirm
    [[ "${confirm,,}" == "y" ]] || exit 0

    printf "Overwrite existing servers? [y/N] "; read -r ow
    [[ "${ow,,}" == "y" ]] && overwrite_all=true

    # ── Ask master password once (only if passwords to encrypt) ───────────────
    MASTER_PW=""
    if [[ "${has_password}" == true ]]; then
        printf '\n'
        prompt_master_password
    fi

    # ── Import servers ────────────────────────────────────────────────────────
    printf '\n'
    local imported=0 skipped=0

    while IFS=$'\x01' read -r sl host port user auth pw kf rd name; do
        if server_exists "${sl}" && [[ "${overwrite_all}" == false ]]; then
            printf "  ${YELLOW}!${NC} %-32s already exists — skipped\n" "${sl}"
            (( ++skipped )); continue
        fi

        local password_enc=""
        if [[ -n "${pw}" && -n "${MASTER_PW}" ]]; then
            password_enc=$(encrypt_value "${pw}" "${MASTER_PW}") || {
                printf "  ${RED}✗${NC} %-32s encrypt failed — skipped\n" "${sl}"
                (( ++skipped )); continue
            }
        fi

        printf 'HOST=%s\nPORT=%s\nUSER=%s\nAUTH_TYPE=%s\nPASSWORD=%s\nSSH_KEY=%s\nPROJECT_DIR=%s\nADMIN_URL=\nADMIN_USER=\nADMIN_PASSWORD=\nFRONTEND_URL=\nGIT_TOKEN=\n' \
            "${host}" "${port}" "${user}" "${auth}" \
            "${password_enc}" "${kf}" "${rd}" \
            | write_server "${sl}"

        printf "  ${GREEN}✓${NC} %-32s imported  ${DIM}(%s)${NC}\n" "${sl}" "${name}"
        (( ++imported ))
    done <<< "${parsed_data}"

    printf '\n'
    ok "${imported} server(s) imported, ${skipped} skipped."
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_help() {
    printf "
${BOLD}${CYAN}magneto-ssh${NC} ${DIM}v${VERSION}${NC}
SSH connection manager for Magento environments.

${BOLD}Usage:${NC}
  magneto-ssh <command> [arguments]

${BOLD}Commands:${NC}
  ${CYAN}init${NC}                     Set master password (run once)
  ${CYAN}add${NC}    <name>            Add a server interactively
  ${CYAN}update${NC} <name>            Update an existing server config
  ${CYAN}ssh${NC}    <name>            Connect to a server
  ${CYAN}list${NC}                     List all configured servers
  ${CYAN}info${NC}   <name>            Show server details (no passwords shown)
  ${CYAN}remove${NC} <name>            Delete a server config
  ${CYAN}import${NC}   <file.xml>        Import servers from FileZilla XML export
  ${CYAN}validate${NC} [--timeout N]   Test connectivity for all servers
  ${CYAN}filezilla${NC} <name>         Open server in FileZilla (SFTP)
  ${CYAN}tunnel${NC}   <name>          Create SSH tunnel to remote DB (localhost:TUNNEL_LOCAL_PORT)
  ${CYAN}dbeaver${NC}  <name>          Open tunnel + launch DBeaver with DB connection
  ${CYAN}version${NC}                  Print version

${BOLD}Tab completion:${NC}
  magneto-ssh install-completion   Add bash tab completion to ~/.bashrc

${BOLD}Examples:${NC}
  magneto-ssh init
  magneto-ssh add petzone_stage
  magneto-ssh update petzone_stage
  magneto-ssh ssh petzone_stage
  magneto-ssh list
  magneto-ssh info petzone_stage

${BOLD}Name format:${NC}  project_environment
  e.g.  petzone_stage   petzone_production   clientA_dev
"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_install_completion() {
    local bashrc="${HOME}/.bashrc"
    mkdir -p "${HOME}/.bash_completion.d"

    cat > "${HOME}/.bash_completion.d/magneto-ssh" <<'COMPLETION'
# magneto-ssh bash tab completion
_magneto_ssh_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    local cmds="init add update ssh list info remove import validate filezilla tunnel dbeaver install-completion version help"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=($(compgen -W "${cmds}" -- "${cur}"))
        compopt +o default 2>/dev/null
        return 0
    fi

    case "${prev}" in
        ssh|info|remove|add|update|filezilla|fz|tunnel|dbeaver|db)
            local servers=""
            [[ -d "${HOME}/.magneto-ssh/servers" ]] \
                && servers=$(ls "${HOME}/.magneto-ssh/servers" 2>/dev/null | tr '\n' ' ')
            COMPREPLY=($(compgen -W "${servers}" -- "${cur}"))
            compopt +o default 2>/dev/null
            return 0
            ;;
    esac

    COMPREPLY=()
    compopt +o default 2>/dev/null
    return 0
}
complete -F _magneto_ssh_complete magneto-ssh
COMPLETION

    local source_line='[[ -f "${HOME}/.bash_completion.d/magneto-ssh" ]] && source "${HOME}/.bash_completion.d/magneto-ssh"'
    if ! grep -q '.bash_completion.d/magneto-ssh' "${bashrc}" 2>/dev/null; then
        printf '\n# magneto-ssh completion\n%s\n' "${source_line}" >> "${bashrc}"
    fi

    ok "Tab completion installed. Run: source ~/.bash_completion.d/magneto-ssh"
}

# =============================================================================
# Main dispatcher
# =============================================================================

main() {
    local cmd="${1:-help}"
    shift || true

    case "${cmd}" in
        init)                   cmd_init ;;
        add)                    cmd_add "$@" ;;
        update|edit)            cmd_update "$@" ;;
        ssh)                    cmd_ssh "$@" ;;
        list)                   cmd_list ;;
        info)                   cmd_info "$@" ;;
        remove|rm|delete)       cmd_remove "$@" ;;
        import)                 cmd_import "$@" ;;
        filezilla|fz)           cmd_filezilla "$@" ;;
        tunnel)                 cmd_tunnel "$@" ;;
        dbeaver|db)             cmd_dbeaver "$@" ;;
        validate|check)         cmd_validate "$@" ;;
        version|--version|-v)   printf "magneto-ssh v%s\n" "${VERSION}" ;;
        install-completion)     cmd_install_completion ;;
        help|--help|-h)         cmd_help ;;
        *)                      err "Unknown command: ${cmd}"; cmd_help; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
