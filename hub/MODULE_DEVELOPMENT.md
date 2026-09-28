# K.R.O.T. Hub Module Development Guide

This guide explains how to create custom modules for K.R.O.T. Hub that integrate with the Rules system.

## Module Structure

A Hub module is a directory in a GitHub repository with the following structure:

```
hub/
└── your-module/
    ├── module.json          # Required: Module manifest
    ├── install.sh           # Required: Installation script
    ├── remove.sh            # Optional: Removal script
    ├── update.sh            # Optional: Update script
    └── files/               # Optional: Additional files
        ├── etc/
        │   ├── config/      # UCI configs
        │   ├── init.d/      # Init scripts
        │   └── your-module/ # Config templates
        └── usr/
            └── bin/         # Binaries
```

## module.json Reference

The `module.json` file is the heart of your module. Here's a complete example based on Xray-core:

```json
{
  "id": "your-module",
  "name": "Your Module Name",
  "description": "Short description of what your module does.",
  "category": "tunnel",
  "author": "Your Name",
  "project_url": "https://github.com/you/your-project",
  "component": "your-module",
  "repo": "your-github-username/your-repo",
  "version": "1.0.0",
  "actions": [
    {
      "id": "your-action",
      "label": "Your Module — Action Name",
      "description": "What this action does when selected in Rules.",
      "outbound_json": {
        "type": "socks",
        "server": "127.0.0.1",
        "server_port": 10808,
        "version": "5"
      },
      "config": {
        "option": "your_config_option",
        "label": "Config Label",
        "description": "Description shown in the Rules UI.",
        "format": "json",
        "template": "hub/your-module/config.template.json",
        "render_path": "/etc/your-module/conf.d/${section}.json",
        "render_service": "your-module",
        "render_dir": "/etc/your-module/conf.d",
        "auto_port": true
      }
    }
  ],
  "install_script": "hub/your-module/install.sh",
  "update_script": "hub/your-module/update.sh",
  "remove_script": "hub/your-module/remove.sh"
}
```

### Required Fields

| Field | Description |
|-------|-------------|
| `id` | Unique module identifier (lowercase, no spaces) |
| `name` | Display name in the Modules UI |
| `description` | Short description for the Modules list |
| `category` | Category: `tunnel`, `dpi-bypass`, `dns`, etc. |
| `author` | Module author |
| `project_url` | Link to the project page |
| `component` | Component name for version detection |
| `repo` | GitHub repository (owner/repo) |
| `version` | Module version (semver recommended) |
| `install_script` | Path to install script in the repo |

### Optional Fields

| Field | Description |
|-------|-------------|
| `update_script` | Path to update script |
| `remove_script` | Path to removal script |
| `actions` | Array of actions this module contributes to Rules |
| `web_url` | URL to module's web panel (use `{{router_ip}}` for router IP) |

## Actions: Integrating with Rules

Actions allow your module to appear in the K.R.O.T. Rules action dropdown.

### Action Fields

| Field | Description |
|-------|-------------|
| `id` | Action identifier (used in UCI as `option action 'your-action'`) |
| `label` | Display name in the Rules UI |
| `description` | Help text for the action |
| `outbound_json` | Default outbound configuration for sing-box |
| `config` | Per-rule configuration field definition |

### Config Fields

| Field | Description |
|-------|-------------|
| `option` | UCI option name for the rule's config |
| `label` | Field label in Rules UI |
| `description` | Help text |
| `format` | Config format: `json`, `xray`, or `text` |
| `template` | Path to template file in the repo |
| `render_path` | Where to write the rendered config (`${section}` = rule name) |
| `render_service` | Init script to restart when config changes |
| `render_dir` | Directory for rendered configs |
| `auto_port` | If true, K.R.O.T. assigns unique ports automatically |

## Scripts

### install.sh

The install script runs when a user installs your module. It should:

1. Install binaries to appropriate locations
2. Create necessary directories
3. Install init scripts
4. Set up UCI configs
5. Start services if needed

Example structure:

```sh
#!/bin/sh
set -e

# Helper functions
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

# Download and install binary
# ... (see xray/install.sh for a complete example)

# Install init script
cp files/etc/init.d/your-module /etc/init.d/your-module
chmod 0755 /etc/init.d/your-module

# Create config directories
mkdir -p /etc/your-module/conf.d

# Enable and start service
/etc/init.d/your-module enable
/etc/init.d/your-module start

msg "Your Module installed successfully!"
```

### remove.sh

The remove script should clean up everything:

```sh
#!/bin/sh
set -e

# Stop and disable service
/etc/init.d/your-module stop 2>/dev/null || true
/etc/init.d/your-module disable 2>/dev/null || true

# Remove files
rm -f /etc/init.d/your-module
rm -f /usr/bin/your-module
rm -rf /etc/your-module

# Remove UCI config
rm -f /etc/config/your-module

echo "Your Module removed successfully"
```

### update.sh

The update script should preserve user configs:

```sh
#!/bin/sh
set -e

# Download new version
# ... (preserve /etc/your-module/conf.d and user configs)

# Restart service
/etc/init.d/your-module restart

echo "Your Module updated successfully"
```

## Version Detection

K.R.O.T. detects installed module versions through:

1. **VERSION file**: `/opt/your-module/VERSION` or `/etc/your-module/VERSION`
2. **Binary version**: Running `your-module --version`
3. **Package manager**: `opkg list-installed your-module` or `apk info -e your-module`

Implement version detection in your install script:

```sh
# Write version file for Hub detection
echo "1.0.0" > /etc/your-module/VERSION
```

## Using Your Module

### Adding a Custom Source

Users can add your module repository:

```sh
krot component_action hub add_source "your-username/your-repo"
```

Or with a specific branch:

```sh
krot component_action hub add_source "your-username/your-repo@develop"
```

### Installing a Module

```sh
krot component_action hub hub_install_your-module
```

### Removing a Module

```sh
krot component_action hub hub_remove_your-module
```

## Example: Xray-core Module

See `hub/xray/` for a complete example:

- `module.json` — Full-featured manifest with actions
- `install.sh` — Binary download, service setup, UCI config
- `update.sh` — Binary update preserving user configs
- `remove.sh` — Complete cleanup
- `config.template.json` — Template for per-rule configs

## Best Practices

1. **Preserve user data**: Never delete `/etc/your-module/conf.d` or user-edited configs during updates
2. **Use unique ports**: Let K.R.O.T. assign ports with `auto_port: true`
3. **Handle proxy settings**: Respect `krot.settings.download_lists_via_proxy` for downloads
4. **Support multiple architectures**: Detect `uname -m` and download appropriate binaries
5. **Validate configs**: Check rendered configs before restarting services
6. **Log clearly**: Use `msg()` and `fail()` for user feedback

## Testing Your Module

1. Push your module to GitHub
2. Add the source on your router:
   ```sh
   krot component_action hub add_source "your-username/your-repo"
   ```
3. Install and test:
   ```sh
   krot component_action hub hub_install_your-module
   ```
4. Check the Rules UI for your action
5. Test removal:
   ```sh
   krot component_action hub hub_remove_your-module
   ```
