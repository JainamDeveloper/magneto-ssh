#!/usr/bin/env bash
# magneto-ssh installer
# Usage: curl -fsSL https://raw.githubusercontent.com/JainamDeveloper/magneto-ssh/main/install.sh | bash

set -euo pipefail

REPO="JainamDeveloper/magneto-ssh"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/main/magneto-ssh.sh"
INSTALL_DIR="${HOME}/.local/bin"
COMPLETION_DIR="${HOME}/.bash_completion.d"
INSTALL_PATH="${INSTALL_DIR}/magneto-ssh"
BASHRC="${HOME}/.bashrc"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { printf "${GREEN}✓${NC} %s\n" "$*"; }
info() { printf "${CYAN}→${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}!${NC} %s\n" "$*"; }

echo ""
printf "${BOLD}magneto-ssh installer${NC}\n"
echo "────────────────────────────────────"

# ── Check dependencies ────────────────────────────────────────────────────────
info "Checking dependencies..."

missing=()
command -v ssh     &>/dev/null || missing+=("ssh")
command -v sshpass &>/dev/null || missing+=("sshpass")

if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing: ${missing[*]}"
    printf "  Install with: sudo apt install %s\n" "${missing[*]}"
    echo ""
fi

# ── Download script ───────────────────────────────────────────────────────────
info "Downloading magneto-ssh..."

mkdir -p "${INSTALL_DIR}"

if command -v curl &>/dev/null; then
    curl -fsSL "${SCRIPT_URL}" -o "${INSTALL_PATH}"
elif command -v wget &>/dev/null; then
    wget -qO "${INSTALL_PATH}" "${SCRIPT_URL}"
else
    printf "Error: curl or wget is required.\n" >&2
    exit 1
fi

chmod +x "${INSTALL_PATH}"
ok "Installed to ${INSTALL_PATH}"

# ── Ensure ~/.local/bin is in PATH ────────────────────────────────────────────
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
    info "Adding ${INSTALL_DIR} to PATH in ${BASHRC}..."
    printf '\n# Added by magneto-ssh installer\nexport PATH="%s:$PATH"\n' "${INSTALL_DIR}" >> "${BASHRC}"
    export PATH="${INSTALL_DIR}:${PATH}"
    ok "PATH updated"
fi

# ── Install tab completion ─────────────────────────────────────────────────────
info "Installing tab completion..."

mkdir -p "${COMPLETION_DIR}"

cat > "${COMPLETION_DIR}/magneto-ssh" <<'COMPLETION'
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

# Source it in ~/.bashrc if not already
SOURCE_LINE='[[ -f "${HOME}/.bash_completion.d/magneto-ssh" ]] && source "${HOME}/.bash_completion.d/magneto-ssh"'
if ! grep -q '.bash_completion.d/magneto-ssh' "${BASHRC}" 2>/dev/null; then
    printf '\n# magneto-ssh completion\n%s\n' "${SOURCE_LINE}" >> "${BASHRC}"
fi

ok "Tab completion installed"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
printf "${BOLD}Done!${NC} Run the following to activate in your current shell:\n\n"
printf "  ${CYAN}source ~/.bashrc${NC}\n\n"
printf "Then get started:\n\n"
printf "  ${CYAN}magneto-ssh add myserver${NC} # Add your first server\n"
printf "  ${CYAN}magneto-ssh myserver${NC}     # Connect directly\n"
echo ""
