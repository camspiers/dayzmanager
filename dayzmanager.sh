#!/usr/bin/env bash

# Exit immediately on error
set -euo pipefail

# ---------------------------
# Prints the usage then exits
# ---------------------------
usage() {
  cat <<EOF

Usage: dayzmanager.sh [-c config.json] <command>

Options:

  -c config.json   Path to config file (default: config.json)
  -v               Enable verbose output
  -h               Output this message

Command (required):

  setup            Set up the server
  backup           Back up files
  login            Authenticate with remote service
  systemd          Generate systemd unit file
  update           Update server and mods
  start            Start the server

EOF
  exit 1
}

# Ensure that the following commands exist
for cmd in jq steamcmd realpath find tar rsync; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command '$cmd' not found in PATH."
    exit 1
  fi
done

# Obtain a full path to the current dayzmanager.sh file being executed
DAYZ_MANAGER_FULL_PATH=$(realpath "$0")

VERBOSE=1
CONFIG_FILE_PATH="config.json"

while getopts "c:vh" opt; do
  case $opt in
	c) CONFIG_FILE_PATH="$OPTARG" ;;
	v) VERBOSE=0;;
	h) usage;;
	\?) echo "Invalid option: -$OPTARG" ;;
  esac
done

# Ensure config file exists
if [ ! -f "$CONFIG_FILE_PATH" ]; then
  echo "$CONFIG_FILE_PATH doesn't exist"
  usage
  exit 1
fi

# Turn config into full path
CONFIG_FILE_PATH=$(realpath "$CONFIG_FILE_PATH")

# Parse config file to error early and store contents for later usage
CONFIG=$(jq -c '.' "$CONFIG_FILE_PATH")

# Remove those arguments we parsed
shift $((OPTIND - 1))

# Command (required)
COMMAND="${1:-}"

# List of valid commands
VALID_COMMANDS=("login" "setup" "update" "start" "backup" "systemd")

if [[ -z "$COMMAND" ]]; then
  echo "No command provided."
  usage
fi

if [[ ! " ${VALID_COMMANDS[*]} " =~ " $COMMAND " ]]; then
  echo "Invalid command provided: $COMMAND"
  usage
fi


# ---------------------------------------------
# Query the config with jq and output raw value
# ---------------------------------------------
query() {
  echo "${2:-$CONFIG}" | jq -r "$1"
}

# ---------------------------------------------
# Query the config with jq and output values
# compactly such that they can be read linewise
# ---------------------------------------------
query_c() {
  echo "${2:-$CONFIG}" | jq -c "$1"
}

# ---------------------------------------------
# Expand leading ~ in path with $HOME
# ---------------------------------------------
expand_path() {
  local input="$1"
  echo "${input/#\~/$HOME}"
}

