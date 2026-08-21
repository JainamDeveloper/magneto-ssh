# magneto-ssh

SSH connection manager for Magento environments.
Store, connect, and manage multiple project servers with a single short command.
Pure Bash — no Python, no pip, no venv.

---

## Dependencies

| Tool | Purpose | Install |
|------|---------|---------|
| `bash` 4.0+ | Runtime | Pre-installed on Linux/macOS |
| `ssh` | SSH connections and tunnels | Pre-installed |
| `sshpass` | Password-based SSH (non-interactive) | `sudo apt install sshpass` |
| `python3` | FileZilla XML import only | `sudo apt install python3` |
| `filezilla` | `filezilla` command — SFTP file manager | `sudo apt install filezilla` |
| `dbeaver` or `dbeaver-ce` | `dbeaver` command — database GUI | [dbeaver.io](https://dbeaver.io/download/) |
| `lsof` | Tunnel port management | Pre-installed |

Minimum required for core commands (`add`, `ssh`, `list`, etc.): **ssh + sshpass**.

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
magneto-ssh add myproject_stage
```

Interactive prompts collect server details. Passwords are stored plaintext in `~/.magneto-ssh/servers/<name>`.

---

## Commands

### Add a server

```bash
magneto-ssh add myproject_stage
```

Interactive prompts collect:
- Host, port, SSH user, auth type (password or SSH key)
- Optional: project directory, admin URL/user/password, frontend URL, git token
- Optional: DB host, DB port, DB name, DB user, DB password
- Optional: disk usage path used by `housekeeping` (default `~/application/`)

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

Shows all fields including plaintext passwords.

### Update a server

```bash
magneto-ssh edit myproject_stage
```

Select which fields to update. Prompts only for selected fields.

### Remove a server

```bash
magneto-ssh remove myproject_stage
```

### Import from FileZilla XML

```bash
magneto-ssh import ~/Desktop/FileZilla.xml
```

Requires `python3`. Parses FileZilla's site manager XML export and saves each server as a config file.

### Validate connections

```bash
magneto-ssh validate
magneto-ssh validate --timeout 10
```

Tests TCP connectivity and password authentication for password-auth servers.

```
Checking servers...

  myproject_stage         ✓  auth OK
  myproject_production    ✓  reachable
  clienta_dev             ✗  unreachable

! 2/3 reachable, 1 failed.
```

### Open in FileZilla

```bash
magneto-ssh filezilla myproject_stage
# shorthand:
magneto-ssh fz myproject_stage
```

Launches FileZilla directly connected to the server via SFTP.
Requires `filezilla` to be installed.

### Open DB tunnel

```bash
magneto-ssh tunnel myproject_stage
```

Creates an SSH tunnel forwarding `localhost:13306` to `<DB_HOST>:<DB_PORT>` on the remote server.
Prints connection details when the tunnel is up.

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

Opens the SSH tunnel, then launches DBeaver with a pre-filled MySQL connection.
Requires `dbeaver` or `dbeaver-ce` to be installed.

### Housekeeping report

```bash
magneto-ssh housekeeping myproject_stage
# shorthand:
magneto-ssh hk myproject_stage
```

One SSH round-trip, three checks:

1. **exception.log** — reads `<PROJECT_DIR>/var/log/exception.log`, reports size, line count and
   last-modified time, prints the last lines, and downloads a timestamped copy to
   `~/.magneto-ssh/reports/<name>/`.
2. **Indexer status** — runs `php bin/magento indexer:status` (auto-detects the remote PHP binary)
   and flags any indexer that is not Ready.
3. **Disk usage** — runs `df -h` on `DISK_PATH` (default `~/application/`), warning at 80% used and
   erroring at 90%.

Exits with status `1` when any check fails, so it can be used in scripts.

| Option | Description |
|--------|-------------|
| `--tail N` | Lines of `exception.log` to print inline (default 20, `0` disables) |
| `--no-download` | Skip downloading the log file |
| `--output DIR` | Directory for the downloaded log (default `~/.magneto-ssh/reports/<name>`) |
| `--log PATH` | Override the log path |
| `--disk PATH` | Override the `df -h` path for this run |

---

## Tab Completion

Install once, then restart your shell:

```bash
magneto-ssh install-completion
source ~/.bash_completion.d/magneto-ssh
```

Tab-completing server names works for: `ssh`, `scp`, `info`, `edit`, `remove`, `filezilla`, `tunnel`, `dbeaver`, `housekeeping`

```bash
magneto-ssh ssh myp<TAB>
# myproject_stage    myproject_production
```

---

## Config Location

| Path | Permissions | Contents |
|------|-------------|----------|
| `~/.magneto-ssh/` | `700` | Config directory |
| `~/.magneto-ssh/servers/<name>` | `600` | Per-server config (plaintext passwords) |
| `~/.magneto-ssh/keys/` | `700` | Optional SSH key storage |

Per-server config format (KEY=value):

```
HOST=1.2.3.4
PORT=22
USER=deploy
AUTH_TYPE=password
PASSWORD=mypassword
SSH_KEY=
PROJECT_DIR=~/myproject/current
ADMIN_URL=https://stage.myproject.com/admin
ADMIN_USER=admin
ADMIN_PASSWORD=adminpass
FRONTEND_URL=https://stage.myproject.com
GIT_TOKEN=ghp_xxxxx
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=myproject_db
DB_USER=dbuser
DB_PASSWORD=dbpass
DISK_PATH=~/application/
```

---

## Security

⚠️ **Plaintext Storage**: Passwords are stored plaintext in `~/.magneto-ssh/servers/<name>` (mode `600`).
- Server configs are readable only by you (permission `600`).
- Suitable for local development environments.
- Not suitable for multi-user systems or production credentials.

For production use, consider:
- Storing passwords in a secrets manager instead of magneto-ssh.
- Using SSH key authentication only.
- Running in restricted environments where only you have access.

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
| `add <name>` | | Add a server interactively |
| `edit <name>` | `update` | Update an existing server config |
| `ssh <name>` | | Connect via SSH |
| `scp <name>` | `download` | Upload/download files via SCP |
| `list` | | List all servers |
| `info <name>` | | Show server details |
| `remove <name>` | `rm`, `delete` | Delete a server config |
| `import <file.xml>` | | Import from FileZilla XML |
| `validate` | `check` | Test connectivity and auth |
| `filezilla <name>` | `fz` | Open in FileZilla (SFTP) |
| `tunnel <name>` | | Create SSH tunnel to remote DB |
| `dbeaver <name>` | `db` | Open tunnel + launch DBeaver |
| `housekeeping <name>` | `hk` | Indexer status + disk usage + download exception.log |
| `install-completion` | | Install bash tab completion |
| `upgrade` | | Self-upgrade to latest version |
| `version` | `--version` | Print version |
| `help` | `--help` | Show help |
