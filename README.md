# Xray Extender

LuCI web interface extension for `luci-app-xray`. This package automates advanced configuration management, object routing, upstream telemetry integration, and data backup tools for your local layout.

## Features

- **Automated Configuration Handling:** Simplifies processing of complex object structures and remote telemetry links.
- **Upstream Integration Patches:** Safely resolves known configuration layout compatibility issues via automated, idempotent patches.
- **Privilege Separation:** Downloads remote data using a dedicated low-privilege system user account (`xrayext`) for maximum local security.
- **Data Formats:** Full support for plain-text data matrices, Base64 strings, and structural JSON configurations.

---

## Runtime Dependencies

The package declares strict runtime dependencies on:
- `luci-app-xray` (the main web interface and configuration schema)
- `luci-base`
- `wget-ssl` (required for secure remote data transfers)
- Lua 5.1 and base OpenWrt Lua bindings (`lua`, `lua-cjson`, `libubox-lua`, `libubus-lua`, `libuci-lua`)

---

## Build and Installation (OpenWrt Buildroot)

1. Update and install your environment feeds, ensuring the feed containing the prerequisite packages is enabled:
   ```sh
   ./scripts/feeds update -a
   ./scripts/feeds install -a
   ```

2. Place this directory at `package/luci-app-xray-ext` inside your buildroot:
   ```sh
   make package/luci-app-xray-ext/clean
   make package/luci-app-xray-ext/compile V=s
   ```

3. Install the resulting `.apk` binaries from `bin/packages/` onto your router.

---

## Technical Details & Internal Architecture

<details>
<summary>⚙️ Click to expand advanced architecture details (Patches, Automation, Formats)</summary>

### Upstream Compatibility Patches
The installation script checks and applies guarded patches inside the installed environment files:
- **Issue #520** — appends the built-in balancer's outbound-tag prefix to its `routing.balancers[].selector` in `/usr/share/xray/gen_config.uc`.
- **Issue #523** — enables `RoutingService` in `api_conf()` in `/usr/share/xray/feature/system.mjs`.

The patcher tool creates timestamped backups under `/etc/xray_ext/patch-backups/` and can be run manually:
```sh
xray-ext-patches check
xray-ext-patches apply
```

### Automation & API Options
During installation or first-boot (`uci-defaults`), the installer safely sets the following telemetry keys to `1` in `/etc/config/xray_core`:
- `stats`, `observatory`, `metrics_server_enable`, `xray_api`

### Secure Downloads
When direct downloads are enabled, the daemon spawns download commands strictly under the system user `xrayext` (UID/GID 666). The system validates that these IDs are free before allocating them.

### Data Formats & Protocols
Configuration payloads may contain plain-text/Base64 URI lists or complex JSON arrays. Processing is handled by `xray_subscription_json_parser.lua`. The extension supports standard processing schemas including dynamic object routing, fallback nodes, and custom configuration injection (`splithttpSettings`, etc.).

### Data Preservation
`/etc/config/xray_ext` is managed as a standard persistent conffile. Runtime metadata located under `/etc/xray_ext/` is fully preserved during package upgrades or software removal.
</details>

---

## Bug Reports & Contributions

⚠️ **Notice:** This project is developed in my free time. There are probably bugs hidden inside, and I won't be able to catch all of them on my own. 

If you find an issue, a broken parser, or have an idea for improvement, feel free to open an **Issue** or submit a **Pull Request**. Any help and contributions from the community are highly appreciated!

---

## License Notice

This project is free and open-source software. You are completely free to modify, redistribute, or use this code in any way you like — do whatever you want with it, I really don't care. :)

Licensed under the **WTFPL** (Do What You Want To Public License). 
*(For package metadata in your buildroot, use `PKG_LICENSE:=WTFPL`)*.

