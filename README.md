# Xray Extender

A LuCI companion for `luci-app-xray`. Xray Extender adds subscription management, server health monitoring, backup server management, automatic failover and runtime outbound control.

The extension works alongside the original `luci-app-xray` package. It does not replace Xray-core or its configuration interface.

## Features

- **Subscription management** — import and update server subscriptions, track subscription metadata and handle missing or changed servers.
- **Multiple subscription formats** — plain-text URI lists, Base64-encoded URI lists and JSON Xray configurations.
- **Adaptive subscription retries** — retry failed subscriptions every five minutes during the first hour, then once per hour until recovery.
- **Smart manual refresh** — refresh only failed subscriptions during the initial retry window, then allow a full refresh of all enabled subscriptions.
- **Server health monitoring** — monitor primary and backup servers, with configurable confirmation thresholds to avoid reacting to short-lived state changes.
- **Automatic failover** — dynamically add backup outbounds when a primary group becomes unavailable and remove them when normal operation is restored.
- **Runtime outbound management** — inspect, add and remove Xray outbounds without restarting Xray.
- **Balancer monitoring** — inspect current balancer selections and runtime outbound membership.
- **Resolver settings** — configure DNS resolution strategies and DNS servers for imported nodes.
- **Direct subscription downloads** — optionally fetch subscription URLs outside Xray transparent proxying.
- **Upstream compatibility patches** — apply guarded, repeatable patches required by the installed `luci-app-xray` version.

## Runtime architecture

The main daemon is written in Lua and runs independently of the LuCI page.

```text
LuCI interface
     |
     | ubus
     v
xray_extd daemon
     |
     +---- Subscription downloader
     |
     +---- Subscription parsers
     |
     +---- Subscription retry manager
     |
     +---- Server health monitoring
     |
     +---- Failover management
     |
     +---- Runtime outbound management
                 |
                 v
            xray_grpc.so
                 |
                 | gRPC
                 v
             Xray-core
```

The daemon uses the native Lua/C gRPC module for runtime operations. Supported outbound configurations are built directly as protobuf messages. The CLI is retained as a fallback for configurations that the native builder explicitly reports as unsupported.

### Runtime ADO and RMO

- **ADO** — Add Outbound: add an outbound to the running Xray instance.
- **RMO** — Remove Outbound: remove an outbound from the running Xray instance.

Native ADO builders currently cover VLESS, Hysteria 2 and Shadowsocks 2022 configurations. Unsupported settings may use the CLI fallback.

RMO and ADO operations are verified against the actual runtime outbound list. A successful API response alone is not treated as sufficient confirmation.

Successful operations are logged with the tag, protocol, transport, security type, server address and execution method.

## Subscriptions

### Supported input formats

Subscriptions may contain:

- Plain-text protocol URI lists.
- Base64-encoded URI lists.
- JSON arrays containing Xray configuration objects.

Supported subscription protocols include VLESS, Hysteria 2 and Shadowsocks, including Shadowsocks 2022.

Standard protocol settings are stored in the corresponding `luci-app-xray` UCI fields. Additional configuration is retained in `custom_config` where appropriate.

Duplicate server aliases are matched by occurrence index rather than by alias alone. This helps preserve the correct relationship between subscription entries and existing UCI sections.

### Download and update pipeline

Subscription downloads use an asynchronous `uloop.process` pipeline:

1. Up to three downloads can run concurrently.
2. Results are processed sequentially.
3. Each update follows the `PLAN → APPLY → COMMIT` sequence.
4. Each subscription is tracked independently by its subscription ID (`ext_id`).
5. Failed downloads and unsuccessful update operations enter the automatic retry system.
6. A download has a 60-second deadline; a timed-out process is terminated, followed by a forced kill if necessary.

The downloader separates response data from HTTP headers and diagnostic output.

### Automatic retry policy

Failed subscription updates use an adaptive retry schedule:

- During the first hour after the initial failure, the daemon retries every five minutes.
- After one hour of continuous failures, the retry interval changes to once per hour.
- Hourly retries continue indefinitely until the subscription is successfully updated.
- A successful update clears the retry history for that subscription.
- Retry state is maintained separately for each subscription, so one subscription recovering does not affect another subscription's retry schedule.

The retry mechanism is independent of the regular subscription update interval. An enabled subscription can continue receiving failure retries even when its normal update interval is set to manual.

Retry state is stored in:

```text
/tmp/xray_ext/subscription_retry_state.json
```

The state survives daemon restarts but is temporary and is lost after a full router reboot.

### Manual refresh behaviour

The manual refresh button adapts its scope to the current retry state:

