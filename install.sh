#!/usr/bin/env bash
# Pokémon Modern MMO — your own game server on Linux (Ubuntu 22.04 / 24.04, x86-64). Website:
#   https://pokemon-modern-mmo.tanersaydam.net/
#
# One command (as root or with sudo):
#   curl -fsSL https://raw.githubusercontent.com/PokemonModernMMO/server-releases/main/install.sh | sudo bash
#
# It asks for your admin account and Max players, installs the server host into /opt/pokemon-server, runs it as the
# systemd service "pokemon-server" (starts with the machine; installs and updates the server by itself when a new
# version is published), opens the ports (UDP 7777 game, TCP 7780 login), waits until the server is up, makes your
# admin account and prints the address your friends type into the launcher (Settings > untick "Default server").
#
# Run it again any time: it keeps your accounts and saves (Data) and only refreshes the service.
# Later changes: /opt/pokemon-server/server.conf (MAX_PLAYERS), then:  sudo systemctl restart pokemon-server
#
# Source: Setup/ServerMachine/install.sh in the game's repository (LINUX_SETUP.md); upload it to server-releases after
# a change. Test switches: NO_SERVICE=1 (no systemd: the host runs in the background, e.g. a container),
# HOST_FILE=<path> (use this host program instead of the published one).

set -euo pipefail

REPO="PokemonModernMMO/server-releases"
DIR="/opt/pokemon-server"
SERVICE="pokemon-server"
RUN_USER="pokemon"
GAME_PORT=7777
LOGIN_PORT=7780

say()  { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run it as root: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sudo bash"
[ "$(uname -m)" = "x86_64" ] || fail "The server runs on x86-64 (amd64) machines only."
if [ "${NO_SERVICE:-0}" != "1" ] && ! command -v systemctl >/dev/null 2>&1; then
  fail "systemd was not found. This script is for Ubuntu 22.04 / 24.04."
fi

# The answers come from the terminal even when the script itself arrives through a pipe (curl ... | bash).
if [ -t 0 ]; then TTY=/dev/stdin; elif [ -r /dev/tty ]; then TTY=/dev/tty; else TTY=""; fi
ask() { # ask <prompt> <variable> [silent]
  local answer=""
  if [ -n "${!2:-}" ]; then return; fi            # already given in the environment (ADMIN_NAME=... etc.)
  [ -n "$TTY" ] || fail "No terminal to ask in. Give ADMIN_NAME, ADMIN_PASSWORD and MAX_PLAYERS in the environment."
  if [ "${3:-}" = "silent" ]; then
    read -r -s -p "$1" answer < "$TTY"; echo
  else
    read -r -p "$1" answer < "$TTY"
  fi
  printf -v "$2" '%s' "$answer"
}

echo
echo "  Pokémon Modern MMO — create your own server"
echo "  ------------------------------------------"
echo
while :; do
  ask "Admin account name (3-16 letters, digits, _): " ADMIN_NAME
  [[ "$ADMIN_NAME" =~ ^[A-Za-z0-9_]{3,16}$ ]] && break
  echo "  The name must be 3-16 letters, digits or _."; ADMIN_NAME=""
done
while :; do
  ask "Admin password (at least 6 characters): " ADMIN_PASSWORD silent
  [ "${#ADMIN_PASSWORD}" -ge 6 ] && break
  echo "  The password must be at least 6 characters."; ADMIN_PASSWORD=""
done
while :; do
  ask "Max players at once [4]: " MAX_PLAYERS
  MAX_PLAYERS="${MAX_PLAYERS:-4}"
  [[ "$MAX_PLAYERS" =~ ^[0-9]+$ ]] && [ "$MAX_PLAYERS" -ge 1 ] && [ "$MAX_PLAYERS" -le 32 ] && break
  echo "  Max players must be 1-32."; MAX_PLAYERS=""
done
echo

# ----- what it needs -----
say "Checking the tools it needs..."
missing=""
for tool in curl python3 sha256sum; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
if [ -n "$missing" ]; then
  command -v apt-get >/dev/null 2>&1 || fail "Please install:$missing"
  apt-get update -qq && apt-get install -y -qq curl ca-certificates python3 coreutils >/dev/null
fi
memory_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576 + 0.5}' /proc/meminfo)
if [ "${memory_gb:-0}" -lt 8 ]; then
  echo "  Note: this machine has ${memory_gb} GB memory; 8 GB or more is recommended (the server can run out)."
fi

# ----- user and folder -----
if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DIR" --shell /usr/sbin/nologin "$RUN_USER"
fi
mkdir -p "$DIR/Data"

# ----- the server host program -----
if [ -n "${HOST_FILE:-}" ]; then
  say "Using the host program $HOST_FILE"
  install -m 755 "$HOST_FILE" "$DIR/PokemonServerHost"
else
  say "Downloading the server host program..."
  latest=$(curl -fsSI "https://github.com/$REPO/releases/latest" | tr -d '\r' | awk -F'/tag/' 'tolower($1) ~ /^location:/ {print $2}')
  [ -n "$latest" ] || fail "No published server version was found."
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://github.com/$REPO/releases/download/$latest/manifest-linux.json" -o "$tmp/manifest.json" \
    || fail "Version $latest has no Linux server."
  read -r asset sha <<<"$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); l=m["launcher"]; p=l["parts"]; assert len(p)==1; print(p[0]["asset"], l["sha256"])' "$tmp/manifest.json")"
  curl -fsSL -H "Accept: application/octet-stream" "https://api.github.com/repos/$REPO/releases/assets/$asset" -o "$tmp/host"
  echo "$sha  $tmp/host" | sha256sum -c --status || fail "The host program did not download correctly. Run the script again."
  install -m 755 "$tmp/host" "$DIR/PokemonServerHost"