# ----------------------
# Provide confirm prompt
# ----------------------
confirm() {
  read -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

INSTALL_DIR=$(expand_path "$(query '.install_directory')")
STEAM_USERNAME=$(query '.steam_username')
SERVER_CONFIG=$(query '.server_config // ""')
SERVER_PID=""
SERVER_PID_FILE="$INSTALL_DIR/dayzmanager-server.pid"
APP_ID=223350
WORKSHOP_ITEM_APP_ID=221100

# -----------------------------------------
# Install or update the DayZ server itself
# -----------------------------------------
setup_server() {
  steamcmd \
    +force_install_dir "$INSTALL_DIR" \
    +login "$STEAM_USERNAME" \
    +app_update $APP_ID \
    +quit > /dev/null
}

# -----------------------------------------
# Download mods and symlink them into place
# -----------------------------------------
setup_mods() {
  echo "Removing any existing symlinked keys"

  find "$INSTALL_DIR/keys" -type l -delete

  query_c '.mods[]' | while IFS= read -r mod; do
    name=$(query '.name' "$mod")
    app_id=$(query ".app_id // $WORKSHOP_ITEM_APP_ID" "$mod")
    item_id=$(query '.item_id' "$mod")
    src="$INSTALL_DIR/steamapps/workshop/content/$app_id/$item_id"
    dest="$INSTALL_DIR/$name"

    if [ -e "$src" ]; then
      echo "Updating mod $name (Item ID: $app_id:$item_id)"
    else
      echo "Installing mod $name (Item ID: $app_id:$item_id)"
    fi

    # Download or update mod
    steamcmd \
      +force_install_dir "$INSTALL_DIR" \
      +login "$STEAM_USERNAME" \
      +workshop_download_item "$app_id" "$item_id" \
      +quit > /dev/null

    if [ -e "$dest" ]; then
      echo "Removing any existing symlink"
      rm "$dest"
    fi

    echo "  Symlinking mod $name to $dest"
    ln -s "$src" "$dest"

    echo "  Symlinking mod $name keys to $INSTALL_DIR/keys/"

    # Handle both Keys and keys directories
    ln -sf "$src"/[Kk]eys/*.bikey "$INSTALL_DIR/keys/"
  done
}

# -----------------------------------------
# Clone or update any git-based resources
# -----------------------------------------
setup_resources() {
  query_c '.resources[] | select(.type == "git")' | while IFS= read -r resource; do
    # Ensure git command is available
    if ! command -v git >/dev/null 2>&1; then
      echo "Required command '$cmd' not found in PATH."
      exit 1
    fi

    name=$(query '.name' "$resource")
    url=$(query '.url' "$resource")
    target="$INSTALL_DIR/resources/$name"

    if [ -d "$target/.git" ]; then
      echo "Git resource $name already cloned, updating."
      git -C "$target" pull --ff-only
    else
      if [ -e "$target" ]; then
        echo "Resource $target already exists but is not a git repo, please manually remove it"
        exit 1
      fi

      echo "Cloning $name from $url..."
      git clone "$url" "$target"
    fi
  done
}

systemd_timespan_to_minutes() {
  microseconds=$(systemd-analyze timespan "$1" 2>/dev/null | awk '/μs:/ {print $2}')

  if [[ -z "$microseconds" || ! "$microseconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid time format"
    exit 1
  fi

  echo $(($microseconds / 60000000 ))
}

setup_mission_xml() {
  SYSTEMD_UNIT_RESTART_AFTER=$(query '.systemd.restart_after // "6h"')
  mission="$1"
  mission_path=$(query '.path' "$mission")
  dest="$INSTALL_DIR/mpmissions/$(basename "$INSTALL_DIR/$mission_path")"
}

# ------------------------------------
# Setup mission files by rsyncing them
# ------------------------------------
setup_missions() {
  # Sometimes the mpmissions directory doesn't exist when DayZServer is installed
  mkdir -p "$INSTALL_DIR/mpmissions"

  query_c '.missions[]' | while IFS= read -r mission; do
    mission_path=$(query '.path' "$mission")

    src="$INSTALL_DIR/$mission_path"
    dest="$INSTALL_DIR/mpmissions/$(basename "$INSTALL_DIR/$mission_path")"
    
    mkdir -p "$dest"

    exclude_flags=("")
    while IFS= read -r exclude; do
      exclude_flags+=("--exclude=$exclude")
    done < <(query '.exclude[]?' "$mission")

    if [ -f "$dest/.dayzmanager.installed" ]; then
      echo "Updating mission $src to $dest"

      # Add to the exclude_flags for updates
      while IFS= read -r exclude; do
        exclude_flags+=("--exclude=$exclude")
      done < <(query '.exclude_update[]?' "$mission")
    else
      echo "Installing mission $src to $dest"
    fi

    rsync \
      --recursive \
      --delete \
      ${exclude_flags[@]} \
      "$src/" \
      "$dest/"

    touch "$dest/.dayzmanager.installed"
  done
}

# -----------------------------------------
# Set up the main server configuration file
# -----------------------------------------
setup_server_config() {
  if [ -n "$SERVER_CONFIG" ]; then
    if [ ! -f "$INSTALL_DIR/$SERVER_CONFIG" ]; then
      echo "Server config $SERVER_CONFIG doesn't exist"
      exit 1
    fi

    if [ -f "$INSTALL_DIR/serverDZ.cfg" ]; then
      echo "Backing up existing serverDZ.cfg"
      mv "$INSTALL_DIR/serverDZ.cfg" "$INSTALL_DIR/serverDZ.cfg.bak"
    fi

    cp "$INSTALL_DIR/$SERVER_CONFIG" "$INSTALL_DIR/serverDZ.cfg"
  else
    echo "No server config specified, skipping..."
  fi
}

# -----------------------------------------
# Optionally install a systemd service unit
# -----------------------------------------
setup_systemd_unit() {
  SYSTEMD_UNIT_NAME=$(query '.systemd.name // "dayz-server"')
  SYSTEMD_UNIT_DESCRIPTION=$(query '.systemd.description // "DayZ Server"')
  SYSTEMD_UNIT_NICENESS=$(query '.systemd.niceness // "-10"')
  SYSTEMD_UNIT_RESTART_AFTER=$(query '.systemd.restart_after // "6h"')
  SYSTEMD_UNIT_PATH="/etc/systemd/system/$SYSTEMD_UNIT_NAME.service"
  USERNAME=$(whoami)
  GROUP=$(id -gn)

  if ! confirm "Would you like to create a systemd service unit?"; then
    echo "Skipping systemd unit creation."
    return 0
  fi

  # Back up existing unit
  if [ -f "$SYSTEMD_UNIT_PATH" ]; then
    timestamp=$(date +%Y%m%d%H%M%S)
    backup_file="${SYSTEMD_UNIT_PATH}.bak.${timestamp}"
    echo "Backing up existing systemd unit to: $backup_file"
    sudo cp "$SYSTEMD_UNIT_PATH" "$backup_file"
  fi

  echo "Generating systemd unit at: $SYSTEMD_UNIT_PATH"
  cat <<EOF | sudo tee "$SYSTEMD_UNIT_PATH" > /dev/null
[Unit]
Description=$SYSTEMD_UNIT_DESCRIPTION
Wants=network-online.target
After=syslog.target network.target nss-lookup.target network-online.target

[Service]
ExecStartPre=$DAYZ_MANAGER_FULL_PATH $CONFIG_FILE_PATH update
ExecStart=$DAYZ_MANAGER_FULL_PATH $CONFIG_FILE_PATH start
LimitNOFILE=100000
User=$USERNAME
Group=$GROUP
Restart=on-failure
RestartSec=5s
RuntimeMaxSec=$SYSTEMD_UNIT_RESTART_AFTER
Nice=$SYSTEMD_UNIT_NICENESS

[Install]
WantedBy=multi-user.target
EOF

  echo "Reloading systemd daemon to detect new or changed service"
  sudo systemctl daemon-reload

  if confirm "Would you like to generate a missions.xml file that reflects your systemd.restart_after setting"; then
    minutes=$(systemd_timespan_to_minutes "$SYSTEMD_UNIT_RESTART_AFTER")
    query_c '.missions[]' | while IFS= read -r mission; do
      mission_path=$(query '.path' "$mission")
      dest="$INSTALL_DIR/mpmissions/$(basename "$INSTALL_DIR/$mission_path")"

      if [ -f "$dest/db/messages.xml" ]; then
        echo "Backing up existing missions.xml file"
        timestamp=$(date +%Y%m%d%H%M%S)
        cp "$dest/db/messages.xml" "$dest/db/messages.xml.bak.${timestamp}"
      fi

      cat <<EOF | tee "$dest/db/missions.xml" > /dev/null
<messages>
    <message>
        <deadline>${minutes}</deadline>
        <countdown>1</countdown>
        <shutdown>1</shutdown>
        <text>#name will shutdown in #tmin minutes.</text>
    </message>
    <message>
        <onconnect>1</onconnect>
        <text>Welcome to #name</text>
    </message>
</messages>
EOF
    done
  fi


  if confirm "Would you like to enable (to run at boot) and immediately start the service?"; then
    sudo systemctl enable --now "$SYSTEMD_UNIT_NAME.service"
    echo "Sevice enabled and started."
  elif confirm "Would you like to enable the service (but not start it)?"; then
    sudo systemctl enable "$SYSTEMD_UNIT_NAME.service"
    echo "Sevice enabled."
  elif confirm "Would you like to start it now?"; then
    sudo systemctl start "$SYSTEMD_UNIT_NAME.service"
    echo "Sevice started."
  else
    echo "Sevice was not enabled or started."
    echo ""
  fi

  echo "You can enable the service by running (this will enable the server to start automatically at boot):"
  echo "sudo systemctl enable ${SYSTEMD_UNIT_NAME}.service"
  echo ""
  echo "You can disaled the service by running (this will disable the server to start automatically at boot):"
  echo "sudo systemctl disable ${SYSTEMD_UNIT_NAME}.service"
  echo ""
  echo "You can start the service by running:"
  echo "sudo systemctl start ${SYSTEMD_UNIT_NAME}.service"
  echo ""
  echo "You can stop the service by running:"
  echo "sudo systemctl stop ${SYSTEMD_UNIT_NAME}.service"
  echo ""
  echo "You can check the status of the service by running:"
  echo "sudo systemctl status ${SYSTEMD_UNIT_NAME}.service"
}

# -----------------------------------------
# Setups up the server for the first time.
# - Ensures user can login
# - Ensures install directory doesn't already exist
# - Downloads DayZServer
# - Downloads mods
# - Downloads resources
# - Sets up missions
# - Copies specified server config
# -----------------------------------------
setup() {
  ensure_login

  echo "Setting up DayZServer in $INSTALL_DIR..."

  if [ -d "$INSTALL_DIR" ]; then
    echo "Directory $INSTALL_DIR already exists."
    echo "Delete it or use 'update' instead of 'setup'."
    exit 1
  fi

  echo "  Creating directory $INSTALL_DIR"

  mkdir -p "$INSTALL_DIR"

  echo "  Changing directory to $INSTALL_DIR"

  cd "$INSTALL_DIR"

  echo "  Downloading DayZServer"

  setup_server

  echo "Setting up mods"

  setup_mods

  echo "Setting up resources"

  setup_resources

  echo "Setting up missions"

  setup_missions

  echo "Setting up server config"

  setup_server_config

  echo "Setup complete"
  echo "You can now optionally install a systemd unit by running:"
  echo "$DAYZ_MANAGER_FULL_PATH $CONFIG_FILE_PATH systemd"
}

# -----------------------------------------
# Updates an existing installation
# - Ensures user can login
# - Updates DayZServer
# - Updates mods
# - Updates resources
# - Updates missions
# -----------------------------------------
update() {
  ensure_login

  backup

  echo "Changing directory to $INSTALL_DIR"

  cd "$INSTALL_DIR"

  echo "Updating DayZ server in $INSTALL_DIR..."

  setup_server

  echo "Updating mods"

  setup_mods

  echo "Updating resources"

  setup_resources

  echo "Updating missions"

  setup_missions

  echo "Update complete"
}

# -------------------------------------
# Waits for the server process to end
# captures the exit code and exits the
# bash process with the same code
# -------------------------------------
server_wait_and_exit() {
  wait "$SERVER_PID"
  exit_code=$?
  echo "Server exited with code $exit_code"
  exit $exit_code
}

# -------------------------------------------
# Forwards the arbitrary signal to the server
# waits for the server process to end
# -------------------------------------------
server_forward_with_exit() {
  echo "dayzmanager.sh caught $1, forwarding to server ($SERVER_PID)"
  kill "-$1" "$SERVER_PID"
  server_wait_and_exit
}

# -----------------------------------------
# Forwards the SIGTERM signal to the server
# -----------------------------------------
server_forward_terminate() {
  server_forward_with_exit "SIGTERM"
}

# ----------------------------------------
# Forwards the SIGINT signal to the server
# ----------------------------------------
server_forward_interupt() {
  server_forward_with_exit "SIGINT"
}

# ----------------------------------------
# Forwards the SIGHUP signal to the server
# ----------------------------------------
server_forward_hangup() {
  echo "dayzmanager.sh caught SIGHUP, forwarding to server ($SERVER_PID)"
  kill -SIGHUP "$SERVER_PID"
}

# ----------------------
# Removes the server PID
# ----------------------
server_remove_pid_file() {
  echo "Removing PID file"
  rm "$SERVER_PID_FILE"
}

# --------------------------------------------
# Starts the server with the appropriate args
# based on the config. Backgrounds the server,
# creates traps and signal forwarding, stores
# PID of server, waits for the server process
# --------------------------------------------
start() {
  echo "Changing directory to $INSTALL_DIR"

  cd "$INSTALL_DIR"

  START_COMMAND_WRAPPER=$(query '.start_command.wrapper // ""')
  PORT=$(query '.start_command.port // 2301')

  start_command_flags=(
  	"-config=serverDZ.cfg"
  	"-port=$PORT"
  	"-BEpath=battleye"
  	"-profiles=profiles"
  	"-nologs"
  	"-freezecheck"
  )

  while IFS= read -r flag; do
    start_command_flags+=("-$flag")
  done < <(query '.start_command.additional_flags[]?')

  mods=""
  while IFS= read -r mod; do
    mod_name=$(query '.name' "$mod")
    mods="${mods}${mod_name};"
  done < <(query_c '.mods[]')

  if [ -n "$mods" ]; then
    start_command_flags+=("-mod=${mods}")
  fi

  echo "Starting server"

  # Start server in background then wait below
  $START_COMMAND_WRAPPER ./DayZServer "${start_command_flags[@]}" &

  SERVER_PID=$!

  echo "Server started with PID $SERVER_PID, saving PID file"
  echo "$SERVER_PID" > "$SERVER_PID_FILE"

  # Setup signal forwarding
  trap server_forward_terminate SIGTERM
  trap server_forward_interupt SIGINT
  trap server_forward_hangup SIGHUP

  # Set up cleanup code after the bash script exits
  trap server_remove_pid_file EXIT

  server_wait_and_exit
}

# --------------------------------------------
# Used for setting up steam cached credentials
# against the steam username in config
# --------------------------------------------
login() {
  echo "Setting up login through steamcmd"

  # We don't suppress the output as we want to prompt for password
  steamcmd \
    +login "$STEAM_USERNAME" \
    +quit

  ensure_login
}

# --------------------------------------------
# Creates backups for the configured missions
# and the profiles directory
# --------------------------------------------
backup() {
  BACKUP_DIRECTORY=$(expand_path "$(query '.backup.directory // ""')")
  BACKUP_PREFIX=$(query '.backup.prefix // ""')
  BACKUP_RETENTION_DAYS=$(query '.backup.retention_days // 5')

  if [ -z "$BACKUP_DIRECTORY" ]; then
    echo "Backups not configured"
    return 0
  fi

  if [ -n "$BACKUP_PREFIX" ]; then
    BACKUP_PREFIX="${BACKUP_PREFIX}_"
  fi

  echo "Backing up server"

  mkdir -p "$BACKUP_DIRECTORY"

  timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

  backup_dirs=(
    "$INSTALL_DIR/profiles"
  )

  while IFS= read -r mission; do
    backup_dirs+=("$INSTALL_DIR/mpmissions/$(basename "$INSTALL_DIR/$mission")")
  done < <(query '.missions[].path')

  for dir in "${backup_dirs[@]}"; do
    dir_name=$(basename "$dir")
    echo "  Creating backup for $dir_name"
    tar -czf "$BACKUP_DIRECTORY/${BACKUP_PREFIX}${dir_name}_${timestamp}.tar.gz" -C "$(dirname "$dir")" "$dir_name"
  done

  echo "  Pruning backups older than $BACKUP_RETENTION_DAYS days"
  find "$BACKUP_DIRECTORY" -type f -name "*.tar.gz" -mtime +$BACKUP_RETENTION_DAYS -delete

  echo "Backup completed"
}

# ----------------------------
# Checks whether the server is
# running using the stored pid
# ----------------------------
is_server_running() {
  if [ -f "$SERVER_PID_FILE" ]; then
    PID=$(<"$SERVER_PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      return 0
    else
      return 1
    fi
  fi

  return 1
}

# --------------------------------------------
# Checks whether the server is running and
# errors if it is running
# --------------------------------------------
ensure_server_isnt_running() {
  echo "Checking server isn't running"

  if is_server_running; then
    echo "Server is running. Please kill and re-run command"
    exit 1
  fi

  echo "Server isn't running"
}

# --------------------------------------------
# Checks whether the the user can login and
# errors if not
# --------------------------------------------
ensure_login() {
  echo "Checking steam login"

  if ! steamcmd \
      +@NoPromptForPassword 1 \
      +login "$STEAM_USERNAME" \
      +quit > /dev/null; then
    echo "Not logged in, please run '$0 --config $CONFIG_FILE_PATH login'"
    exit 1
  fi

  echo "Steam login successful"
}

# Main entry point
case "$COMMAND" in
  login)
    login
    ;;
  setup)
    ensure_server_isnt_running
    setup
    ;;
  update)
    ensure_server_isnt_running
    update
    ;;
  start)
    ensure_server_isnt_running
    start
    ;;
  backup)
    ensure_server_isnt_running
    backup
    ;;
  systemd)
    ensure_server_isnt_running
    setup_systemd_unit
    ;;
esac