- If there are no subscriptions awaiting retry, all enabled subscriptions are refreshed.
- During the initial one-hour retry window, manual refresh targets only failed subscriptions.
- Once all recorded failures have entered the hourly cooldown phase, the next manual refresh targets all enabled subscriptions.
- Failed subscriptions that remain unavailable after a full manual refresh start a new one-hour retry window.
- Successfully updated subscriptions have their retry history cleared.

Manual refreshes do not disable the automatic retry mechanism. The daemon continues to maintain retry schedules independently.

This approach avoids repeatedly downloading healthy subscriptions during short recovery periods while still allowing a complete manual refresh after prolonged failures.

### Direct downloads

The **Download subscriptions directly (bypass Xray)** option runs subscription download commands under the dedicated `xrayext` account (UID/GID 666).

This account is excluded from Xray transparent proxying through `xray_core.general.uids_direct`. This allows subscription updates to continue even when the VPN tunnels are unavailable.

The option controls how downloads are executed; changing it does not require an Xray restart.

### Subscription metadata

Subscription metadata is stored separately from the server configuration:

```text
/etc/xray_ext/subscription_meta.json
```

It may contain subscription title, web page URL, user information, update timestamp, support URL and announcement text.

## Health monitoring and failover

The daemon monitors primary and backup server groups independently.

Failover is designed to avoid reacting to a single failed or successful probe. Confirmation thresholds can be configured in `/etc/config/xray_ext`.

Relevant options include:

- `failover_dead_confirm`
- `failover_live_confirm`
- `subscription_dead_confirm`
- `subscription_live_confirm`
- `backup_subscription_dead_confirm`
- `backup_subscription_live_confirm`

The daemon checks WAN link state before performing network-dependent work. WAN availability is based on the link state, not on a general Internet reachability test.

When a primary group is confirmed available again, stale scheduled `group_dead` subscription update requests are cancelled, including when no backup servers were available and failover was never activated.

This prevents unnecessary subscription downloads after a primary group recovers on its own.

**Important:** a server reported as alive by the current health checks is not necessarily capable of delivering usable application throughput. Connection health and real-world service quality are different measurements. Quality-aware failover remains a separate area for future development.

## Blackhole fallback for balancers

This is an important safety feature in the recommended Xray configuration.

When all members of a balancer are considered unavailable according to Observatory results, Xray can use the balancer's `fallbackTag`.

Without an explicit fallback, a failed balancing path may not provide the fail-closed behavior desired for a VPN-only configuration.

The solution is to direct the four built-in IPv4/IPv6 TCP/UDP balancers to a dedicated Blackhole outbound:

```json
{
  "tag": "blackhole_outbound",
  "protocol": "blackhole",
  "settings": {
    "response": {
      "type": "none"
    }
  }
}
```

Make sure this outbound exists in the final Xray configuration and that its tag is unique.

### Custom Configuration Hook

Place the following code in the `luci-app-xray` **Custom Configuration Hook**:

```javascript
return function(config) {
    if (config.routing && config.routing.balancers) {
        for (let balancer in config.routing.balancers) {
            if (
                balancer.tag == "tcp_outbound_v4" ||
                balancer.tag == "udp_outbound_v4" ||
                balancer.tag == "tcp_outbound_v6" ||
                balancer.tag == "udp_outbound_v6"
            ) {
                balancer.fallbackTag = "blackhole_outbound";
            }
        }
    }

    return config;
};
```

The hook assigns `blackhole_outbound` as the fallback for:

- `tcp_outbound_v4`
- `udp_outbound_v4`
- `tcp_outbound_v6`
- `udp_outbound_v6`

When Observatory reports that all selected members are unavailable, traffic sent through the affected balancer is discarded instead of being passed to an unintended outbound.

**Requirements and limitations:**

- The `blackhole_outbound` tag must exist in the final Xray configuration.
- Observatory or burstObservatory must be configured for health-based fallback selection.
- This is a fail-closed fallback for these balancers, not a global routing rule.
- It does not measure throughput or detect every case of a technically alive but unusably slow server.

