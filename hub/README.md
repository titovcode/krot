# K.R.O.T. Hub — Module Specification

Third-party developers can create modules for K.R.O.T. and publish them via GitHub.

## How it works

1. Create a GitHub repo with the following structure:
   ```
   hub/
     your-module/
       module.json    # Module metadata
       install.sh     # Install script (required)
       remove.sh      # Remove script (optional)
       update.sh      # Update script (optional)
   ```

2. Add your repo as a Hub source in K.R.O.T. → Hub → "Add source"

3. Your module will appear in the Hub tab and can be installed/updated/removed.

## module.json format

```json
{
  "id": "my-module",
  "name": "My Module",
  "description": "Short description of what this module does",
  "category": "dpi-bypass",
  "author": "your-username",
  "project_url": "https://github.com/you/your-project",
  "component": "my_module",
  "repo": "you/your-krot-hub-repo",
  "version": "1.0.0",
  "install_script": "hub/my-module/install.sh",
  "update_script": "hub/my-module/update.sh",
  "remove_script": "hub/my-module/remove.sh"
}
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique module identifier (alphanumeric, dash, underscore) |
| `name` | Yes | Human-readable display name |
| `description` | Yes | Short description shown in the Hub |
| `category` | Yes | Category tag (e.g., `dpi-bypass`, `utility`, `networking`) |
| `author` | Yes | Author name or GitHub username |
| `project_url` | Yes | URL to the upstream project |
| `component` | Yes | Internal component identifier (must be unique) |
| `repo` | Yes | GitHub `owner/repo` where this module lives |
| `version` | Yes | Module version string |
| `install_script` | Yes | Path to install script relative to repo root |
| `update_script` | No | Path to update script relative to repo root |
| `remove_script` | No | Path to remove script relative to repo root |

## install.sh

The install script is executed with `sh`. It should:

1. Detect the system architecture and package format (`apk` or `opkg`)
2. Download the appropriate package/binary
3. Install it

Example:
```bash
#!/bin/sh
set -e

# Detect package format
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

if [ "$PKG_IS_APK" -eq 1 ]; then
    ARCH="$(apk info --print-arch 2>/dev/null)"
    EXT="apk"
else
    ARCH="$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -v '^all$' | head -1)"
    EXT="ipk"
fi

# Download and install
# ... your logic here ...
```

## remove.sh

Optional. Called when the user removes the module. Should clean up installed files.

## update.sh

Optional. Called when the user checks for updates. Should download and install the latest version.

## Security notes

- Module IDs are validated: only `[a-zA-Z0-9_-]+` is allowed (no path traversal)
- Scripts are downloaded over HTTPS from GitHub
- Scripts run with the same privileges as the K.R.O.T. service (typically root)
- Only add modules from trusted sources
