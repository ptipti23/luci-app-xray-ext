#!/bin/sh
# Apply the two guarded luci-app-xray compatibility patches required by
# Xray Extender. Safe to run repeatedly; unknown upstream layouts are not changed.

set -eu

GEN_CONFIG="${XRAY_EXT_GEN_CONFIG:-/usr/share/xray/gen_config.uc}"
SYSTEM_MJS="${XRAY_EXT_SYSTEM_MJS:-/usr/share/xray/feature/system.mjs}"
BACKUP_DIR="${XRAY_EXT_PATCH_BACKUP_DIR:-/etc/xray_ext/patch-backups}"
ACTION="${1:-check}"

say() {
    printf 'xray-ext-patches: %s\n' "$*"
}

fail() {
    say "ERROR: $*" >&2
    exit 1
}

require_file() {
    [ -r "$1" ] || fail "required upstream file is missing or unreadable: $1"
}

# Issue #520: keep system.mjs's balancer() unchanged for concrete outbound
# enumeration. In gen_config.uc, alias that import for outbounds(), then add a
# local balancer() wrapper used by routing.balancers[] to append the dynamic
# <balancer>@balancer_outbound: prefix.
check_gen_config() {
    if grep -Fq 'balancer as balancer_outbounds' "$GEN_CONFIG" && \
       grep -Fq 'function balancer(proxy, balancer_tag, prefix)' "$GEN_CONFIG" && \
       grep -Fq '`${prefix}@balancer_outbound:`' "$GEN_CONFIG" && \
       grep -Fq 'balancer_outbounds(proxy, b, b)' "$GEN_CONFIG" && \
       grep -Fq 'balancer_outbounds(e, "destination"' "$GEN_CONFIG" && \
       grep -Fq 'balancer_outbounds(f, "fake_dns_forward_server_tcp"' "$GEN_CONFIG" && \
       grep -Fq 'balancer_outbounds(f, "fake_dns_forward_server_udp"' "$GEN_CONFIG" && \
       grep -Fq '"selector": balancer(proxy, balancer_tag, balancer_tag)' "$GEN_CONFIG" && \
       ! grep -Fq 'balancer(proxy, b, b)' "$GEN_CONFIG" && \
       ! grep -Fq '"selector": [...balancer(proxy, balancer_tag, balancer_tag)' "$GEN_CONFIG"; then
        GEN_STATE='patched'
        return 0
    fi

    # Known upstream form: one shared balancer() import, used four times by
    # outbounds() and once by balancers(). The older r2 selector-only patch is
    # accepted too and normalized by patch_gen_config().
    if grep -Fq 'from "./feature/system.mjs"' "$GEN_CONFIG" && \
       grep -Fq 'function outbounds(' "$GEN_CONFIG" && \
       grep -Fq 'function balancers(' "$GEN_CONFIG" && \
       grep -Fq 'function observatory(' "$GEN_CONFIG" && \
       grep -Fq 'balancer(proxy, b, b)' "$GEN_CONFIG" && \
       grep -Fq '"selector": balancer(proxy, balancer_tag, balancer_tag)' "$GEN_CONFIG"; then
        GEN_STATE='needs-patch'
        return 0
    fi

    if grep -Fq '"selector": [...balancer(proxy, balancer_tag, balancer_tag), `${balancer_tag}@balancer_outbound:`]' "$GEN_CONFIG" && \
       grep -Fq 'from "./feature/system.mjs"' "$GEN_CONFIG"; then
        GEN_STATE='needs-patch'
        return 0
    fi

    GEN_STATE='unsupported'
}

api_conf_block() {
    awk '
        /function[[:space:]]+api_conf[[:space:]]*\(/ { active = 1 }
        active { print }
        active && /};/ { exit }
    ' "$SYSTEM_MJS"
}

api_services_block() {
    awk '
        {
            line = $0
            if (!active && line ~ /services[[:space:]]*:/) {
                active = 1
                pos = index(line, "services")
                line = substr(line, pos)
            }
            if (active && !started) {
                pos = index(line, "[")
                if (!pos) next
                line = substr(line, pos)
                started = 1
            }
            if (active && started) {
                close_pos = index(line, "]")
                if (close_pos) line = substr(line, 1, close_pos)
                print line
                if (close_pos) exit
            }
        }
    '
}

