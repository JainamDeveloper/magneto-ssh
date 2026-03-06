# magneto-ssh

SSH connection manager for Magento environments.
Store, connect, and manage multiple project servers with a single short command.
Pure Bash — no Python, no pip, no venv.

---

## Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| `bash` 4.0+ | Runtime | Pre-installed on Linux/macOS |
| `openssl` | Password encryption (AES-256-CBC) | Pre-installed |
| `ssh` | SSH connections and tunnels | Pre-installed |
| `sshpass` | Password-based SSH (non-interactive) | `sudo apt install sshpass` |
| `python3` | FileZilla XML import only | `sudo apt install python3` |
| `filezilla` | `filezilla` command — SFTP file manager | `sudo apt install filezilla` |
| `dbeaver` or `dbeaver-ce` | `dbeaver` command — database GUI | [dbeaver.io](https://dbeaver.io/download/) |
| `lsof` | Tunnel port management | Pre-installed |

Minimum required for core commands (`init`, `add`, `ssh`, `list`, etc.): **openssl + ssh + sshpass**.

---

## Installation

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/JainamDeveloper/magneto-ssh/main/install.sh | bash
source ~/.bashrc
```

That's it. No git clone needed.

### Manual install

```bash
# 1. Download the script
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/JainamDeveloper/magneto-ssh/main/magneto-ssh.sh \
    -o ~/.local/bin/magneto-ssh
chmod +x ~/.local/bin/magneto-ssh

# 2. Ensure ~/.local/bin is in your PATH
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# 3. Install tab completion
magneto-ssh install-completion
source ~/.bashrc
```

---

## First Run

```bash
magneto-ssh init
```

Sets a master password used to encrypt SSH passwords, admin passwords, DB passwords, and git tokens.
**This password cannot be recovered. Do not forget it.**

---

## Commands

### Add a server

```bash
magneto-ssh add myproject_stage
```

Interactive prompts collect:
- Host, port, SSH user, auth type (password or SSH key)
- Optional: project directory, admin URL/user/password, frontend URL, git token
- Optional: DB host, DB port, DB name, DB user, DB password, tunnel local port

### Connect via SSH

```bash
magneto-ssh ssh myproject_stage
```

Opens an interactive SSH session. If a project directory is configured, the session starts inside it automatically.

### List servers

```bash
magneto-ssh list
```

```
NAME                  HOST              USER      PORT   AUTH      PROJECT DIR
myproject_stage       1.2.3.4           deploy    22     password  ~/myproject/current
myproject_production  1.2.3.5           deploy    22     ssh_key   ~/myproject/current
clienta_dev           10.0.0.50         admin     2222   ssh_key   -
```

### Server details

```bash
magneto-ssh info myproject_stage
```

Shows all fields. Passwords are shown as `[encrypted]` — never plain text.

### Update a server

```bash
magneto-ssh update myproject_stage
```

Prompts for every field with the current value shown in `[ ]`. Press Enter to keep it.
Supports renaming the server. Master password is only asked if a secret field is changed.

### Remove a server

```bash
magneto-ssh remove myproject_stage
```

### Import from FileZilla XML

```bash
magneto-ssh import ~/Desktop/FileZilla.xml
```

Requires `python3`. Parses FileZilla's site manager XML export, decodes stored passwords (base64), re-encrypts them with your master password, and saves each server as a config file.

### Validate connections

```bash
magneto-ssh validate
magneto-ssh validate --timeout 10
```

```
Checking servers...

  myproject_stage         connected
  myproject_production    connected
  clienta_dev             connection timeout

! 2/3 reachable, 1 failed.
```

### Open in FileZilla

```bash
magneto-ssh filezilla myproject_stage
# shorthand:
magneto-ssh fz myproject_stage
```

Decrypts the SSH password and launches FileZilla directly connected to the server via SFTP.
Requires `filezilla` to be installed.

### Open DB tunnel

```bash
magneto-ssh tunnel myproject_stage
```

Creates an SSH tunnel forwarding `localhost:<TUNNEL_LOCAL_PORT>` to `<DB_HOST>:<DB_PORT>` on the remote server.
Default local port: `13306`. Prints connection details when the tunnel is up.

Close the tunnel:
```bash
kill $(lsof -ti tcp:13306)
```

### Open in DBeaver

```bash
magneto-ssh dbeaver myproject_stage
# shorthand:
magneto-ssh db myproject_stage
```

Opens the SSH tunnel (above), then launches DBeaver with a pre-filled MySQL connection.
Requires `dbeaver` or `dbeaver-ce` to be installed.

---

## Tab Completion

Install once, then restart your shell:

```bash
magneto-ssh install-completion
source ~/.bash_completion.d/magneto-ssh
```

Tab-completing server names works for: `ssh`, `info`, `update`, `remove`, `filezilla`, `tunnel`, `dbeaver`

```bash
magneto-ssh ssh myp<TAB>
# myproject_stage    myproject_production
```

---

## Config Location

| Path | Permissions | Contents |
|------|-------------|----------|
| `~/.magneto-ssh/` | `700` | Config directory |
| `~/.magneto-ssh/servers/<name>` | `600` | Per-server config (passwords encrypted) |
| `~/.magneto-ssh/.salt` | `600` | PBKDF2 salt |
| `~/.magneto-ssh/.verify` | `600` | Encrypted verification token |
| `~/.magneto-ssh/keys/` | `700` | Optional SSH key storage |

Per-server config format (KEY=value):

```
HOST=1.2.3.4
PORT=22
USER=deploy
AUTH_TYPE=password
PASSWORD=<encrypted>
SSH_KEY=
PROJECT_DIR=~/myproject/current
ADMIN_URL=https://stage.myproject.com/admin
ADMIN_USER=admin
ADMIN_PASSWORD=<encrypted>
FRONTEND_URL=https://stage.myproject.com
GIT_TOKEN=<encrypted>
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=myproject_db
DB_USER=dbuser
DB_PASSWORD=<encrypted>
TUNNEL_LOCAL_PORT=13306
```

---

## Security Model

- Sensitive fields (`PASSWORD`, `ADMIN_PASSWORD`, `GIT_TOKEN`, `DB_PASSWORD`) are encrypted with AES-256-CBC via OpenSSL.
- The encryption key is derived from your master password via PBKDF2-HMAC-SHA256 with 310,000 iterations and a random 16-byte salt.
- Plain-text passwords are never written to disk.
- The master password is never stored — only an encrypted verification token is kept.

---

## Updating the Script

Re-run the one-liner to get the latest version:

```bash
curl -fsSL https://raw.githubusercontent.com/JainamDeveloper/magneto-ssh/main/install.sh | bash
```

---

## Command Reference

| Command | Shorthand | Description |
|---------|-----------|-------------|
| `init` | | Set master password (run once) |
| `add <name>` | | Add a server interactively |
| `update <name>` | `edit` | Update an existing server config |
| `ssh <name>` | | Connect via SSH |
| `list` | | List all servers |
| `info <name>` | | Show server details |
| `remove <name>` | `rm`, `delete` | Delete a server config |
| `import <file.xml>` | | Import from FileZilla XML |
| `validate` | `check` | Test connectivity for all servers |
| `filezilla <name>` | `fz` | Open in FileZilla (SFTP) |
| `tunnel <name>` | | Create SSH tunnel to remote DB |
| `dbeaver <name>` | `db` | Open tunnel + launch DBeaver |
| `install-completion` | | Install bash tab completion |
| `version` | `--version` | Print version |
| `help` | `--help` | Show help |
