#!/bin/sh
# One-time package installation/upgrade configuration.
set -eu

PATCHER='/usr/libexec/xray_extd/upstream_patches.sh'

[ -x "$PATCHER" ] || {
    echo "xray-ext: patch helper is missing: $PATCHER" >&2
    exit 1
}

"$PATCHER" apply

if ! uci -q get 'xray_core.@general[0]' >/dev/null 2>&1; then
    echo 'xray-ext: xray_core general section was not found; is luci-app-xray installed?' >&2
    exit 1
fi

# Create the dedicated downloader account directly, using fixed UID/GID 666.
# Check both numeric IDs first: never steal an ID already assigned to another account.
DIRECT_USER='xrayext'
DIRECT_UID='666'
DIRECT_GID='666'

passwd_uid_user="$(awk -F: -v uid="$DIRECT_UID" '$3 == uid { print $1 ":" $4; exit }' /etc/passwd)"
passwd_name_uid="$(awk -F: -v user="$DIRECT_USER" '$1 == user { print $3 ":" $4; exit }' /etc/passwd)"
group_uid_name="$(awk -F: -v gid="$DIRECT_GID" '$3 == gid { print $1; exit }' /etc/group)"
group_name_gid="$(awk -F: -v group="$DIRECT_USER" '$1 == group { print $3; exit }' /etc/group)"

# Validate both databases before changing either one, avoiding a half-created
# account if only the UID or GID is available.
if [ -n "$passwd_uid_user" ]; then
    [ "$passwd_uid_user" = "$DIRECT_USER:$DIRECT_GID" ] || {
        echo "xray-ext: UID $DIRECT_UID is already assigned to another or incompatible user: $passwd_uid_user" >&2
        exit 1
    }
else
    [ -z "$passwd_name_uid" ] || {
        echo "xray-ext: user $DIRECT_USER already exists with UID/GID $passwd_name_uid" >&2
        exit 1
    }
fi

if [ -n "$group_uid_name" ]; then
    [ "$group_uid_name" = "$DIRECT_USER" ] || {
        echo "xray-ext: GID $DIRECT_GID is already assigned to group $group_uid_name" >&2
        exit 1
    }
else
    [ -z "$group_name_gid" ] || {
        echo "xray-ext: group $DIRECT_USER already exists with GID $group_name_gid" >&2
        exit 1
    }
fi

if [ -z "$passwd_uid_user" ]; then
    printf '%s\n' 'xrayext:x:666:666:Xray Extender subscription downloader:/:/bin/sh' >> /etc/passwd
    echo "xray-ext: created system user $DIRECT_USER (UID/GID 666)"
fi

if [ -z "$group_uid_name" ]; then
    printf '%s\n' 'xrayext:x:666:' >> /etc/group
    echo "xray-ext: created system group $DIRECT_USER (GID 666)"
fi

# Remove the temporary UID setting used by the earlier overcomplicated design.
if uci -q get 'xray_ext.@general[0].subscription_direct_uid' >/dev/null 2>&1; then
    uci -q delete 'xray_ext.@general[0].subscription_direct_uid'
    uci commit xray_ext
    echo 'xray-ext: removed obsolete subscription_direct_uid option'
fi

# Keep UID 666 permanently outside Xray TProxy. The UI toggle controls only
# whether the subscription updater uses this account; it never edits xray_core.
if ! uci -q show xray_core | awk -F= '
    $1 == "xray_core.@general[0].uids_direct" {
        value = $2
        gsub(/\047/, "", value)
        count = split(value, ids, /[[:space:]]+/)
        for (i = 1; i <= count; i++) if (ids[i] == "666") found = 1
    }
    END { exit !found }
'; then
    uci add_list 'xray_core.@general[0].uids_direct=666'
    echo 'xray-ext: added UID 666 to xray_core.general.uids_direct'
    xray_core_changed=1
else
    xray_core_changed=0
fi

changed=${xray_core_changed:-0}
for option in stats observatory metrics_server_enable xray_api; do
    current="$(uci -q get "xray_core.@general[0].$option" 2>/dev/null || true)"
    if [ "$current" != '1' ]; then
        uci set "xray_core.@general[0].$option=1"
        changed=1
        echo "xray-ext: enabled xray_core.general.$option"
    fi
done

if [ "$changed" -eq 1 ]; then
    uci commit xray_core
    echo 'xray-ext: xray_core settings committed'
else
    echo 'xray-ext: required xray_core options were already enabled'
fi

echo 'xray-ext: metrics_server_port was left unchanged (Xray defaults to 18888 when unset)'
echo 'xray-ext: Xray was not restarted'