check_system_mjs() {
    local block services
    block="$(api_conf_block)"

    if [ -z "$block" ]; then
        API_STATE='unsupported'
        return 0
    fi

    services="$(printf '%s\n' "$block" | api_services_block)"
    if [ -z "$services" ]; then
        API_STATE='unsupported'
        return 0
    fi

    if ! printf '%s\n' "$services" | grep -Fq '"HandlerService"' || \
       ! printf '%s\n' "$services" | grep -Fq '"LoggerService"' || \
       ! printf '%s\n' "$services" | grep -Fq '"StatsService"' || \
       ! printf '%s\n' "$block" | grep -Fq 'xray_api'; then
        API_STATE='unsupported'
        return 0
    fi

    if printf '%s\n' "$services" | grep -Fq '"RoutingService"'; then
        API_STATE='patched'
        return 0
    fi

    if ! printf '%s\n' "$services" | grep -Eq '"HandlerService"[[:space:]]*,'; then
        API_STATE='unsupported'
        return 0
    fi

    API_STATE='needs-patch'
}

get_mode() {
    stat -c '%a' "$1" 2>/dev/null || printf '644\n'
}

backup_file() {
    local file="$1"
    local stamp backup

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true
    stamp="$(date '+%Y%m%d-%H%M%S')"
    backup="$BACKUP_DIR/$(basename "$file").${stamp}.$$"
    cp -p "$file" "$backup" || fail "could not back up $file"
    say "backup created: $backup"
}