fi

# ----- settings and start script -----
if [ -f "$DIR/server.conf" ]; then
  sed -i "s/^MAX_PLAYERS=.*/MAX_PLAYERS=$MAX_PLAYERS/" "$DIR/server.conf"
else
  cat > "$DIR/server.conf" <<EOF
# Pokémon Modern MMO server settings. After a change:  sudo systemctl restart $SERVICE
# How many players at once.
MAX_PLAYERS=$MAX_PLAYERS
EOF
fi
cat > "$DIR/StartServer.sh" <<'EOF'
#!/bin/sh
# Runs the server host (systemd starts this; by hand Ctrl+C saves everyone and stops). Settings: server.conf.
DIR="$(dirname "$(readlink -f "$0")")"
cd "$DIR" || exit 1
MAX_PLAYERS=4
[ -f "$DIR/server.conf" ] && . "$DIR/server.conf"
exec "$DIR/PokemonServerHost" --dir "$DIR" --warn-seconds 120 -- -PokemonServerData="$DIR/Data" \
  "-ini:Game:[/Script/PokemonOnline.PokemonNetSettings]:MaxPlayers=$MAX_PLAYERS"
EOF
chmod 755 "$DIR/StartServer.sh"
chown -R "$RUN_USER:$RUN_USER" "$DIR"

# ----- ports -----
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  say "Opening the ports in ufw (UDP $GAME_PORT, TCP $LOGIN_PORT)..."
  ufw allow "$GAME_PORT/udp" >/dev/null
  ufw allow "$LOGIN_PORT/tcp" >/dev/null
fi

# ----- service -----
if [ "${NO_SERVICE:-0}" = "1" ]; then
  say "Starting the server host in the background (no service)..."
  pkill -f "$DIR/PokemonServerHost" 2>/dev/null || true
  su -s /bin/sh "$RUN_USER" -c "cd '$DIR' && nohup '$DIR/StartServer.sh' > '$DIR/host.log' 2>&1 &"
else
  say "Installing the $SERVICE service..."
  cat > "/etc/systemd/system/$SERVICE.service" <<EOF
# Pokémon Modern MMO server (install.sh). Stop saves everyone first. Logs: journalctl -u $SERVICE -f
[Unit]
Description=Pokémon Modern MMO server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$DIR
ExecStart=$DIR/StartServer.sh
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=120
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1
  systemctl restart "$SERVICE"
fi

# ----- wait until it is up (the first time it downloads about 1 GB) -----
say "Installing and starting the game server (the first time it downloads about 1 GB)..."
up=""
for _ in $(seq 1 360); do
  if curl -fs -m 3 -X POST -H "Content-Type: application/json" -d '{}' "http://127.0.0.1:$LOGIN_PORT/api/status" >/dev/null 2>&1; then
    up=1; break
  fi
  size=$(du -sm "$DIR/Server" 2>/dev/null | cut -f1 || echo 0)
  printf '\r    %s MB so far...   ' "${size:-0}"
  sleep 5
done
echo
[ -n "$up" ] || fail "The server did not come up in 30 minutes. See: journalctl -u $SERVICE -n 100"

# ----- admin account -----
say "Creating the admin account $ADMIN_NAME..."
for _ in $(seq 1 30); do [ -s "$DIR/Data/AdminKey.txt" ] && break; sleep 1; done
body=$(KEY="$(cat "$DIR/Data/AdminKey.txt")" NAME="$ADMIN_NAME" PASS="$ADMIN_PASSWORD" python3 -c \
  'import json,os; print(json.dumps({"key":os.environ["KEY"].strip(),"email":os.environ["NAME"]+"@admin.local","username":os.environ["NAME"],"password":os.environ["PASS"],"admin":True}))')
answer=$(curl -fs -m 10 -X POST -H "Content-Type: application/json" -d "$body" "http://127.0.0.1:$LOGIN_PORT/api/admin/account" || true)
if echo "$answer" | grep -q '"ok":true'; then
  echo "    Done."
else
  echo "    The server refused it: ${answer:-no answer}. Run the script again to retry."
fi

# ----- the address for friends -----
address=$(curl -fs -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo
echo "  Your server is running."
echo
echo "  Address for your friends:   $address"
echo "  They open the launcher > Settings (gear) > untick \"Use the default server\" > type the address > Save."
echo
echo "  Max players:     edit $DIR/server.conf, then  sudo systemctl restart $SERVICE"
echo "  Stop / start:    sudo systemctl stop $SERVICE   /   sudo systemctl start $SERVICE"
echo "  Logs:            journalctl -u $SERVICE -f"
echo "  It updates itself when a new version is published. Accounts and saves: $DIR/Data"
echo "  If your provider has its own firewall, allow UDP $GAME_PORT and TCP $LOGIN_PORT there too."
echo "  More: https://pokemon-modern-mmo.tanersaydam.net/create-server"
echo
