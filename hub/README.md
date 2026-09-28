# K.R.O.T. Hub — Module Specification

Third-party developers can create modules for K.R.O.T. and publish them via GitHub.

## Quick Start

1. **Copy the template**: Use `hub/_template/` as a starting point for your module
2. **Read the full guide**: See [MODULE_DEVELOPMENT.md](MODULE_DEVELOPMENT.md) for detailed documentation
3. **Study the reference**: `hub/xray/` is a complete, production-ready example

## How it works

1. Create a GitHub repo with the following structure:
   ```
   hub/
     your-module/
       module.json    # Module metadata (required)
       install.sh     # Install script (required)
       remove.sh      # Remove script (optional)
       update.sh      # Update script (optional)
       config.template.json  # Config template (optional)
       files/         # Additional files (optional)
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
| `version` | Yes | Latest available release version (drives the "Update available" badge) |
| `web_url` | No | URL of the module's own web UI, shown as a link in the Hub card. `{{router_ip}}` (or `${router_ip}`) is replaced with the router's LAN address when the installed-module list is built |
| `install_script` | Yes | Path to install script relative to repo root |
| `update_script` | No | Path to update script relative to repo root |
| `remove_script` | No | Path to remove script relative to repo root |
| `actions` | No | Rule actions this module contributes to K.R.O.T. (see "Module-provided rule actions") |

## Module-provided rule actions (extending K.R.O.T.)

K.R.O.T. is a wrapper: modules extend its functionality. A module can declare
extra choices for the rule **Action** dropdown in `module.json` via the
optional `actions` array. Each entry:

```json
{
  "actions": [
    {
      "id": "xray",
      "label": "Xray — Xray JSON",
      "description": "Route matched traffic through the local Xray-core sidecar using this rule's own config.",
      "outbound_json": {
        "type": "socks",
        "server": "127.0.0.1",
        "server_port": 10808,
        "version": "5"
      },
      "config": {
        "option": "xray_json",
        "label": "Xray JSON",
        "description": "Complete Xray-core config for this rule. Its SOCKS inbound port is used automatically for the rule's outbound.",
        "format": "xray",
        "template": "hub/xray/config.template.json",
        "render_path": "/etc/xray/conf.d/${section}.json",
        "render_service": "xray",
        "render_dir": "/etc/xray/conf.d",
        "auto_port": true
      }
    }
  ]
}
```

| Action field | Required | Description |
|--------------|----------|-------------|
| `id` | Yes | Action id written to the rule's `action` option. `[A-Za-z0-9_-]+`; must not collide with the built-ins (`proxy`, `vpn`, `direct`, `block`, `zapret`, `byedpi`, `outbound`) |
| `label` | Yes | Text shown in the Action dropdown |
| `description` | No | Short hint |
| `outbound_json` | Yes | A complete sing-box outbound object used when this action is selected |
| `config` | No | Per-rule config field contributed by the action (see "Module config fields") |

Behaviour:

- The action appears in the dropdown only while the module is **installed**.
- Selecting it stores `action = <id>` and copies `outbound_json` onto the rule.
  K.R.O.T. then routes it through its existing JSON-outbound primitive, so no
  K.R.O.T. backend change is required per module.
- The copy is a snapshot, not a requirement: when a rule has no `outbound_json`
  of its own, K.R.O.T. resolves the document from the installed module that
  declares the action. A rule written through the CLI, restored from a backup,
  or saved by a release whose UI did not copy the template therefore keeps
  working without anyone editing UCI by hand. A rule's own `outbound_json`
  always wins over the module's declaration.
- An action id that no installed module declares and that carries no
  `outbound_json` stays a hard error (K.R.O.T. cannot know where to send the
  traffic), and the log names both missing pieces.
- Built-in actions keep working exactly as before.

## Module config fields (`actions[].config`)

An action can additionally ask K.R.O.T. to show a **textarea on the rule**
where the user pastes a full config document — one per rule, unlimited rules.
The module ships the starting template; K.R.O.T. stores the text, validates
it, deploys it to the router and manages the module's service. Field names
are a hard contract:

| `config` field | Required | Description |
|----------------|----------|-------------|
| `option` | Yes | UCI option on the rule that stores the config text (`krot.<rule>.<option>`) |
| `label` | Yes | Label of the textarea in the rule editor |
| `description` | No | Hint shown with the textarea |
| `format` | Yes | Validator profile: `xray` \| `json` \| `none` |
| `template` | No | Repo-relative path to a **strict JSON** template (no comments — the UI parses it with `JSON.parse`). The hub listing downloads it and returns it as `config.template_text` so the UI can prefill the field |
| `render_path` | Yes | Where K.R.O.T. writes this rule's config; `${section}` is replaced by the rule section name |
| `render_service` | Yes | `/etc/init.d/<name>` restarted by K.R.O.T. when rendered configs change |
| `render_dir` | Yes | Directory K.R.O.T. purges of stale `${section}.json` fragments of rules that no longer use this action |
| `auto_port` | No | When `true` and `format` is `xray`, K.R.O.T. reads the first SOCKS inbound port from the rule's own config and substitutes it into the rule's `outbound_json` `server_port` at runtime, so each rule talks to its own Xray inbound |

K.R.O.T. deploys module configs as follows:

- The rule's config text is validated against `format`, then rendered to
  `render_path` (one file per rule) — the service itself is not touched on save.
- `render_service` is restarted **only when the set of rendered configs
  actually changed**, never on unrelated rule edits.
- Before rendering, K.R.O.T. purges `render_dir` of stale `<section>.json`
  fragments belonging to rules that were deleted or switched to another action.
- `config.template_text` is injected into the module manifest by the hub
  listing (`hub_get_modules` downloads the `template` file), so the UI can
  prefill a freshly selected action with the module's starting point.
- The action keeps its `outbound_json` as the routing primitive; with
  `auto_port` its `server_port` is overridden per rule at runtime.

The bundled `xray` module is the reference example: it contributes the
`Xray — Xray JSON` action above, and its service starts Xray-core with
`-confdir /etc/xray/conf.d`, so Xray merges every rendered rule fragment
automatically. (Note: Xray-core ignores a `"confdir"` key inside the JSON
config — only the command line flag loads extra configs.)

## Version handling (dynamic — no code edits needed)

K.R.O.T. determines module versions automatically:

- **Installed version** is reported from the router itself, in priority order:
  1. the `VERSION` file your install script writes (e.g. `/opt/olcrtc/VERSION`),
  2. live detection for the built-in components (package manager or binary
     `--version` for zapret, byedpi, adguard),
  3. your `module.json` `version` (last-resort fallback).
- **Latest available version** comes from `module.json` `version`. Publish a
  new release, update this single field, and the Hub tab shows
  "Update available: x.y.z" next to the module until the user updates it.

Recommended: at the end of `install.sh`, write the release you actually
installed so the Hub always shows the real version:

```sh
echo "1.2.3" > /opt/your-module/VERSION
```

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