References: [Xray Balancer configuration](https://xtls.github.io/ru/config/routing.html) · [Xray Blackhole outbound](https://xtls.github.io/ru/config/outbounds/blackhole.html)

## Native gRPC module

The native module is built from the C sources in `src/` and installed as:

```text
/usr/lib/lua/xray_grpc.so
```

It provides runtime operations used by the daemon, including:

- Listing runtime outbounds.
- Adding outbounds through `HandlerService`.
- Removing outbounds through `HandlerService`.
- Reading balancer information.

The Lua daemon exposes the corresponding control methods through ubus:

```text
xray_extd.status
xray_extd.refresh
xray_extd.outbounds
xray_extd.balancer_info
xray_extd.add_outbound
xray_extd.remove_outbound
```

Example diagnostics:

```sh
ubus -v list xray_extd

ubus call xray_extd status '{}'

ubus call xray_extd outbounds '{}'

ubus call xray_extd balancer_info \
    '{"tag":"tcp_outbound_v4"}'
```

## Upstream compatibility patches

The package includes guarded patches for compatibility with the installed upstream packages.

| Target | Purpose |
|---|---|
| `gen_config.uc` (#520) | Preserve dynamic outbound selection by extending built-in balancer selectors |
| `feature/system.mjs` (#523) | Enable the required RoutingService API |
| `common/tls.mjs` | Maintain TLS configuration compatibility where required |
| `common/stream.mjs` (#525) | Map WebSocket Host to the dedicated `host` property instead of treating it as a generic HTTP header |

The WebSocket compatibility patch moves `ws_host` into the dedicated WebSocket `host` setting. It does not treat the Host value as an ordinary HTTP header.

The patch manager applies these compatibility patches automatically when the Xray Extender daemon service starts.

Each patch checks the expected upstream source layout before applying changes. Existing patches are detected and skipped. Unknown source layouts are left untouched and cause the patch operation to fail rather than blindly modifying upstream files.

Original files are backed up under:

```text
/etc/xray_ext/patch-backups/
```

Useful commands:

```sh
xray-ext-patches check
xray-ext-patches apply
```

The patcher is designed to be safe to run repeatedly.

## Important files and locations

| Path | Purpose |
|---|---|
| `/usr/libexec/xray_extd/xray_extd.lua` | Main Lua daemon |
| `/usr/libexec/xray_extd/xray_subscription_json_parser.lua` | JSON subscription parser |
| `/usr/lib/lua/xray_grpc.so` | Native gRPC module |
| `/usr/libexec/xray_extd/upstream_patches.sh` | Upstream compatibility patch manager |
| `/www/luci-static/resources/view/xray/xray_ext.js` | LuCI interface |
| `/etc/config/xray_ext` | Persistent Xray Extender configuration |
| `/etc/xray_ext/subscription_meta.json` | Subscription metadata |
| `/etc/xray_ext/patch-backups/` | Upstream patch backups |
| `/tmp/xray_ext/subscription_retry_state.json` | Temporary per-subscription retry state |
| `/tmp/xray_extd_runtime_lists.json` | Temporary runtime outbound snapshot |

The backup server lists in `/etc/config/xray_ext` are part of the failover configuration. Do not remove them when cleaning up or troubleshooting the package.

## Logs and diagnostics

View daemon messages:

```sh
logread -e xray_extd
```

Check Lua syntax after editing the daemon:

```sh
luac -p /usr/libexec/xray_extd/xray_extd.lua
```

Restart the daemon:

```sh
/etc/init.d/xray_extd restart
```

Inspect runtime outbounds and daemon registration:

```sh
ubus -v list xray_extd
ubus call xray_extd outbounds '{}'
```

Check upstream patch status:

```sh
xray-ext-patches check
```

For ADO/RMO diagnostics, look for messages containing:

```text
ADO OK
ADO FAILED
RMO OK
RMO FAILED
ADO VERIFIED
BACKUP PROBE
FAILOVER
```

For subscription retry diagnostics, look for messages containing:

```text
SUBSCRIPTION RETRY SCHEDULED
SUBSCRIPTION RETRY RESTORED
SUBSCRIPTION RETRY STATE CLEARED
UPDATE FETCH START FAILED
UPDATE FETCH/PARSE FAILED
UPDATE APPLY FAILED
```

## Build

Place the package source in:

```text
package/luci-app-xray-ext/
```

From the OpenWrt buildroot:

```sh
make package/luci-app-xray-ext/clean
make package/luci-app-xray-ext/compile V=s
```

The resulting package is placed under the target architecture's directory in:

```text
bin/packages/
```

Package version and release number are maintained in the package `Makefile`.

## Configuration and data preservation

The main configuration is stored in:

```text
/etc/config/xray_ext
```

Subscription metadata and patch backups are stored persistently under:

```text
/etc/xray_ext/
```

Temporary runtime data, including subscription retry state, is stored under:

```text
/tmp/xray_ext/
```

Temporary retry state survives daemon restarts but is lost after a full router reboot.

Back up the persistent configuration and metadata locations before manual cleanup, package removal or major configuration changes.

The package complements `luci-app-xray`; its configuration and runtime operations depend on the Xray-core configuration and API being available.

## License

**WTFPL**