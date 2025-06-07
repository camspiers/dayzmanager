# DayZ Server Manager

A Bash script to manage a DayZ Server (or multiple) supporting setup, updates, backups, mod/resource management, and optional systemd integration.

## Features

- Define reproducable servers from a JSON config file
- Install/update DayZ server via SteamCMD
- Install/update mods from Steam Workshop
- Define resources to be imported from local or remote git repositories
- Define missions to be symlinked into the `mpmissions` folder
- Generate a systemd unit for server management
- Backup mission and profile data with retention policies
- Define a restart policy

## Requirements

Ensure the following are available in your `PATH`:

- `jq`
- `steamcmd`
- `realpath`
- `find`
- `tar`
- `rsync`
- `git` (optional: required for git-based resources)

## Usage

```bash
dayzmanager.sh myconfig.json {login|setup|update|start|backup|systemd}
```

Given a valid JSON config, use the following steps to setup your DayZ Server.

```bash
# Run login to ensure that the specified steam user's (from your JSON config) credentials are cached
dayzmanager.sh myconfig.json login
```

```bash
# Run setup to install the DayZ Server and the specified mods, resources and missions in your JSON config
dayzmanager.sh myconfig.json setup
```

```bash
# Run systemd to create or update a systemd unit for starting, stopping, auto-starting at boot, and auto-restarting the DayZ server
dayzmanager.sh myconfig.json systemd
```

### Commands

- login — Authenticate with Steam using credentials in config
- setup — Perform a fresh install using the config
- update — Update the server, mods, and missions
- start — Start the DayZ server with proper signal handling
- backup — Archive profile and mission data
- systemd — Create or update a systemd service unit

### Example Configuration

This will provide a Namalsk server with backups and auto-restarting every 6 hours.

```json
{
  "steam_username": "ExampleUsername",
  "install_directory": "~/dayzserver",
  "mods": [
    {
      "name": "Community-Framework",
      "item_id": 1559212036
    },
    {
      "name": "Community-Online-Tools",
      "item_id": 1564026768
    },
    {
      "name": "Namalsk-Island",
      "item_id": 2289456201
    },
    {
      "name": "Namalsk-Survival",
      "item_id": 2289461232
    }
  ],
  "resources": [
    {
      "type": "git",
      "name": "Namalsk-Server",
      "url": "https://github.com/SumrakDZN/Namalsk-Server"
    }
  ],
  "missions": [
    {
      "path": "resources/Namalsk-Server/Mission Files/hardcore.namalsk",
      "exclude": [
        "storage_1/"
      ],
      "exclude_update": [
        "db/messages.xml"
      ]
    }
  ],
  "server_config": "resources/Namalsk-Server/Server Config/Hardcore/serverDZ.cfg",
  "start_command": {
    "port": 2301,
    "additional_flags": [
      "cpuCount=4",
      "limitFPS=200"
    ]
  },
  "systemd": {
    "name": "dayz-namalsk-server",
    "description": "DayZ Dedicated Namalsk Server",
    "restart_after": "6h"
  },
  "backup": {
    "directory": "~/dayzserver-backup",
    "prefix": "namalskserver",
    "retention_days": 5
  }
}
```

## License

MIT
