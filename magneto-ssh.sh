#!/usr/bin/env bash
# =============================================================================
# magneto-ssh — SSH connection manager for Magento environments
# Pure Bash. Zero dependencies beyond ssh and sshpass (for passwords)
# =============================================================================

set -euo pipefail

# ── Version ───────────────────────────────────────────────────────────────────
VERSION="1.3.002"

# ── Paths ─────────────────────────────────────────────────────────────────────
CONFIG_DIR="${HOME}/.magneto-ssh"
SERVERS_DIR="${CONFIG_DIR}/servers"
KEYS_DIR="${CONFIG_DIR}/keys"
UPDATE_CACHE="${CONFIG_DIR}/.update_cache"

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

# ── Interactive server picker ─────────────────────────────────────────────────
pick_server() {
    local prompt="${1:-Select server}"
    local names
    mapfile -t names < <(list_server_names)
    [[ ${#names[@]} -gt 0 ]] || die "No servers configured. Run: magneto-ssh add <name>"
    if command -v fzf &>/dev/null; then
        printf "%s\n" "${names[@]}" | fzf --prompt="${prompt}: " --height=40% --reverse --no-info
    else
        printf "${BOLD}%s:${NC}\n" "${prompt}" >&2
        select name in "${names[@]}"; do
            [[ -n "${name}" ]] && { printf "%s" "${name}"; return 0; }
            printf "Invalid selection.\n" >&2
        done
    fi
}

# ── TCP reachability (uses bash built-in /dev/tcp, no nc required) ────────────
tcp_check() {
    local host="$1" port="$2" timeout="${3:-5}"
    timeout "${timeout}" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

# =============================================================================
# Commands
# =============================================================================

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

    # ── Auth credentials ──────────────────────────────────────────────────────
    local password="" ssh_key=""
    if [[ "${auth_type}" == "password" ]]; then
        printf "  SSH password: "; read -rs password; printf '\n'
    else
        printf "  Path to SSH key [~/.ssh/id_rsa]: "; read -r ssh_key
        ssh_key="${ssh_key:-~/.ssh/id_rsa}"
    fi

    # ── Optional metadata ─────────────────────────────────────────────────────
    printf "\n${DIM}  Optional fields — press Enter to skip:${NC}\n"

    local project_dir admin_url admin_user admin_password frontend_url git_token
    printf "  Project directory: ";  read -r project_dir
    printf "  Admin URL: ";          read -r admin_url
    printf "  Admin username: ";     read -r admin_user

    admin_password=""
    if [[ -n "${admin_user}" ]]; then
        printf "  Admin password: "; read -rs admin_password; printf '\n'
    fi

    printf "  Frontend URL: ";  read -r frontend_url
    printf "  Git token: ";     read -rs git_token; printf '\n'

    # ── Database (optional) ──────────────────────────────────────────────────
    local db_host db_port db_name db_user db_password
    printf "\n${DIM}  Database (optional):${NC}\n"
    printf "  DB host [127.0.0.1]: ";   read -r db_host;          db_host="${db_host:-127.0.0.1}"
    printf "  DB port [3306]: ";        read -r db_port;           db_port="${db_port:-3306}"
    printf "  DB name: ";               read -r db_name
    printf "  DB user: ";               read -r db_user
    db_password=""
    if [[ -n "${db_user}" ]]; then
        printf "  DB password: ";       read -rs db_password; printf "\n"
    fi

    # ── Save ──────────────────────────────────────────────────────────────────
    write_server "${name}" <<EOF
HOST=${host}
PORT=${port}
USER=${user}
AUTH_TYPE=${auth_type}
PASSWORD=${password}
SSH_KEY=${ssh_key}
PROJECT_DIR=${project_dir}
ADMIN_URL=${admin_url}
ADMIN_USER=${admin_user}
ADMIN_PASSWORD=${admin_password}
FRONTEND_URL=${frontend_url}
GIT_TOKEN=${git_token}
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
EOF

    printf '\n'; ok "Server ${CYAN}${name}${NC} saved.\n"
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_update() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh edit <name>"
    server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"

    local file; file=$(server_file "${name}")

    # ── Load all current values ───────────────────────────────────────────────
    local cur_host cur_port cur_user cur_auth_type cur_password cur_ssh_key
    local cur_project_dir cur_admin_url cur_admin_user cur_admin_password
    local cur_frontend_url cur_git_token
    local cur_db_host cur_db_port cur_db_name cur_db_user cur_db_password

    cur_host=$(read_field "${file}" HOST)
    cur_port=$(read_field "${file}" PORT)
    cur_user=$(read_field "${file}" USER)
    cur_auth_type=$(read_field "${file}" AUTH_TYPE)
    cur_password=$(read_field "${file}" PASSWORD)
    cur_ssh_key=$(read_field "${file}" SSH_KEY)
    cur_project_dir=$(read_field "${file}" PROJECT_DIR)
    cur_admin_url=$(read_field "${file}" ADMIN_URL)
    cur_admin_user=$(read_field "${file}" ADMIN_USER)
    cur_admin_password=$(read_field "${file}" ADMIN_PASSWORD)
    cur_frontend_url=$(read_field "${file}" FRONTEND_URL)
    cur_git_token=$(read_field "${file}" GIT_TOKEN)
    cur_db_host=$(read_field "${file}" DB_HOST)
    cur_db_port=$(read_field "${file}" DB_PORT)
    cur_db_name=$(read_field "${file}" DB_NAME)
    cur_db_user=$(read_field "${file}" DB_USER)
    cur_db_password=$(read_field "${file}" DB_PASSWORD)

    # ── Field picker ─────────────────────────────────────────────────────────
    printf "\n${BOLD}Edit server:${NC} ${CYAN}%s${NC}\n" "${name}"

    local field_labels=(
        "Name            [${name}]"
        "Host            [${cur_host}]"
        "Port            [${cur_port}]"
        "SSH User        [${cur_user}]"
        "Auth Type       [${cur_auth_type}]"
        "SSH Password    $([ -n "${cur_password}" ] && echo "[set]" || echo "[not set]")"
        "SSH Key         [${cur_ssh_key}]"
        "Project Dir     [${cur_project_dir}]"
        "Admin URL       [${cur_admin_url}]"
        "Admin User      [${cur_admin_user}]"
        "Admin Password  $([ -n "${cur_admin_password}" ] && echo "[set]" || echo "[not set]")"
        "Frontend URL    [${cur_frontend_url}]"
        "Git Token       $([ -n "${cur_git_token}" ] && echo "[set]" || echo "[not set]")"
        "DB Host         [${cur_db_host}]"
        "DB Port         [${cur_db_port}]"
        "DB Name         [${cur_db_name}]"
        "DB User         [${cur_db_user}]"
        "DB Password     $([ -n "${cur_db_password}" ] && echo "[set]" || echo "[not set]")"
    )

    local -a chosen_indices=()
    if command -v fzf &>/dev/null; then
        printf "${DIM}  ↑↓ navigate  Tab=toggle  Enter=confirm${NC}\n\n"
        local selected
        selected=$(printf '%s\n' "${field_labels[@]}" \
            | fzf --multi --prompt="Select fields to edit: " \
                  --height=~100% --reverse --no-info \
                  --bind 'tab:toggle+down') || true
        while IFS= read -r line; do
            for i in "${!field_labels[@]}"; do
                [[ "${field_labels[$i]}" == "$line" ]] && chosen_indices+=("$i") && break
            done
        done <<< "$selected"
    else
        printf "${DIM}  Enter numbers separated by spaces (e.g. 1 3 6):${NC}\n\n"
        local i=1
        for label in "${field_labels[@]}"; do
            printf "  %2d) %s\n" "$i" "${label}"
            (( i++ ))
        done
        printf "\n  Fields to edit: "; read -r choices
        for n in ${choices}; do
            [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#field_labels[@]} )) \
                && chosen_indices+=("$((n-1))")
        done
    fi

    [[ ${#chosen_indices[@]} -gt 0 ]] || { warn "No fields selected. Nothing changed."; return 0; }

    _field_is_chosen() {
        local idx=$1
        for i in "${chosen_indices[@]}"; do
            [[ "$i" == "$idx" ]] && return 0
        done
        return 1
    }

    # ── Prompt only selected fields ───────────────────────────────────────────
    local new_name="${name}"
    if _field_is_chosen 0; then
        printf "  Server name [%s]: " "${name}"; read -r new_name
        new_name="${new_name:-${name}}"
        if [[ "${new_name}" != "${name}" ]] && server_exists "${new_name}"; then
            printf "Server '%s' already exists. Overwrite? [y/N] " "${new_name}"; read -r _ow
            [[ "${_ow,,}" == "y" ]] || exit 0
        fi
    fi

    local host="${cur_host}" port="${cur_port}" user="${cur_user}" auth_type="${cur_auth_type}"
    if _field_is_chosen 1; then
        printf "  Host [%s]: " "${cur_host}"; read -r host; host="${host:-${cur_host}}"
        [[ -n "${host}" ]] || die "Host is required."
    fi
    if _field_is_chosen 2; then
        printf "  Port [%s]: " "${cur_port}"; read -r port; port="${port:-${cur_port}}"
        [[ "${port}" =~ ^[0-9]+$ && "${port}" -ge 1 && "${port}" -le 65535 ]] || die "Invalid port."
    fi
    if _field_is_chosen 3; then
        printf "  SSH user [%s]: " "${cur_user}"; read -r user; user="${user:-${cur_user}}"
        [[ -n "${user}" ]] || die "User is required."
    fi
    if _field_is_chosen 4; then
        printf "  Auth type (current: %s):\n    1) password\n    2) ssh_key\n  Select: " "${cur_auth_type}"
        read -r _ac
        case "${_ac}" in 1) auth_type="password";; 2) auth_type="ssh_key";; esac
    fi

    local password="${cur_password}" ssh_key="${cur_ssh_key}"
    if _field_is_chosen 5 && [[ "${auth_type}" == "password" ]]; then
        printf "  New SSH password: "; read -rs password; printf '\n'
    fi
    if _field_is_chosen 6 && [[ "${auth_type}" == "ssh_key" ]]; then
        printf "  SSH key path [%s]: " "${cur_ssh_key}"; read -r ssh_key; ssh_key="${ssh_key:-${cur_ssh_key}}"
    fi

    local project_dir="${cur_project_dir}" admin_url="${cur_admin_url}" admin_user="${cur_admin_user}"
    local frontend_url="${cur_frontend_url}"
    if _field_is_chosen 7; then
        printf "  Project dir [%s]: " "${cur_project_dir}"; read -r project_dir
        project_dir="${project_dir:-${cur_project_dir}}"
    fi
    if _field_is_chosen 8; then
        printf "  Admin URL [%s]: " "${cur_admin_url}"; read -r admin_url
        admin_url="${admin_url:-${cur_admin_url}}"
    fi
    if _field_is_chosen 9; then
        printf "  Admin username [%s]: " "${cur_admin_user}"; read -r admin_user
        admin_user="${admin_user:-${cur_admin_user}}"
    fi
    if _field_is_chosen 11; then
        printf "  Frontend URL [%s]: " "${cur_frontend_url}"; read -r frontend_url
        frontend_url="${frontend_url:-${cur_frontend_url}}"
    fi

    local admin_password="${cur_admin_password}" git_token="${cur_git_token}"
    if _field_is_chosen 10; then
        printf "  New admin password: "; read -rs admin_password; printf '\n'
    fi
    if _field_is_chosen 12; then
        printf "  New git token: "; read -rs git_token; printf '\n'
    fi

    local db_host="${cur_db_host:-127.0.0.1}" db_port="${cur_db_port:-3306}"
    local db_name="${cur_db_name}" db_user="${cur_db_user}" db_password="${cur_db_password}"
    if _field_is_chosen 13; then
        printf "  DB host [%s]: " "${cur_db_host:-127.0.0.1}"; read -r db_host
        db_host="${db_host:-${cur_db_host:-127.0.0.1}}"
    fi
    if _field_is_chosen 14; then
        printf "  DB port [%s]: " "${cur_db_port:-3306}"; read -r db_port
        db_port="${db_port:-${cur_db_port:-3306}}"
    fi
    if _field_is_chosen 15; then
        printf "  DB name [%s]: " "${cur_db_name}"; read -r db_name
        db_name="${db_name:-${cur_db_name}}"
    fi
    if _field_is_chosen 16; then
        printf "  DB user [%s]: " "${cur_db_user}"; read -r db_user
        db_user="${db_user:-${cur_db_user}}"
    fi
    if _field_is_chosen 17; then
        printf "  New DB password: "; read -rs db_password; printf '\n'
    fi

    [[ "${auth_type}" == "ssh_key" ]] && password=""

    # ── Save ──────────────────────────────────────────────────────────────────
    write_server "${new_name}" <<EOF
HOST=${host}
PORT=${port}
USER=${user}
AUTH_TYPE=${auth_type}
PASSWORD=${password}
SSH_KEY=${ssh_key}
PROJECT_DIR=${project_dir}
ADMIN_URL=${admin_url}
ADMIN_USER=${admin_user}
ADMIN_PASSWORD=${admin_password}
FRONTEND_URL=${frontend_url}
GIT_TOKEN=${git_token}
DB_HOST=${db_host}
DB_PORT=${db_port}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
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

    local host port user auth_type password ssh_key project_dir
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    password=$(read_field "${file}" PASSWORD)
    ssh_key=$(read_field "${file}" SSH_KEY)
    project_dir=$(read_field "${file}" PROJECT_DIR)

    local remote_cmd="exec \$SHELL"
    [[ -n "${project_dir}" ]] && remote_cmd="cd ${project_dir} 2>/dev/null || cd; exec \$SHELL"

    printf "\n${DIM}Connecting to${NC} ${CYAN}%s${NC} ${DIM}→ %s@%s:%s${NC}\n\n" \
        "${name}" "${user}" "${host}" "${port}"

    local ssh_opts=(-p "${port}"
                    -o StrictHostKeyChecking=accept-new
                    -o ConnectTimeout=10)

    if [[ "${auth_type}" == "password" ]]; then
        [[ -n "${password}" ]] || die "No password stored for '${name}'. Run: magneto-ssh edit ${name}"
        command -v sshpass &>/dev/null \
            || die "sshpass not installed. Run: sudo apt install sshpass"
        sshpass -p "${password}" \
            ssh "${ssh_opts[@]}" \
            -o PubkeyAuthentication=no \
            -o IdentitiesOnly=yes \
            -tt "${user}@${host}" "${remote_cmd}" \
            || die "Stored password incorrect or authentication failed."
    else
        local expanded_key="${ssh_key/#\~/${HOME}}"
        [[ -f "${expanded_key}" ]] || die "SSH key not found: ${ssh_key}"
        exec ssh "${ssh_opts[@]}" -i "${expanded_key}" -t "${user}@${host}" "${remote_cmd}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_scp() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh scp <name> <remote_path> [local_dest]
       magneto-ssh scp <name> --upload <local_path> <remote_path>"
    server_exists "${name}" || die "Server '${name}' not found. Run: magneto-ssh list"
    shift

    local upload=false
    local src="" dst=""

    if [[ "${1:-}" == "--upload" || "${1:-}" == "-u" ]]; then
        upload=true
        shift
        src="${1:-}"; dst="${2:-}"
        [[ -n "${src}" && -n "${dst}" ]] \
            || die "Usage: magneto-ssh scp <name> --upload <local_path> <remote_path>"
        [[ -f "${src}" || -d "${src}" ]] || die "Local path not found: ${src}"
    else
        src="${1:-}"; dst="${2:-.}"
        [[ -n "${src}" ]] \
            || die "Usage: magneto-ssh scp <name> <remote_path> [local_dest]"
    fi

    local file; file=$(server_file "${name}")
    local host port user auth_type password ssh_key
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    password=$(read_field "${file}" PASSWORD)
    ssh_key=$(read_field "${file}" SSH_KEY)

    local scp_opts=(-P "${port}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
    local pw_only_opts=(-o PubkeyAuthentication=no -o IdentitiesOnly=yes)

    if [[ "${upload}" == true ]]; then
        printf "\n${DIM}Uploading${NC} ${CYAN}%s${NC} ${DIM}→ %s@%s:%s${NC}\n\n" \
            "${src}" "${user}" "${host}" "${dst}"
    else
        printf "\n${DIM}Downloading${NC} ${CYAN}%s:%s${NC} ${DIM}→ %s${NC}\n\n" \
            "${name}" "${src}" "${dst}"
    fi

    if [[ "${auth_type}" == "password" ]]; then
        [[ -n "${password}" ]] || die "No password stored for '${name}'."
        command -v sshpass &>/dev/null \
            || die "sshpass not installed. Run: sudo apt install sshpass"
        if [[ "${upload}" == true ]]; then
            sshpass -p "${password}" scp "${scp_opts[@]}" "${pw_only_opts[@]}" "${src}" "${user}@${host}:${dst}"
        else
            sshpass -p "${password}" scp "${scp_opts[@]}" "${pw_only_opts[@]}" "${user}@${host}:${src}" "${dst}"
        fi
    else
        local expanded_key="${ssh_key/#\~/${HOME}}"
        [[ -f "${expanded_key}" ]] || die "SSH key not found: ${ssh_key}"
        if [[ "${upload}" == true ]]; then
            scp "${scp_opts[@]}" -i "${expanded_key}" "${src}" "${user}@${host}:${dst}"
        else
            scp "${scp_opts[@]}" -i "${expanded_key}" "${user}@${host}:${src}" "${dst}"
        fi
    fi

    ok "Done."
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
        [[ -n "${val}" ]] && printf "  %-16s %s\n" "${secret_labels[$field]}" "${val}"
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
    local filter=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout|-t) timeout="$2"; shift 2 ;;
            *) filter+=("$1"); shift ;;
        esac
    done

    local servers
    if [[ ${#filter[@]} -gt 0 ]]; then
        for name in "${filter[@]}"; do
            server_exists "${name}" || die "Server not found: ${name}"
        done
        servers=("${filter[@]}")
    else
        mapfile -t servers < <(list_server_names)
    fi
    [[ ${#servers[@]} -eq 0 ]] && { warn "No servers configured."; return; }

    printf "\n${BOLD}Checking servers...${NC}\n\n"

    local pad=0
    for name in "${servers[@]}"; do (( ${#name} > pad )) && pad=${#name}; done
    (( pad += 4 ))

    local ok_count=0 fail_count=0

    for name in "${servers[@]}"; do
        local file; file=$(server_file "${name}")
        local host port user auth_type password
        host=$(read_field "${file}" HOST)
        port=$(read_field "${file}" PORT)
        user=$(read_field "${file}" USER)
        auth_type=$(read_field "${file}" AUTH_TYPE)
        password=$(read_field "${file}" PASSWORD)

        local padded; padded=$(printf "%-${pad}s" "${name}")

        if tcp_check "${host}" "${port}" "${timeout}"; then
            if [[ "${auth_type}" == "password" && -n "${password}" ]]; then
                if timeout "${timeout}" sshpass -p "${password}" \
                    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
                    -o PasswordAuthentication=yes -o PubkeyAuthentication=no \
                    -o BatchMode=no "${user}@${host}" -p "${port}" "exit" 2>/dev/null; then
                    printf "  %s ${GREEN}✓${NC}  auth OK\n" "${padded}"
                    (( ++ok_count ))
                else
                    printf "  %s ${YELLOW}⚠${NC}  auth failed (wrong password?)\n" "${padded}"
                    (( ++fail_count ))
                fi
            else
                printf "  %s ${GREEN}✓${NC}  reachable\n" "${padded}"
                (( ++ok_count ))
            fi
        else
            printf "  %s ${RED}✗${NC}  unreachable\n" "${padded}"
            (( ++fail_count ))
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

    local host port user auth_type project_dir
    host=$(read_field "${file}" HOST)
    port=$(read_field "${file}" PORT)
    user=$(read_field "${file}" USER)
    auth_type=$(read_field "${file}" AUTH_TYPE)
    project_dir=$(read_field "${file}" PROJECT_DIR)

    local uri
    if [[ "${auth_type}" == "password" ]]; then
        local raw_pass
        raw_pass=$(read_field "${file}" PASSWORD)
        [[ -n "${raw_pass}" ]] || die "No password stored for '${name}'."
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

# ─────────────────────────────────────────────────────────────────────────────

cmd_tunnel() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh tunnel <name>"
    local file="${SERVERS_DIR}/${name}"
    [[ -f "${file}" ]] || die "Server not found: ${name}"

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

    local existing_pid
    existing_pid=$(lsof -ti "tcp:${tunnel_local_port}" 2>/dev/null || true)
    if [[ -n "${existing_pid}" ]]; then
        kill "${existing_pid}" 2>/dev/null || true
        warn "Killed existing tunnel on port ${tunnel_local_port}."
    fi

    ok "Opening SSH tunnel: localhost:${tunnel_local_port} → ${db_host}:${db_port} via ${host}"

    if [[ "${auth_type}" == "password" ]]; then
        local raw_pass
        raw_pass=$(read_field "${file}" PASSWORD)
        [[ -n "${raw_pass}" ]] || die "No password stored for '${name}'."
        export SSHPASS="${raw_pass}"
        sshpass -e ssh -f -N \
            -o StrictHostKeyChecking=accept-new \
            -o ExitOnForwardFailure=yes \
            -o PubkeyAuthentication=no \
            -o IdentitiesOnly=yes \
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

# ─────────────────────────────────────────────────────────────────────────────

cmd_dbeaver() {
    local name="${1:-}"
    [[ -n "${name}" ]] || die "Usage: magneto-ssh dbeaver <name>"
    local file="${SERVERS_DIR}/${name}"
    [[ -f "${file}" ]] || die "Server not found: ${name}"

    if ! command -v dbeaver &>/dev/null && ! command -v dbeaver-ce &>/dev/null; then
        die "DBeaver not found. Install it from https://dbeaver.io"
    fi

    cmd_tunnel "${name}"

    local tunnel_local_port db_name db_user db_password
    tunnel_local_port=$(read_field "${file}" TUNNEL_LOCAL_PORT)
    tunnel_local_port="${tunnel_local_port:-13306}"
    db_name=$(read_field "${file}" DB_NAME)
    db_user=$(read_field "${file}" DB_USER)
    db_password=$(read_field "${file}" DB_PASSWORD)

    local con_str="driver=mysql8|host=127.0.0.1|port=${tunnel_local_port}"
    [[ -n "${db_name}" ]]     && con_str="${con_str}|database=${db_name}"
    [[ -n "${db_user}" ]]     && con_str="${con_str}|user=${db_user}"
    [[ -n "${db_password}" ]] && con_str="${con_str}|password=${db_password}"
    con_str="${con_str}|name=${name}|save=true|connect=true"

    ok "Launching DBeaver → ${name} (127.0.0.1:${tunnel_local_port})"
    local dbeaver_bin
    dbeaver_bin=$(command -v dbeaver 2>/dev/null || command -v dbeaver-ce)
    "${dbeaver_bin}" -con "${con_str}" &
    disown
}

# ─────────────────────────────────────────────────────────────────────────────

cmd_import() {
    local xml_file="${1:-}"
    [[ -n "${xml_file}" ]] || die "Usage: magneto-ssh import <filezilla_export.xml>"
    [[ -f "${xml_file}" ]] || die "File not found: ${xml_file}"
    command -v python3 &>/dev/null || die "python3 is required for XML import."

    printf "\n${BOLD}Parsing FileZilla XML:${NC} %s\n\n" "${xml_file}"

    # Parse with python3 stdlib — outputs SOH-delimited lines:
    # slug \x01 host \x01 port \x01 user \x01 auth_type \x01 raw_pw \x01 keyfile \x01 project_dir \x01 orig_name
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

    # ── Count servers ─────────────────────────────────────────────────────────
    local total=0
    while IFS=$'\x01' read -r sl host port user auth pw kf rd name; do
        (( ++total ))
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

    # ── Import servers ────────────────────────────────────────────────────────
    printf '\n'
    local imported=0 skipped=0

    while IFS=$'\x01' read -r sl host port user auth pw kf rd name; do
        if server_exists "${sl}" && [[ "${overwrite_all}" == false ]]; then
            printf "  ${YELLOW}!${NC} %-32s already exists — skipped\n" "${sl}"
            (( ++skipped )); continue
        fi

        printf 'HOST=%s\nPORT=%s\nUSER=%s\nAUTH_TYPE=%s\nPASSWORD=%s\nSSH_KEY=%s\nPROJECT_DIR=%s\nADMIN_URL=\nADMIN_USER=\nADMIN_PASSWORD=\nFRONTEND_URL=\nGIT_TOKEN=\nDB_HOST=\nDB_PORT=\nDB_NAME=\nDB_USER=\nDB_PASSWORD=\nTUNNEL_LOCAL_PORT=\n' \
            "${host}" "${port}" "${user}" "${auth}" \
            "${pw}" "${kf}" "${rd}" \
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
  magneto-ssh <name>               Connect directly to a server

${BOLD}Commands:${NC}
  ${CYAN}add${NC}    <name>            Add a server interactively
  ${CYAN}edit${NC}   <name>            Edit an existing server config
  ${CYAN}ssh${NC}    <name>            Connect to a server
  ${CYAN}scp${NC}    <name> <remote> [local]   Download file from server
  ${CYAN}scp${NC}    <name> --upload <local> <remote>  Upload file to server
  ${CYAN}list${NC}                     List all configured servers
  ${CYAN}info${NC}   <name>            Show server details
  ${CYAN}remove${NC} <name>            Delete a server config
  ${CYAN}import${NC}   <file.xml>        Import servers from FileZilla XML export
  ${CYAN}validate${NC} [--timeout N]   Test connectivity for all servers
  ${CYAN}filezilla${NC} <name>         Open server in FileZilla (SFTP)
  ${CYAN}tunnel${NC}   <name>          Create SSH tunnel to remote DB (localhost:TUNNEL_LOCAL_PORT)
  ${CYAN}dbeaver${NC}  <name>          Open tunnel + launch DBeaver with DB connection
  ${CYAN}version${NC}                  Print version and check for updates
  ${CYAN}update${NC}                   Update magneto-ssh to latest version

${BOLD}Tab completion:${NC}
  magneto-ssh install-completion   Add bash tab completion to ~/.bashrc

${BOLD}Examples:${NC}
  magneto-ssh add petzone_stage
  magneto-ssh petzone_stage
  magneto-ssh edit petzone_stage
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
    local cmds="add edit ssh scp download list info remove import validate filezilla tunnel dbeaver install-completion version update help"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        # Complete both commands and server names
        local servers=""
        [[ -d "${HOME}/.magneto-ssh/servers" ]] \
            && servers=$(ls "${HOME}/.magneto-ssh/servers" 2>/dev/null | tr '\n' ' ')
        COMPREPLY=($(compgen -W "${cmds} ${servers}" -- "${cur}"))
        compopt +o default 2>/dev/null
        return 0
    fi

    case "${prev}" in
        ssh|scp|download|info|remove|add|edit|update|filezilla|fz|tunnel|dbeaver|db)
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
# Version / update check
# =============================================================================

_fetch_latest_version() {
    local fetch_cmd=""
    if command -v curl &>/dev/null; then
        fetch_cmd="curl -fsSL --max-time 5"
    elif command -v wget &>/dev/null; then
        fetch_cmd="wget -qO- --timeout=5"
    else
        return 1
    fi
    ${fetch_cmd} "https://raw.githubusercontent.com/JainamDeveloper/magneto-ssh/main/magneto-ssh.sh" 2>/dev/null \
        | grep '^VERSION=' | head -1 | cut -d'"' -f2
}

check_for_update() {
    # Refresh cache at most once per day
    local now
    now=$(date +%s)
    local last_check=0
    local cached_version=""
    if [[ -f "${UPDATE_CACHE}" ]]; then
        last_check=$(grep '^checked=' "${UPDATE_CACHE}" 2>/dev/null | cut -d= -f2 || echo 0)
        cached_version=$(grep '^latest=' "${UPDATE_CACHE}" 2>/dev/null | cut -d= -f2 || echo "")
    fi
    if (( now - last_check > 86400 )); then
        local fetched
        fetched=$(_fetch_latest_version 2>/dev/null) || fetched=""
        if [[ -n "${fetched}" ]]; then
            printf "checked=%s\nlatest=%s\n" "${now}" "${fetched}" > "${UPDATE_CACHE}" 2>/dev/null || true
            cached_version="${fetched}"
        fi
    fi
    printf "%s" "${cached_version}"
}

show_update_notice() {
    [[ -f "${UPDATE_CACHE}" ]] || return 0
    local latest
    latest=$(grep '^latest=' "${UPDATE_CACHE}" 2>/dev/null | cut -d= -f2 || echo "") || true
    [[ -n "${latest}" ]] || return 0
    # Only notify when remote is strictly newer than local
    local newer
    newer=$(printf "%s\n%s\n" "${VERSION}" "${latest}" | sort -V | tail -1)
    [[ "${newer}" == "${latest}" && "${latest}" != "${VERSION}" ]] || return 0
    printf "\n${YELLOW}Update available: v%s → v%s${NC}  Run: ${CYAN}magneto-ssh update${NC}\n" \
        "${VERSION}" "${latest}"
}

cmd_upgrade() {
    local latest
    latest=$(check_for_update)
    if [[ -n "${latest}" && "${latest}" == "${VERSION}" ]]; then
        ok "Already on latest version (v${VERSION})."
        return 0
    fi
    printf "Upgrading magneto-ssh"
    [[ -n "${latest}" ]] && printf " v%s → v%s" "${VERSION}" "${latest}"
    printf "...\n"
    local install_url="https://raw.githubusercontent.com/JainamDeveloper/magneto-ssh/main/install.sh"
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 30 "${install_url}" | bash
    elif command -v wget &>/dev/null; then
        wget -qO- --timeout=30 "${install_url}" | bash
    else
        die "curl or wget required to upgrade."
    fi
    # Bust cache so next run reflects new version
    rm -f "${UPDATE_CACHE}" 2>/dev/null || true
}

cmd_version() {
    printf "magneto-ssh v%s\n" "${VERSION}"
    local latest
    latest=$(_fetch_latest_version 2>/dev/null) || latest=""
    if [[ -z "${latest}" ]]; then
        printf "${DIM}(could not check for updates)${NC}\n"
        return 0
    fi
    # Bust cache with fresh result
    printf "checked=%s\nlatest=%s\n" "$(date +%s)" "${latest}" > "${UPDATE_CACHE}" 2>/dev/null || true
    local newer
    newer=$(printf "%s\n%s\n" "${VERSION}" "${latest}" | sort -V | tail -1)
    if [[ "${latest}" == "${VERSION}" ]]; then
        printf "${GREEN}You are on the latest version.${NC}\n"
    elif [[ "${newer}" == "${latest}" ]]; then
        printf "${YELLOW}Update available: v%s → v%s${NC}  Run: ${CYAN}magneto-ssh update${NC}\n" \
            "${VERSION}" "${latest}"
    else
        printf "${GREEN}You are running a newer version than GitHub (v%s > v%s).${NC}\n" \
            "${VERSION}" "${latest}"
    fi
}

# =============================================================================
# Main dispatcher
# =============================================================================

main() {
    local cmd="${1:-help}"
    shift || true

    case "${cmd}" in
        add)                    cmd_add "$@" ;;
        edit)                   cmd_update "$@" ;;
        ssh)                    cmd_ssh "$@" ;;
        scp|download)           cmd_scp "$@" ;;
        list)                   cmd_list ;;
        info)                   cmd_info "$@" ;;
        remove|rm|delete)       cmd_remove "$@" ;;
        import)                 cmd_import "$@" ;;
        filezilla|fz)           cmd_filezilla "$@" ;;
        tunnel)                 cmd_tunnel "$@" ;;
        dbeaver|db)             cmd_dbeaver "$@" ;;
        validate|check)         cmd_validate "$@" ;;
        version|--version|-v)   cmd_version ;;
        upgrade|update|self-update) cmd_upgrade ;;
        install-completion)     cmd_install_completion ;;
        help|--help|-h)         cmd_help ;;
        *)
            # Direct connect: magneto-ssh <server-name>
            if server_exists "${cmd}"; then
                cmd_ssh "${cmd}" "$@"
            else
                err "Unknown command or server: ${cmd}"; cmd_help; exit 1
            fi
            ;;
    esac

    case "${cmd}" in
        version|upgrade|update|self-update|help|--help|-h|--version|-v) : ;;
        *) check_for_update > /dev/null 2>&1 & show_update_notice ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