patch_gen_config() {
    local tmp mode
    tmp="${GEN_CONFIG}.xray-ext.$$"
    mode="$(get_mode "$GEN_CONFIG")"

    # Preserve the exported helper for outbounds() and use a local wrapper only
    # when generating routing.balancers[].selector.
    awk '
        function replace_once(text, old, new, pos) {
            pos = index(text, old)
            if (!pos) return text
            return substr(text, 1, pos - 1) new substr(text, pos + length(old))
        }
        BEGIN {
            legacy = "\"selector\": [...balancer(proxy, balancer_tag, balancer_tag), `${balancer_tag}@balancer_outbound:`]"
            selector = "\"selector\": balancer(proxy, balancer_tag, balancer_tag)"
            helper = "function balancer(proxy, balancer_tag, prefix) {\n" \
                     "    return [\n" \
                     "        ...balancer_outbounds(proxy, balancer_tag, prefix),\n" \
                     "        `${prefix}@balancer_outbound:`\n" \
                     "    ];\n" \
                     "};\n\n"
        }
        {
            line = $0

            # Rename only the balancer imported from feature/system.mjs.
            module_pos = index(line, "from \"./feature/system.mjs\"")
            if (module_pos) {
                import_part = substr(line, 1, module_pos - 1)
                if (index(import_part, "balancer as balancer_outbounds")) {
                    imported = 1
                } else if (sub(/balancer,[[:space:]]*logging,/, "balancer as balancer_outbounds, logging,", import_part)) {
                    imported = 1
                }
                line = import_part substr(line, module_pos)
            }

            # The old helper must remain in outbounds(), which creates concrete
            # outbound objects. Rename its four calls, and only those calls.
            out_pos = index(line, "function outbounds(")
            rules_pos = index(line, "function rules(")
            if (out_pos && rules_pos > out_pos) {
                block = substr(line, out_pos, rules_pos - out_pos)
                changed = gsub(/balancer[[:space:]]*\(/, "balancer_outbounds(", block)
                calls += changed
                line = substr(line, 1, out_pos - 1) block substr(line, rules_pos)
            } else if (out_pos) {
                block = substr(line, out_pos)
                changed = gsub(/balancer[[:space:]]*\(/, "balancer_outbounds(", block)
                calls += changed
                line = substr(line, 1, out_pos - 1) block
                in_outbounds = 1
            } else if (in_outbounds) {
                rules_pos = index(line, "function rules(")
                if (rules_pos) {
                    block = substr(line, 1, rules_pos - 1)
                    changed = gsub(/balancer[[:space:]]*\(/, "balancer_outbounds(", block)
                    calls += changed
                    line = block substr(line, rules_pos)
                    in_outbounds = 0
                } else {
                    calls += gsub(/balancer[[:space:]]*\(/, "balancer_outbounds(", line)
                }
            }

            # Remove the earlier r2 call-site addition before adding the
            # generator-local wrapper, so the prefix is not duplicated.
            line = replace_once(line, legacy, selector)

            # Insert the wrapper before balancers(), including in compact
            # one-line upstream sources.
            balancers_pos = index(line, "function balancers(")
            if (balancers_pos) {
                prefix = substr(line, 1, balancers_pos - 1)
                suffix = substr(line, balancers_pos)
                print prefix helper suffix
                inserted = 1
                next
            }

            print line
        }
        END {
            if (!imported || !inserted || calls != 4) exit 2
        }
    ' "$GEN_CONFIG" > "$tmp" || {
        rm -f "$tmp"
        fail "could not safely patch $GEN_CONFIG (expected the known balancer import and four outbound references)"
    }

    chmod "$mode" "$tmp" || {
        rm -f "$tmp"
        fail "could not preserve permissions on $GEN_CONFIG"
    }
    mv "$tmp" "$GEN_CONFIG" || {
        rm -f "$tmp"
        fail "could not install patched $GEN_CONFIG"
    }

    say 'patch #520 applied: the original outbound helper is preserved; built-in balancer selectors also match dynamically added outbounds'
}

patch_system_mjs() {
    local tmp mode
    tmp="${SYSTEM_MJS}.xray-ext.$$"
    mode="$(get_mode "$SYSTEM_MJS")"

    # Search only inside api_conf() -> services: [...]. This works for both
    # normally formatted files and a compact one-line function.
    awk '
        {
            line = $0
            prefix = ""

            if (!in_api && line ~ /function[[:space:]]+api_conf[[:space:]]*\(/) {
                in_api = 1
                pos = index(line, "function")
                prefix = substr(line, 1, pos - 1)
                line = substr(line, pos)
            }

            if (in_api && !in_services) {
                pos = index(line, "services")
                if (pos) {
                    prefix = prefix substr(line, 1, pos - 1)
                    line = substr(line, pos)
                    in_services = 1
                }
            }

            if (in_services && !done) {
                if (match(line, /"HandlerService"[[:space:]]*,/)) {
                    before = substr(line, 1, RSTART + RLENGTH - 1)
                    after = substr(line, RSTART + RLENGTH)
                    match(before, /^[[:space:]]*/)
                    indent = substr(before, RSTART, RLENGTH)

                    print prefix before
                    print indent "\"RoutingService\"," after
                    done = 1
                    next
                }
            }

            print $0
            if (in_api && /};/) in_api = 0
        }
        END { if (!done) exit 2 }
    ' "$SYSTEM_MJS" > "$tmp" || {
        rm -f "$tmp"
        fail "could not safely patch $SYSTEM_MJS (upstream source layout changed)"
    }

    chmod "$mode" "$tmp" || {
        rm -f "$tmp"
        fail "could not preserve permissions on $SYSTEM_MJS"
    }
    mv "$tmp" "$SYSTEM_MJS" || {
        rm -f "$tmp"
        fail "could not install patched $SYSTEM_MJS"
    }
    say 'patch #523 applied: RoutingService enabled in Xray API'
}

require_file "$GEN_CONFIG"
require_file "$SYSTEM_MJS"

check_gen_config
check_system_mjs

say "gen_config.uc (#520): $GEN_STATE"
say "feature/system.mjs (#523): $API_STATE"

if [ "$ACTION" = 'check' ]; then
    [ "$GEN_STATE" = 'patched' ] && [ "$API_STATE" = 'patched' ] || exit 2
    say 'all required upstream patches are present'
    exit 0
fi

[ "$ACTION" = 'apply' ] || fail "usage: $0 [check|apply]"

# Inspect both files before changing either. Unknown source layouts stop the
# operation before any file is modified.
[ "$GEN_STATE" != 'unsupported' ] || fail "unrecognized balancers() selector in $GEN_CONFIG; leaving it untouched"
[ "$API_STATE" != 'unsupported' ] || fail "unrecognized api_conf() in $SYSTEM_MJS; leaving it untouched"

if [ "$GEN_STATE" = 'needs-patch' ]; then
    backup_file "$GEN_CONFIG"
    patch_gen_config
fi

if [ "$API_STATE" = 'needs-patch' ]; then
    backup_file "$SYSTEM_MJS"
    patch_system_mjs
fi

check_gen_config
check_system_mjs
[ "$GEN_STATE" = 'patched' ] || fail "verification failed for $GEN_CONFIG"
[ "$API_STATE" = 'patched' ] || fail "verification failed for $SYSTEM_MJS"
say 'all required upstream patches are present'
