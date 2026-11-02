#!/usr/bin/lua

local uloop = require("uloop")
local uci = require("uci")
local ubus = require("ubus")

local VERSION = "0.4.9-backup-subscription-health-manual-ubus-runtime-snapshot-direct-subscriptions-json-subscriptions-duplicate-alias-indexing"
local INTERVAL = 10000

-- Persistent probe outbounds for backup TCP IPv4 subscription health checks.
-- They remain outside user-facing balancers and use Observatory's existing
-- "extra_inbound" selector.
local BACKUP_PROBE_TCP_V4_PREFIX = "extra_inbound_backup_tcp_v4:"
local backup_probe_fingerprints = {}
local backup_probe_retry_after = {}
local backup_probe_last_log = {}
local backup_probe_missing_logged = {}

uloop.init()

print("xray_extd: starting, version " .. VERSION)

function trim(value)
    if value == nil then
        return ""
    end

    local value_type = type(value)
    if value_type ~= "string" and value_type ~= "number" then
        return ""
    end

    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_list(value)

    if type(value) == "table" then
        return value
    end

    if value and value ~= "" then
        return { value }
    end

    return {}
end


local function positive_integer(value, default)
    local number = tonumber(value)
    if number and number >= 1 and number == math.floor(number) then
        return number
    end
    return default
end


local cjson = require("cjson")
if type(cjson.decode_array_with_array_mt) == "function" then
    pcall(cjson.decode_array_with_array_mt, true)
end

-- Previous logical WAN state; nil means that the daemon has not checked yet.
local last_wan_up = nil

-- Check OpenWrt's logical WAN state, not Internet reachability or a physical port.
-- Fail closed: if ubus output is unavailable or invalid, pause daemon actions.
local function is_wan_up()
    local pipe = io.popen(
        "ubus call network.interface.wan status 2>/dev/null"
    )

    if not pipe then
        return false
    end

    local output = pipe:read("*a") or ""
    pipe:close()

    if output == "" then
        return false
    end

    local ok, status = pcall(cjson.decode, output)

    return ok
        and type(status) == "table"
        and status.up == true
end

-- Subscription parser is intentionally kept separate from the daemon.
local SUBSCRIPTION_PARSER_PATH = "/usr/libexec/xray_extd/xray_subscription_parser.lua"
local subscription_parser_ok, subscription_parser = pcall(
    dofile,
    SUBSCRIPTION_PARSER_PATH
)

if subscription_parser_ok
   and type(subscription_parser) == "table"
   and type(subscription_parser.parse) == "function" then
    print("xray_extd: subscription parser loaded")
else
    local parser_load_error = subscription_parser_ok
        and "parse() missing"
        or subscription_parser

    subscription_parser = nil
    print(
        "xray_extd: subscription parser unavailable; queued updates cannot be checked: " ..
        tostring(parser_load_error)
    )
end

-- JSON Xray-config subscriptions use a separate, independently testable parser.
local SUBSCRIPTION_JSON_PARSER_PATH = "/usr/libexec/xray_extd/xray_subscription_json_parser.lua"
local subscription_json_parser_ok, subscription_json_parser = pcall(
    dofile,
    SUBSCRIPTION_JSON_PARSER_PATH
)

if subscription_json_parser_ok
   and type(subscription_json_parser) == "table"
   and type(subscription_json_parser.parse) == "function" then
    print("xray_extd: JSON subscription parser loaded")
else
    local parser_load_error = subscription_json_parser_ok
        and "parse() missing"
        or subscription_json_parser

    subscription_json_parser = nil
    print(
        "xray_extd: JSON subscription parser unavailable: " ..
        tostring(parser_load_error)
    )
end

local function get_observatory(port)
    port = port or "18888"

    local cmd =
        "/usr/bin/wget -qO- " ..
        "http://127.0.0.1:" ..
        port ..
        "/debug/vars 2>/dev/null"

    local pipe = io.popen(cmd)

    if not pipe then
        print("xray_extd: failed to start wget")
        return nil
    end

    local body = pipe:read("*a")
    pipe:close()

    if not body or body == "" then
        print("xray_extd: empty /debug/vars response")
        return nil
    end

    local ok, data = pcall(
        cjson.decode,
        body
    )

    if not ok then
        print("xray_extd: failed to parse /debug/vars")
        return nil
    end

    return data.observatory or {}
end


local function shell_quote(value)

    value = tostring(value)

    return "'" ..
        value:gsub("'", "'\\''") ..
        "'"
end


-- Subscription HTTP metadata is kept separately from the user-defined name
-- and keyed by ext_id so renaming a subscription does not lose its metadata.
local SUBSCRIPTION_META_PATH = "/etc/xray_ext/subscription_meta.json"
local MAX_ANNOUNCE_LENGTH = 65536

local function read_subscription_metadata_file()
    local file = io.open(SUBSCRIPTION_META_PATH, "r")
    if not file then
        return { subscriptions = {} }
    end

    local contents = file:read("*a") or ""
    file:close()

    local ok, data = pcall(cjson.decode, contents)
    if not ok or type(data) ~= "table" then
        print("xray_extd: subscription metadata file is invalid; starting with an empty in-memory structure")
        return { subscriptions = {} }
    end

    if type(data.subscriptions) ~= "table" then
        data.subscriptions = {}
    end

    return data
end

local function write_subscription_metadata_file(data)
    local mkdir_pipe = io.popen("mkdir -p /etc/xray_ext 2>&1", "r")
    if not mkdir_pipe then
        return false, "cannot create metadata directory"
    end
    local mkdir_output = mkdir_pipe:read("*a") or ""
    local mkdir_ok, mkdir_reason, mkdir_code = mkdir_pipe:close()
    if mkdir_ok == nil or mkdir_ok == false then
        return false, "mkdir failed: " .. tostring(mkdir_reason or "") .. " " .. tostring(mkdir_code or "")
    end

    local encoded_ok, encoded = pcall(cjson.encode, data)
    if not encoded_ok or type(encoded) ~= "string" then
        return false, "cannot encode metadata JSON"
    end

    -- Keep the temporary file in the same filesystem for atomic rename.
    local temp_path = SUBSCRIPTION_META_PATH .. ".tmp." .. tostring(os.time()) .. "." .. tostring(math.random(100000, 999999))
    local file, open_error = io.open(temp_path, "w")
    if not file then
        return false, "cannot open temporary metadata file: " .. tostring(open_error)
    end

    local write_ok, write_error = file:write(encoded, "\n")
    local close_ok, close_error = file:close()
    if not write_ok or close_ok == nil then
        os.remove(temp_path)
        return false, "cannot write metadata file: " .. tostring(write_error or close_error or "unknown error")
    end

    local rename_ok, rename_error = os.rename(temp_path, SUBSCRIPTION_META_PATH)
    if not rename_ok then
        os.remove(temp_path)
        return false, "cannot atomically replace metadata file: " .. tostring(rename_error)
    end

    return true
end

local function decode_base64(value)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    if type(value) ~= "string" or value:find("[^A-Za-z0-9+/=\r\n]" ) then
        return nil
    end

    value = value:gsub("%s", "")
    if #value == 0 or (#value % 4) ~= 0 then
        return nil
    end

    local out = {}
    for i = 1, #value, 4 do
        local a = alphabet:find(value:sub(i, i), 1, true)
        local b = alphabet:find(value:sub(i + 1, i + 1), 1, true)
        local cchar = value:sub(i + 2, i + 2)
        local dchar = value:sub(i + 3, i + 3)
        local c = cchar == "=" and nil or alphabet:find(cchar, 1, true)
        local d = dchar == "=" and nil or alphabet:find(dchar, 1, true)

        if not a or not b then return nil end
        if cchar ~= "=" and not c then return nil end
        if dchar ~= "=" and not d then return nil end
        if cchar == "=" and dchar ~= "=" then return nil end
        if (cchar == "=" or dchar == "=") and i + 3 < #value then return nil end

        local n = (a - 1) * 262144 + (b - 1) * 4096
        if c then n = n + (c - 1) * 64 end
        if d then n = n + (d - 1) end
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if c then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if d then out[#out + 1] = string.char(n % 256) end
    end

    return table.concat(out)
end

local function decode_profile_value(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value:sub(1, 7) == "base64:" then
        return decode_base64(value:sub(8))
    end
    return value
end

local function valid_http_url(value)
    return type(value) == "string"
        and (value:match("^https://[^%s]+$") or value:match("^http://[^%s]+$"))
end

local function parse_subscription_response_headers(raw_headers)
    local headers = {}
    local in_response = false

    for line in (raw_headers or ""):gmatch("[^\r\n]+") do
        -- wget -S indents response lines; diagnostics and progress lines are ignored.
        line = line:gsub("^%s+", "")
        if line:match("^HTTP/%d") then
            -- A redirect can produce several response blocks. Keep only the last.
            headers = {}
            in_response = true
        elseif in_response then
            local name, value = line:match("^([^:%s]+)%s*:%s*(.*)$")
            if name then
                name = name:lower()
                if headers[name] then
                    headers[name] = headers[name] .. ", " .. value
                else
                    headers[name] = value
                end
            end
        end
    end

    local metadata = {}
    local title = decode_profile_value(headers["profile-title"])
    if title and title ~= "" then metadata.profile_title = title end

    local support_url = decode_profile_value(headers["support-url"])
    if valid_http_url(support_url) then metadata.support_url = support_url end

    local web_url = decode_profile_value(headers["profile-web-page-url"])
    if valid_http_url(web_url) then metadata.web_page_url = web_url end

    local announce = decode_profile_value(headers["announce"])
    if announce and announce ~= "" and #announce <= MAX_ANNOUNCE_LENGTH then
        metadata.announce = announce
    end

    local userinfo = headers["subscription-userinfo"]
    if userinfo then
        local parsed = {}
        for key, value in userinfo:gmatch("([%w_-]+)%s*=%s*(%d+)") do
            if key == "upload" or key == "download" or key == "total" or key == "expire" then
                parsed[key] = tonumber(value)
            end
        end
        if next(parsed) then metadata.userinfo = parsed end
    end

    return metadata
end

local function save_subscription_metadata(ext_id, new_metadata)
    if not ext_id or ext_id == "" or type(new_metadata) ~= "table" then
        return false, "missing subscription ID or metadata"
    end

    local data = read_subscription_metadata_file()
    local previous = data.subscriptions[ext_id]
    if type(previous) ~= "table" then previous = {} end

    -- Missing or malformed headers do not erase previously known good values.
    for _, key in ipairs({ "profile_title", "support_url", "web_page_url", "announce" }) do
        if type(new_metadata[key]) == "string" and new_metadata[key] ~= "" then
            previous[key] = new_metadata[key]
        end
    end

    if type(new_metadata.userinfo) == "table" then
        if type(previous.userinfo) ~= "table" then previous.userinfo = {} end
        for _, key in ipairs({ "upload", "download", "total", "expire" }) do
            if type(new_metadata.userinfo[key]) == "number" then
                previous.userinfo[key] = new_metadata.userinfo[key]
            end
        end
    end

    previous.updated_at = os.time()
    data.subscriptions[ext_id] = previous

    return write_subscription_metadata_file(data)
end

local function run_command(command)

    local pipe =
        io.popen(
            command ..
            " 2>&1; " ..
            "rc=$?; " ..
            "printf '\\n__XRAY_EXTD_RC__=%s\\n' \"$rc\""
        )

    if not pipe then

        return false,
            "",
            -1
    end

    local output =
        pipe:read("*a") or ""

    pipe:close()

    local rc =
        output:match(
            "__XRAY_EXTD_RC__=(%d+)%s*$"
        )

    rc =
        tonumber(rc) or -1

    output =
        output:gsub(
            "\n__XRAY_EXTD_RC__=%d+%s*$",
            ""
        )

    return (
        rc == 0
    ),
    output,
    rc
end


-- Small runtime-list snapshot consumed by LuCI. The browser must not poll
-- `xray api lso` directly: that call serializes every outbound's full config.
local RUNTIME_LISTS_PATH = "/tmp/xray_extd_runtime_lists.json"
local runtime_lists_state = nil
local runtime_lists_signature = nil
local runtime_lists_generation = 0
local runtime_lists_write_error_logged = false

local RUNTIME_BALANCER_LISTS = {
    {
        field = "tcp_v4",
        prefix = "tcp_balancer_v4@balancer_outbound:"
    },
    {
        field = "tcp_v6",
        prefix = "tcp_balancer_v6@balancer_outbound:"
    },
    {
        field = "udp_v4",
        prefix = "udp_balancer_v4@balancer_outbound:"
    },
    {
        field = "udp_v6",
        prefix = "udp_balancer_v6@balancer_outbound:"
    }
}

local function copy_runtime_list(source)
    local result = {}
    for _, value in ipairs(source or {}) do
        result[#result + 1] = tostring(value)
    end
    return result
end

local function publish_runtime_lists(runtime, force_generation)
    local source = runtime or runtime_lists_state or {}
    local lists = {
        tcp_v4 = copy_runtime_list(source.tcp_v4),
        tcp_v6 = copy_runtime_list(source.tcp_v6),
        udp_v4 = copy_runtime_list(source.udp_v4),
        udp_v6 = copy_runtime_list(source.udp_v6)
    }

    local canonical = {
        tcp_v4 = copy_runtime_list(lists.tcp_v4),
        tcp_v6 = copy_runtime_list(lists.tcp_v6),
        udp_v4 = copy_runtime_list(lists.udp_v4),
        udp_v6 = copy_runtime_list(lists.udp_v6)
    }
    table.sort(canonical.tcp_v4)
    table.sort(canonical.tcp_v6)
    table.sort(canonical.udp_v4)
    table.sort(canonical.udp_v6)

    local signature = cjson.encode(canonical)
    local changed = runtime_lists_signature ~= signature

    if changed or force_generation then
        runtime_lists_generation = runtime_lists_generation + 1
    end

    runtime_lists_signature = signature
    runtime_lists_state = lists

    -- Avoid replacing the small file on every health-check tick. Recreate it
    -- if /tmp was cleaned while the daemon remained alive.
    local existing = io.open(RUNTIME_LISTS_PATH, "r")
    local file_missing = existing == nil
    if existing then
        existing:close()
    end

    if not changed and not force_generation and not file_missing then
        return true
    end

    local payload = cjson.encode({
        generation = runtime_lists_generation,
        updated_at = os.time(),
        tcp_v4 = lists.tcp_v4,
        tcp_v6 = lists.tcp_v6,
        udp_v4 = lists.udp_v4,
        udp_v6 = lists.udp_v6
    })

    if type(payload) ~= "string" then
        if not runtime_lists_write_error_logged then
            print("xray_extd: cannot encode runtime balancer lists snapshot")
            runtime_lists_write_error_logged = true
        end
        return false
    end

    local temp_path = RUNTIME_LISTS_PATH .. ".tmp"
    local file = io.open(temp_path, "w")
    if not file then
        if not runtime_lists_write_error_logged then
            print("xray_extd: cannot open runtime lists snapshot for writing")
            runtime_lists_write_error_logged = true
        end
        return false
    end

    local write_ok = file:write(payload, "\n")
    local close_ok = file:close()
    if not write_ok or close_ok == nil then
        os.remove(temp_path)
        if not runtime_lists_write_error_logged then
            print("xray_extd: cannot write runtime lists snapshot")
            runtime_lists_write_error_logged = true
        end
        return false
    end

    local rename_ok = os.rename(temp_path, RUNTIME_LISTS_PATH)
    if not rename_ok then
        os.remove(temp_path)
        if not runtime_lists_write_error_logged then
            print("xray_extd: cannot atomically publish runtime lists snapshot")
            runtime_lists_write_error_logged = true
        end
        return false
    end

    runtime_lists_write_error_logged = false
    return true
end

local function mark_runtime_list_tag(tag, present)
    if not runtime_lists_state or type(tag) ~= "string" then
        return
    end

    for _, entry in ipairs(RUNTIME_BALANCER_LISTS) do
        if tag:sub(1, #entry.prefix) == entry.prefix then
            local cfg = tag:sub(#entry.prefix + 1)
            if cfg == "" then
                return
            end

            local list = runtime_lists_state[entry.field]
            local found = false
            for i = #list, 1, -1 do
                if list[i] == cfg then
                    found = true
                    if not present then
                        table.remove(list, i)
                    end
                end
            end

            if present and not found then
                list[#list + 1] = cfg
            end

            -- Refresh the generation even if the tag already exists: ado can
            -- replace its settings while preserving the outbound tag.
            publish_runtime_lists(runtime_lists_state, true)
            return
        end
    end
end

local function get_runtime_outbounds()

    local ok, output, rc =
        run_command(
            "/usr/bin/xray api lso " ..
            "--server=127.0.0.1:8080"
        )

    if not ok then

        print(
            "xray_extd: lso failed rc=" ..
            tostring(rc)
        )

        print(
            "xray_extd: lso output: " ..
            output
        )

        return nil
    end


    local success, data =
        pcall(
            cjson.decode,
            output
        )

    if not success then

        print(
            "xray_extd: cannot parse lso JSON"
        )

        print(
            "xray_extd: lso output: " ..
            output
        )

        return nil
    end


    local result = {

        tcp_v4 = {},
        tcp_v6 = {},
        udp_v4 = {},
        udp_v6 = {},

        tags = {}
    }


    for _, outbound in
        ipairs(data.outbounds or {})
    do

        local tag =
            outbound.tag or ""

        result.tags[tag] = true


        local prefix
        local target


        if tag:sub(
            1,
            #("tcp_balancer_v4@balancer_outbound:")
        ) ==
        "tcp_balancer_v4@balancer_outbound:"
        then

            prefix =
                "tcp_balancer_v4@balancer_outbound:"

            target =
                result.tcp_v4


        elseif tag:sub(
            1,
            #("tcp_balancer_v6@balancer_outbound:")
        ) ==
        "tcp_balancer_v6@balancer_outbound:"
        then

            prefix =
                "tcp_balancer_v6@balancer_outbound:"

            target =
                result.tcp_v6


        elseif tag:sub(
            1,
            #("udp_balancer_v4@balancer_outbound:")
        ) ==
        "udp_balancer_v4@balancer_outbound:"
        then

            prefix =
                "udp_balancer_v4@balancer_outbound:"

            target =
                result.udp_v4


        elseif tag:sub(
            1,
            #("udp_balancer_v6@balancer_outbound:")
        ) ==
        "udp_balancer_v6@balancer_outbound:"
        then

            prefix =
                "udp_balancer_v6@balancer_outbound:"

            target =
                result.udp_v6
        end


        if prefix then

            local cfg =
                tag:sub(
                    #prefix + 1
                )

            if cfg ~= "" then

                table.insert(
                    target,
                    cfg
                )
            end
        end
    end


    publish_runtime_lists(result, false)

    return result
end

local function get_observatory_state(obs)
    if not obs then
        return "unknown"
    end

    if obs.alive == true then
        return "live"
    end

    if obs.last_try_time and
       obs.last_try_time > 0 then
        return "dead"
    end

    return "unknown"
end


local function analyze_observatory_list(
    list,
    prefix,
    observatory
)
    local result = {
        total = 0,
        live = 0,
        dead = 0,
        unknown = 0,
        states = {}
    }

    for _, cfg in ipairs(list) do

        local tag =
            prefix .. cfg

        local obs =
            observatory[tag]

        local state =
            get_observatory_state(obs)

        result.total = result.total + 1

        if state == "live" then
            result.live = result.live + 1

        elseif state == "dead" then
            result.dead = result.dead + 1

        else
            result.unknown = result.unknown + 1
        end

        result.states[cfg] = state
    end

    return result
end


local function log_observatory_list(name, result)
    print(
        string.format(
            "xray_extd: %s total=%d live=%d dead=%d unknown=%d",
            name,
            result.total,
            result.live,
            result.dead,
            result.unknown
        )
    )
end


local last_server_states = {}

local function log_server_state_changes(name, result)
    for cfg, state in pairs(result.states) do
        local key = name .. ":" .. cfg
        local previous = last_server_states[key]

        if previous and previous ~= state then
            print(
                string.format(
                    "xray_extd: %s %s %s -> %s",
                    name,
                    cfg,
                    previous,
                    state
                )
            )
        end

        last_server_states[key] = state
    end
end


local function all_servers_dead(result)

    return
        result.total > 0 and
        result.live == 0 and
        result.dead == result.total and
        result.unknown == 0
end


-- ============================================================
-- Состояние групп primary
-- ============================================================

local function get_group_state(result)

    if not result or result.total == 0 then
        return "unknown"
    end

    if all_servers_dead(result) then
        return "dead"
    end

    if result.live > 0 then
        return "available"
    end

    return "unknown"
end

-- Lua-cjson decodes JSON arrays as numeric-keyed tables. Keep array replacement
-- semantics from luci-app-xray's custom_config merge, while merging objects deeply.
local function is_json_array(value)
    if type(value) ~= "table" then
        return false
    end
    if getmetatable(value) ~= nil then
        return true
    end

    local count = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
    end

    return count > 0 and count == maximum
end

local function copy_json_value(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[key] = copy_json_value(item)
    end
    local mt = getmetatable(value)
    if mt then
        setmetatable(result, mt)
    end
    return result
end

local function merge_json_objects(target, source)
    if type(source) ~= "table" or is_json_array(source) then
        return copy_json_value(source)
    end

    if type(target) ~= "table" or is_json_array(target) then
        target = {}
    end

    for key, value in pairs(source) do
        if type(value) == "table" and not is_json_array(value) then
            target[key] = merge_json_objects(target[key], value)
        else
            target[key] = copy_json_value(value)
        end
    end

    return target
end

local function decode_custom_config(value)
    if type(value) == "table" then
        return copy_json_value(value)
    end

    if type(value) ~= "string" or value == "" then
        return {}
    end

    local ok, decoded = pcall(cjson.decode, value)
    if ok and type(decoded) == "table" then
        return decoded
    end

    return {}
end

local function merge_target_custom_config(target, extra)
    local current = decode_custom_config(target.custom_config)
    local additional = decode_custom_config(extra)

    if next(additional) ~= nil then
        current = merge_json_objects(current, additional)
    end

    if next(current) ~= nil then
        target.custom_config = cjson.encode(current)
    else
        target.custom_config = false
    end
end

local function optional_list(value)
    local result = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            if item ~= nil and tostring(item) ~= "" then
                result[#result + 1] = tostring(item)
            end
        end
    elseif value ~= nil and tostring(value) ~= "" then
        result[1] = tostring(value)
    end

    if #result == 0 then
        return false
    end
    return result
end

local function build_outbound(server, list_name)

    if not server then

        print(
            "xray_extd: build_outbound: no server"
        )

        return nil
    end

    if not list_name or list_name == "" then

        print(
            "xray_extd: build_outbound: no list_name"
        )

        return nil
    end


    local cfg =
        server[".name"]

    if not cfg or cfg == "" then

        print(
            "xray_extd: build_outbound: server has no section name"
        )

        return nil
    end


    local protocol =
        server.protocol


    local outbound = {

        tag =
            list_name ..
            "@balancer_outbound:" ..
            cfg,

        protocol =
            protocol,

        settings = {},

        streamSettings = {}
    }



    if protocol == "vless" then

        outbound.settings = {

            address =
                server.server,

            port =
                tonumber(
                    server.server_port
                    and server.server_port[1]
                ),

            id =
                server.password,

            email =
                server.username,

            encryption =
                server.vless_encryption or "none"
        }


        if server.vless_flow_reality then

            outbound.settings.flow =
                server.vless_flow_reality

        elseif server.vless_flow_tls then

            outbound.settings.flow =
                server.vless_flow_tls
        end


    elseif protocol == "shadowsocks" then

        outbound.settings = {

            address =
                server.server,

            port =
                tonumber(
                    server.server_port
                    and server.server_port[1]
                ),

            password =
                server.password,

            method =
                server.shadowsocks_security,

            email = server.username,

            uot = server.shadowsocks_udp_over_tcp == "1"
        }


    elseif protocol == "hysteria" then

        outbound.settings = {

            version = 2,

            address =
                server.server,

            port =
                tonumber(
                    server.server_port
                    and server.server_port[1]
                )
        }


    else

        print(
            "xray_extd: unsupported protocol: " ..
            tostring(protocol) ..
            " cfg=" ..
            tostring(cfg)
        )

        return nil
    end



    if protocol ~= "hysteria" then

        outbound.streamSettings.network =
            server.transport


        if server.transport == "tcp" then


        elseif server.transport == "splithttp" then

            outbound.streamSettings
                .splithttpSettings = {}

            if server.splithttp_path then

                outbound.streamSettings
                    .splithttpSettings.path =
                        server.splithttp_path
            end

            if server.splithttp_host then

                outbound.streamSettings
                    .splithttpSettings.host =
                        server.splithttp_host
            end

        elseif server.transport == "ws" then

            print(
                "xray_extd: WARNING: WS transport "
                .. "is not implemented yet: "
                .. tostring(cfg)
            )

        elseif server.transport == "grpc" then

            print(
                "xray_extd: WARNING: gRPC transport "
                .. "is not implemented yet: "
                .. tostring(cfg)
            )
        end
    end



    if protocol == "vless" then

        if server.vless_tls == "reality" then

            outbound.streamSettings.security =
                "reality"

            outbound.streamSettings.realitySettings = {

                serverName =
                    server.vless_reality_server_name,

                fingerprint =
                    server.vless_reality_fingerprint,

                password =
                    server.vless_reality_public_key,

                shortId =
                    server.vless_reality_short_id,

                show = server.vless_reality_show == "1",

                spiderX = server.vless_reality_spider_x
            }

        elseif server.vless_tls == "tls" then

            outbound.streamSettings.security =
                "tls"

            outbound.streamSettings.tlsSettings = {

                serverName =
                    server.vless_tls_host,

                fingerprint =
                    server.vless_tls_fingerprint,

                alpn =
                    server.vless_tls_alpn,

                allowInsecure =
                    server.vless_tls_insecure == "1"
            }
        end


    elseif protocol == "shadowsocks" then

        if server.shadowsocks_tls == "tls" then

            outbound.streamSettings.security = "tls"
            outbound.streamSettings.tlsSettings = {
                serverName = server.shadowsocks_tls_host,
                fingerprint = server.shadowsocks_tls_fingerprint,
                alpn = server.shadowsocks_tls_alpn,
                allowInsecure = server.shadowsocks_tls_insecure == "1"
            }

        else

            outbound.streamSettings.security = "none"
        end


    elseif protocol == "hysteria" then

        outbound.streamSettings.security =
            "tls"

        outbound.streamSettings.tlsSettings = {

            serverName =
                server.hysteria_tls_host,

            fingerprint =
                server.hysteria_tls_fingerprint,

            alpn =
                server.hysteria_tls_alpn,

            allowInsecure =
                server.hysteria_tls_insecure == "1"
        }

        outbound.streamSettings.hysteriaSettings = {

            version = 2,

            auth =
                server.password
        }

        local hysteria_settings = outbound.streamSettings.hysteriaSettings

        if server.hysteria_up_mbps and server.hysteria_up_mbps ~= "" then
            hysteria_settings.up = tostring(server.hysteria_up_mbps) .. "mbps"
        end

        if server.hysteria_down_mbps and server.hysteria_down_mbps ~= "" then
            hysteria_settings.down = tostring(server.hysteria_down_mbps) .. "mbps"
        end

        if server.hysteria_udphop_port and server.hysteria_udphop_port ~= "" then
            hysteria_settings.udphop = {
                port = server.hysteria_udphop_port,
                interval = tonumber(server.hysteria_udphop_interval) or 30
            }
        end
    end



    outbound.streamSettings.sockopt = {

        domainStrategy =
            server.domain_strategy,

        mark = 253
    }



    if server.custom_config and server.custom_config ~= "" then

        local ok, custom =
            pcall(
                cjson.decode,
                server.custom_config
            )

        if ok and type(custom) == "table" then
            local fixed_tag = outbound.tag
            local fixed_mark = outbound.streamSettings.sockopt.mark

            for key, value in pairs(custom) do
                if key ~= "tag" and key ~= "protocol" then
                    outbound[key] = merge_json_objects(outbound[key], value)
                end
            end

            outbound.tag = fixed_tag
            outbound.streamSettings = type(outbound.streamSettings) == "table"
                and outbound.streamSettings or {}
            outbound.streamSettings.sockopt = type(outbound.streamSettings.sockopt) == "table"
                and outbound.streamSettings.sockopt or {}
            outbound.streamSettings.sockopt.mark = fixed_mark

        else

            print(
                "xray_extd: invalid custom_config: " ..
                tostring(cfg)
            )
        end
    end


    return outbound
end

local function find_server_by_cfg(cfg)

    if not cfg or cfg == "" then
        return nil
    end

    local cursor = uci.cursor()
    local result = nil

    cursor:foreach(
        "xray_core",
        "servers",
        function(server)

            if server[".name"] == cfg then
                result = server
                return false
            end

            return true
        end
    )

    return result
end


-- ============================================================
-- Xray API: текущие outbounds
-- ============================================================

-- ============================================================
-- Проверить наличие outbound по tag
-- ============================================================

local function runtime_has_outbound(tag)
    local runtime = get_runtime_outbounds()

    if not runtime then
        return nil, "runtime state unavailable"
    end

    return runtime.tags[tag] == true, nil
end


-- ============================================================
-- Добавить outbound
-- ============================================================

local function xray_add_outbound(outbound)

    if type(outbound) ~= "table" then
        return false, "invalid outbound"
    end

    if not outbound.tag or outbound.tag == "" then
        return false, "outbound tag is missing"
    end

    local tmp_file =
        "/tmp/xray-ext-ado-" ..
        tostring(os.time()) ..
        ".json"

    local out_file =
        tmp_file .. ".out"

    local payload = {
        outbounds = {
            outbound
        }
    }

    local ok, json =
        pcall(
            cjson.encode,
            payload
        )

    if not ok then
        return false,
            "cannot encode outbound: " ..
            tostring(json)
    end

    local file =
        io.open(
            tmp_file,
            "w"
        )

    if not file then
        return false,
            "cannot create temporary file"
    end

    file:write(json)
    file:close()

    local command =
        "/usr/bin/xray api ado " ..
        "--server=127.0.0.1:8080 " ..
        "'" .. tmp_file .. "' " ..
        ">" .. out_file .. " 2>&1"

    local rc =
        os.execute(command)

    local result_file =
        io.open(
            out_file,
            "r"
        )

    local output = ""

    if result_file then
        output =
            result_file:read("*a") or ""

        result_file:close()
    end

    os.remove(tmp_file)
    os.remove(out_file)

    print(
        "ADO tag=" ..
        outbound.tag ..
        " rc=" ..
        tostring(rc)
    )

    if output ~= "" then
        print(
            "ADO output=" ..
            output
        )
    end

    if rc ~= 0 then
        return false,
            "xray ado failed"
    end

    mark_runtime_list_tag(outbound.tag, true)

    return true, output
end

local function xray_remove_outbound(tag)

    if not tag or tag == "" then

        print(
            "xray_extd: RMO refused: empty tag"
        )

        return false
    end


    local runtime =
        get_runtime_outbounds()

    if not runtime then

        print(
            "xray_extd: RMO cannot check runtime: " ..
            tag
        )

        return false
    end


    if not runtime.tags[tag] then

        print(
            "xray_extd: RMO skip, already absent: " ..
            tag
        )

        return true
    end


    local command =
        "/usr/bin/xray api rmo " ..
        "--server=127.0.0.1:8080 " ..
        shell_quote(tag)


    print(
        "xray_extd: RMO request " ..
        tag
    )


    local ok, output, rc =
        run_command(command)


    print(
        "xray_extd: RMO CLI rc=" ..
        tostring(rc)
    )

    print(
        "xray_extd: RMO CLI output: " ..
        output
    )

    -- Проверяем результат удаления только через lso.

    runtime =
        get_runtime_outbounds()

    if not runtime then

        print(
            "xray_extd: RMO " ..
            tag ..
            " cannot verify runtime"
        )

        return false
    end


    if not runtime.tags[tag] then

        print(
            "xray_extd: RMO VERIFIED " ..
            tag
        )

        return true
    end


    print(
        "xray_extd: RMO FAILED verification " ..
        tag
    )

    return false
end

local function read_xray_config()
    local cursor = uci.cursor()

    local config = {
        metrics_port = "18888",
        server_meta = {},
        subscriptions = {},

        tcp_v4 = {},
        tcp_v6 = {},
        udp_v4 = {},
        udp_v6 = {},

        backup_tcp_v4 = {},
        backup_tcp_v6 = {},
        backup_udp_v4 = {},
        backup_udp_v6 = {},

        -- Defaults for hostname resolution of newly imported VPN servers.
        -- Keep legacy behavior when the xray_ext options are not configured.
        domain_strategy = "UseIP",
        domain_resolve_dns_method = "udp",
        domain_resolve_dns = "",

        -- Optional subscription downloads outside Xray transparent proxying.
        subscription_direct = false,

        -- Confirmation thresholds are configurable in xray_ext.general.
        failover_dead_confirm = 3,
        failover_live_confirm = 9,
        subscription_dead_confirm = 3,
        subscription_live_confirm = 9,
        backup_subscription_dead_confirm = 3,
        backup_subscription_live_confirm = 9
    }

    local server_section_order = 0
    cursor:foreach(
        "xray_core",
        "servers",
        function(section)
            local cfg = section[".name"]
            server_section_order = server_section_order + 1

            if cfg then
                -- Keep a read-only snapshot of this UCI section for update planning.
                -- The planner never writes these values back to UCI. The section
                -- order is retained to match repeated aliases by occurrence index.
                local server_data = {}
                for key, value in pairs(section) do
                    server_data[key] = value
                end
                server_data.cfg = cfg
                server_data._subscription_order = server_section_order
                config.server_meta[cfg] = server_data
            end

            return true
        end
    )

    cursor:foreach(
        "xray_core",
        "general",
        function(section)
            if section.metrics_server_port
               and section.metrics_server_port ~= "" then
                config.metrics_port =
                    section.metrics_server_port
            end

            config.tcp_v4 =
                normalize_list(section.tcp_balancer_v4)

            config.tcp_v6 =
                normalize_list(section.tcp_balancer_v6)

            config.udp_v4 =
                normalize_list(section.udp_balancer_v4)

            config.udp_v6 =
                normalize_list(section.udp_balancer_v6)

            return false
        end
    )

    cursor:foreach(
        "xray_ext",
        "subscription",
        function(section)
            local ext_id = section.ext_id

            if ext_id and ext_id ~= "" then
                config.subscriptions[ext_id] = {
                    ext_id = ext_id,
                    name = section.name or ext_id,
                    role = section.role == "backup"
                        and "backup"
                        or "primary",
                    enabled = section.enabled ~= "0",
                    interval = section.interval or "360",
                    last_update = tonumber(section.last_update) or 0,
                    url = section.url or "",
                    add_new = section.add_new ~= "0",
                    auto_remove = section.auto_remove == "1"
                }
            end

            return true
        end
    )

    cursor:foreach(
        "xray_ext",
        "general",
        function(section)
            config.backup_tcp_v4 =
                normalize_list(section.tcp_balancer_v4)

            config.backup_tcp_v6 =
                normalize_list(section.tcp_balancer_v6)

            config.backup_udp_v4 =
                normalize_list(section.udp_balancer_v4)

            config.backup_udp_v6 =
                normalize_list(section.udp_balancer_v6)

            if section.domain_strategy and section.domain_strategy ~= "" then
                config.domain_strategy = section.domain_strategy
            end

            if section.domain_resolve_dns_method
               and section.domain_resolve_dns_method ~= "" then
                config.domain_resolve_dns_method =
                    section.domain_resolve_dns_method
            end

            if section.domain_resolve_dns
               and section.domain_resolve_dns ~= "" then
                config.domain_resolve_dns = section.domain_resolve_dns
            end

            config.subscription_direct = section.subscription_direct == "1"

            config.failover_dead_confirm = positive_integer(
                section.failover_dead_confirm, config.failover_dead_confirm
            )
            config.failover_live_confirm = positive_integer(
                section.failover_live_confirm, config.failover_live_confirm
            )
            config.subscription_dead_confirm = positive_integer(
                section.subscription_dead_confirm, config.subscription_dead_confirm
            )
            config.subscription_live_confirm = positive_integer(
                section.subscription_live_confirm, config.subscription_live_confirm
            )
            config.backup_subscription_dead_confirm = positive_integer(
                section.backup_subscription_dead_confirm,
                config.backup_subscription_dead_confirm
            )
            config.backup_subscription_live_confirm = positive_integer(
                section.backup_subscription_live_confirm,
                config.backup_subscription_live_confirm
            )

            return false
        end
    )

    return config
end

-- Create a stable fingerprint from UCI server fields. It allows the daemon to
-- rebuild a probe outbound after subscription parameters change or daemon restart.
local function backup_probe_fingerprint(server)
    local keys = {}
    for key in pairs(server or {}) do
        if type(key) == "string"
           and key:sub(1, 1) ~= "."
           and key ~= "cfg" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        local value = server[key]
        if type(value) == "table" then
            local values = {}
            for i, item in ipairs(value) do
                values[#values + 1] = tostring(item or "")
            end
            value = table.concat(values, "\31")
        else
            value = tostring(value or "")
        end
        parts[#parts + 1] = key .. "\30" .. value
    end

    return table.concat(parts, "\29")
end

local function backup_probe_log_limited(key, message, now)
    local last = backup_probe_last_log[key] or 0
    if now - last >= 30 then
        print("xray_extd: " .. message)
        backup_probe_last_log[key] = now
    end
end

-- Reconcile the backup TCP IPv4 probe list. These probe outbounds are used to
-- derive each backup subscription's health; they are never inserted into the
-- user-facing balancers.
local function reconcile_backup_tcp_v4_probes(config, now)
    now = now or os.time()

    local desired_servers = {}
    local desired_tags = {}
    local desired_cfgs = {}

    for _, value in ipairs(config.backup_tcp_v4 or {}) do
        local cfg = tostring(value)
        local server = config.server_meta[cfg]

        if server and tostring(server.subscription_missing or "") ~= "1" then
            if not desired_servers[cfg] then
                desired_servers[cfg] = server
                desired_tags[BACKUP_PROBE_TCP_V4_PREFIX .. cfg] = true
                desired_cfgs[#desired_cfgs + 1] = cfg
            end
            backup_probe_missing_logged[cfg] = nil
        elseif server then
            if not backup_probe_missing_logged[cfg] then
                print("xray_extd: BACKUP PROBE SKIP missing server cfg=" .. cfg)
                backup_probe_missing_logged[cfg] = true
            end
        else
            backup_probe_log_limited(
                "missing-section:" .. cfg,
                "BACKUP PROBE SKIP server section not found cfg=" .. cfg,
                now
            )
        end
    end

    table.sort(desired_cfgs)

    local runtime = get_runtime_outbounds()
    if not runtime then
        backup_probe_log_limited(
            "runtime-unavailable",
            "BACKUP PROBE reconcile deferred: runtime outbounds unavailable",
            now
        )
        return desired_cfgs
    end

    -- Remove only daemon-managed probe tags whose suffix is a real UCI cfg ID.
    -- Manually created test tags such as *_test are intentionally left untouched.
    for tag, _ in pairs(runtime.tags) do
        local cfg = tag:match("^extra_inbound_backup_tcp_v4:(cfg[%w]+)$")
        if cfg and not desired_tags[tag] then
            if now >= (backup_probe_retry_after[tag] or 0) then
                local removed = xray_remove_outbound(tag)
                if removed then
                    runtime.tags[tag] = nil
                    backup_probe_fingerprints[cfg] = nil
                    backup_probe_retry_after[tag] = nil
                    backup_probe_last_log[tag] = nil
                    print("xray_extd: BACKUP PROBE RMO OK tag=" .. tag)
                else
                    backup_probe_retry_after[tag] = now + 10
                    backup_probe_log_limited(
                        tag,
                        "BACKUP PROBE RMO PENDING tag=" .. tag,
                        now
                    )
                end
            end
        end
    end

    for _, cfg in ipairs(desired_cfgs) do
        local server = desired_servers[cfg]
        local tag = BACKUP_PROBE_TCP_V4_PREFIX .. cfg

        if now >= (backup_probe_retry_after[tag] or 0) then
            local fingerprint = backup_probe_fingerprint(server)
            local exists = runtime.tags[tag] == true
            local rebuild = exists and backup_probe_fingerprints[cfg] ~= fingerprint
            local can_add = not exists

            if rebuild then
                local removed = xray_remove_outbound(tag)
                if removed then
                    runtime.tags[tag] = nil
                    backup_probe_fingerprints[cfg] = nil
                    can_add = true
                else
                    backup_probe_retry_after[tag] = now + 10
                    backup_probe_log_limited(
                        tag,
                        "BACKUP PROBE REBUILD pending RMO tag=" .. tag,
                        now
                    )
                end
            end

            if can_add then
                local outbound = build_outbound(server, "tcp_balancer_v4")
                if outbound then
                    outbound.tag = tag
                    local added, add_error = xray_add_outbound(outbound)
                    if added then
                        local verified, verify_error = runtime_has_outbound(tag)
                        if verified == true then
                            runtime.tags[tag] = true
                            backup_probe_fingerprints[cfg] = fingerprint
                            backup_probe_retry_after[tag] = nil
                            backup_probe_last_log[tag] = nil
                            print("xray_extd: BACKUP PROBE ADO VERIFIED tag=" .. tag)
                        else
                            backup_probe_retry_after[tag] = now + 10
                            backup_probe_log_limited(
                                tag,
                                "BACKUP PROBE ADO verification pending tag=" .. tag ..
                                    " reason=" .. tostring(verify_error),
                                now
                            )
                        end
                    else
                        backup_probe_retry_after[tag] = now + 10
                        backup_probe_log_limited(
                            tag,
                            "BACKUP PROBE ADO pending tag=" .. tag ..
                                " reason=" .. tostring(add_error),
                            now
                        )
                    end
                else
                    backup_probe_retry_after[tag] = now + 60
                    backup_probe_log_limited(
                        tag,
                        "BACKUP PROBE cannot build outbound tag=" .. tag,
                        now
                    )
                end
            end
        end
    end

    return desired_cfgs
end

-- ============================================================
-- Состояние failover
-- ============================================================

local failover_active = {
    tcp_v4 = false,
    tcp_v6 = false,
    udp_v4 = false,
    udp_v6 = false
}

local failover_tags = {
    tcp_v4 = {},
    tcp_v6 = {},
    udp_v4 = {},
    udp_v6 = {}
}

local last_group_states = {
    tcp_v4 = nil,
    tcp_v6 = nil,
    udp_v4 = nil,
    udp_v6 = nil
}

local group_dead_confirmed = {
    tcp_v4 = false,
    tcp_v6 = false,
    udp_v4 = false,
    udp_v6 = false
}

local group_dead_streak = {
    tcp_v4 = 0,
    tcp_v6 = 0,
    udp_v4 = 0,
    udp_v6 = 0
}

local group_live_streak = {
    tcp_v4 = 0,
    tcp_v6 = 0,
    udp_v4 = 0,
    udp_v6 = 0
}

local FAILOVER_DEAD_CONFIRM = 3
local FAILOVER_LIVE_CONFIRM = 9


-- ============================================================
-- Состояние отдельных подписок
-- ============================================================

local last_subscription_states = {}
local subscription_dead_streak = {}
local subscription_live_streak = {}
local subscription_dead_confirmed = {}

local SUBSCRIPTION_DEAD_CONFIRM = 3
local SUBSCRIPTION_LIVE_CONFIRM = 9

local pending_update_requests = {}
local scheduled_update_requests = {}
local last_subscription_fetch = {}

-- Manual refresh is queued by the daemon's ubus API and processed by the
-- existing subscription update pipeline from the normal heartbeat.
local MANUAL_REFRESH_REASON = "manual_refresh"
local manual_refresh_requested = false
local manual_refresh_targets = {}
local manual_refresh_status = {
    state = "idle",
    message = "No manual refresh requested",
    requested_at = 0,
    started_at = 0,
    finished_at = 0,
    total = 0,
    completed = 0,
    succeeded = 0,
    failed = 0
}

local AUTO_UPDATE_DELAY = 5 * 60
local UPDATE_RETRY_DELAY = 5 * 60


local function subscription_can_auto_update(sub, role)
    return
        sub and
        sub.enabled and
        sub.interval == "auto" and
        sub.role == role
end


local function subscription_can_manual_update(sub, role)
    return
        sub and
        sub.enabled and
        sub.role == role
end


local function queue_update_request(
    config,
    ext_id,
    reason,
    role,
    delay
)
    local sub = config.subscriptions[ext_id]

    local allowed =
        (reason == MANUAL_REFRESH_REASON and
            subscription_can_manual_update(sub, role)) or
        subscription_can_auto_update(sub, role)

    if not allowed then
        return false
    end

    delay = tonumber(delay) or 0

    if delay > 0 then
        local request =
            scheduled_update_requests[ext_id]

        if not request then
            request = {
                ext_id = ext_id,
                name = sub.name,
                role = sub.role,
                reasons = {},
                due_at = os.time() + delay
            }

            scheduled_update_requests[ext_id] = request
        end

        request.reasons[reason] = true

        local due_at = os.time() + delay
        if due_at < request.due_at then
            request.due_at = due_at
        end

        return true
    end

    local request =
        pending_update_requests[ext_id]

    if not request then
        request = {
            ext_id = ext_id,
            name = sub.name,
            role = sub.role,
            reasons = {}
        }

        pending_update_requests[ext_id] = request
    end

    request.reasons[reason] = true

    -- An explicit manual refresh supersedes a delayed retry for the same
    -- subscription. Carry its reasons into the immediate request so no work
    -- is lost and the subscription is not fetched twice unnecessarily.
    if reason == MANUAL_REFRESH_REASON then
        local scheduled = scheduled_update_requests[ext_id]
        if scheduled then
            for scheduled_reason, _ in pairs(scheduled.reasons) do
                request.reasons[scheduled_reason] = true
            end
            scheduled_update_requests[ext_id] = nil
        end
    end

    return true
end


local function cancel_scheduled_update_reason(
    ext_id,
    reason
)
    local request = scheduled_update_requests[ext_id]

    if not request then
        return
    end

    request.reasons[reason] = nil

    if next(request.reasons) == nil then
        scheduled_update_requests[ext_id] = nil
    end
end


local function promote_due_update_requests(now)
    for ext_id, request in pairs(scheduled_update_requests) do
        if request.due_at <= now then
            local pending = pending_update_requests[ext_id]

            if not pending then
                pending = {
                    ext_id = request.ext_id,
                    name = request.name,
                    role = request.role,
                    reasons = {}
                }

                pending_update_requests[ext_id] = pending
            end

            for reason, _ in pairs(request.reasons) do
                pending.reasons[reason] = true
            end

            scheduled_update_requests[ext_id] = nil
        end
    end
end


local function queue_updates_for_subscription_ids(
    config,
    ext_ids,
    reason,
    role,
    delay
)
    for ext_id, _ in pairs(ext_ids or {}) do
        queue_update_request(
            config,
            ext_id,
            reason,
            role,
            delay
        )
    end
end


local function queue_manual_refreshes(config)
    if not manual_refresh_requested then
        return
    end

    manual_refresh_requested = false
    manual_refresh_targets = {}

    manual_refresh_status.state = "running"
    manual_refresh_status.message = "Manual subscription refresh in progress"
    manual_refresh_status.started_at = os.time()
    manual_refresh_status.finished_at = 0
    manual_refresh_status.total = 0
    manual_refresh_status.completed = 0
    manual_refresh_status.succeeded = 0
    manual_refresh_status.failed = 0

    local ext_ids = {}
    for ext_id, sub in pairs(config.subscriptions or {}) do
        if sub and sub.enabled then
            table.insert(ext_ids, tostring(ext_id))
        end
    end
    table.sort(ext_ids)

    for _, ext_id in ipairs(ext_ids) do
        local sub = config.subscriptions[ext_id]
        if queue_update_request(
            config,
            ext_id,
            MANUAL_REFRESH_REASON,
            sub.role,
            0
        ) then
            manual_refresh_targets[ext_id] = true
            manual_refresh_status.total = manual_refresh_status.total + 1
        end
    end

    print(
        "xray_extd: MANUAL REFRESH queued subscriptions=" ..
        tostring(manual_refresh_status.total)
    )

    if manual_refresh_status.total == 0 then
        manual_refresh_status.state = "done"
        manual_refresh_status.message = "No enabled subscriptions to refresh"
        manual_refresh_status.finished_at = os.time()
    end
end


local function finish_manual_refresh_target(ext_id, success)
    if not manual_refresh_targets[ext_id] then
        return
    end

    manual_refresh_targets[ext_id] = nil
    manual_refresh_status.completed = manual_refresh_status.completed + 1

    if success then
        manual_refresh_status.succeeded = manual_refresh_status.succeeded + 1
    else
        manual_refresh_status.failed = manual_refresh_status.failed + 1
    end
end


local function finish_manual_refresh_if_complete()
    if manual_refresh_status.state ~= "running" then
        return
    end

    if manual_refresh_status.completed < manual_refresh_status.total then
        return
    end

    manual_refresh_status.state =
        manual_refresh_status.failed > 0 and "done_with_errors" or "done"
    manual_refresh_status.finished_at = os.time()
    manual_refresh_status.message =
        "Manual refresh finished: " ..
        tostring(manual_refresh_status.succeeded) .. " succeeded, " ..
        tostring(manual_refresh_status.failed) .. " failed"

    manual_refresh_targets = {}
    print("xray_extd: " .. manual_refresh_status.message)
end


-- ============================================================
-- Dry-run planner: compare subscription records with UCI snapshots.
-- This block is deliberately read-only. It only reports what a future
-- apply step would add/update/leave unchanged; it never invokes UCI set/delete.
-- ============================================================

local VLESS_FIELDS = {
    "vless_tls",
    "vless_encryption",
    "vless_tls_host",
    "vless_tls_insecure",
    "vless_tls_fingerprint",
    "vless_flow_tls",
    "vless_tls_alpn",
    "vless_reality_public_key",
    "vless_reality_short_id",
    "vless_reality_server_name",
    "vless_reality_fingerprint",
    "vless_flow_reality",
    "vless_reality_show",
    "vless_reality_spider_x",
    "splithttp_path",
    "splithttp_host"
}

local HYSTERIA_FIELDS = {
    "hysteria_tls",
    "hysteria_tls_host",
    "hysteria_tls_insecure",
    "hysteria_tls_fingerprint",
    "hysteria_tls_alpn",
    "hysteria_up_mbps",
    "hysteria_down_mbps",
    "hysteria_udphop_port",
    "hysteria_udphop_interval"
}

local SHADOWSOCKS_FIELDS = {
    "shadowsocks_security",
    "shadowsocks_tls",
    "shadowsocks_tls_host",
    "shadowsocks_tls_insecure",
    "shadowsocks_tls_fingerprint",
    "shadowsocks_tls_alpn",
    "shadowsocks_udp_over_tcp",
    "tcp_guise"
}

local function clear_fields(target, fields)
    for _, field in ipairs(fields) do
        target[field] = false
    end
end

local function optional_value(value)
    if value == nil or tostring(value) == "" then
        return false
    end
    return tostring(value)
end

local function deep_equal(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not deep_equal(value, b[key]) then
            return false
        end
    end
    for key, _ in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

local function json_equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    local ok_a, value_a = pcall(cjson.decode, a)
    local ok_b, value_b = pcall(cjson.decode, b)
    return ok_a and ok_b and deep_equal(value_a, value_b)
end

local function present(value)
    if value == nil or value == "" then
        return false
    end
    if type(value) == "table" then
        return #value > 0 or next(value) ~= nil
    end
    return true
end

local function list_equal(expected, actual)
    local left = normalize_list(expected)
    local right = normalize_list(actual)
    if #left ~= #right then
        return false
    end
    for i = 1, #left do
        if tostring(left[i]) ~= tostring(right[i]) then
            return false
        end
    end
    return true
end

local function build_subscription_target(server)
    local target = {
        server = tostring(server.server),
        server_port = { tostring(server.port) },
        password = tostring(server.password),
        protocol = tostring(server.protocol),
        transport = tostring(server.transport.type)
    }

    local domain_strategy = trim(server.domain_strategy)
    if domain_strategy ~= "" then
        target.domain_strategy = domain_strategy
    end

    if server.protocol == "vless" then
        clear_fields(target, HYSTERIA_FIELDS)
        clear_fields(target, SHADOWSOCKS_FIELDS)
        clear_fields(target, VLESS_FIELDS)
        merge_target_custom_config(target, server.custom_config)
        target.username = optional_value(server.username)
        target.vless_encryption = optional_value(server.vless_encryption)

        local tls = server.tls or {}
        local security = tostring(tls.mode or server.security or "none")

        if security == "reality" then
            target.vless_tls = "reality"
            target.vless_reality_public_key = optional_value(tls.public_key)
            target.vless_reality_short_id = optional_value(tls.short_id)
            target.vless_reality_server_name = optional_value(tls.server_name)
            target.vless_reality_fingerprint = optional_value(tls.fingerprint)
            target.vless_flow_reality = optional_value(tls.flow)
            target.vless_reality_show = optional_value(tls.show)
            target.vless_reality_spider_x = optional_value(tls.spider_x)
        elseif security == "tls" then
            target.vless_tls = "tls"
            target.vless_tls_host = optional_value(tls.server_name)
            target.vless_tls_insecure = optional_value(tls.insecure)
            target.vless_tls_fingerprint = optional_value(tls.fingerprint)
            target.vless_flow_tls = optional_value(tls.flow)
            target.vless_tls_alpn = optional_list(tls.alpn)
        elseif security ~= "none" and security ~= "" then
            return nil, "unsupported VLESS security mode: " .. security
        end

        local transport = server.transport or {}

        -- tcp_guise belongs to TCP transport only. For TCP feeds without an
        -- explicit disguise setting, preserve the established default "none".
        -- On XHTTP/other transports, false means stale legacy UCI values should
        -- eventually be removed by the apply step.
        if transport.type == "tcp" then
            target.tcp_guise = "none"
        else
            target.tcp_guise = false
        end

        if transport.type == "splithttp" then
            local split_settings = {}
            local mode = tostring(transport.mode or "")

            -- mode is meaningful only under splithttpSettings. Ignore a mode
            -- accidentally attached to a TCP URI.
            if mode ~= "" then
                local supported_modes = {
                    auto = true,
                    ["packet-up"] = true,
                    ["stream-up"] = true,
                    ["stream-one"] = true
                }
                if not supported_modes[mode] then
                    return nil, "unsupported SplitHTTP mode for alias " .. tostring(server.alias)
                end
                split_settings.mode = mode
            end

            if transport.extra and transport.extra ~= "" then
                local ok_extra, extra = pcall(cjson.decode, transport.extra)
                if not ok_extra or type(extra) ~= "table" then
                    return nil, "SplitHTTP extra is not valid JSON object for alias " .. tostring(server.alias)
                end
                split_settings.extra = extra
            end

            if next(split_settings) ~= nil then
                merge_target_custom_config(target, {
                    streamSettings = {
                        splithttpSettings = split_settings
                    }
                })
            end

            -- Path and host are first-class SplitHTTP options.
            target.splithttp_path = optional_value(transport.path)
            target.splithttp_host = optional_value(transport.host)
        end

    elseif server.protocol == "hysteria" then
        clear_fields(target, VLESS_FIELDS)
        clear_fields(target, SHADOWSOCKS_FIELDS)
        merge_target_custom_config(target, server.custom_config)
        target.username = false

        local tls = server.tls or {}
        local hysteria = server.hysteria or {}
        target.hysteria_tls = "tls"
        target.hysteria_tls_host = optional_value(tls.server_name)
        target.hysteria_tls_insecure = optional_value(tls.insecure)
        target.hysteria_tls_fingerprint = optional_value(tls.fingerprint)
        target.hysteria_tls_alpn = optional_list(tls.alpn)
        target.hysteria_up_mbps = optional_value(hysteria.up_mbps)
        target.hysteria_down_mbps = optional_value(hysteria.down_mbps)
        target.hysteria_udphop_port = optional_value(hysteria.udphop_port)
        target.hysteria_udphop_interval = optional_value(hysteria.udphop_interval)

        if hysteria.finalmask ~= nil then
            merge_target_custom_config(target, {
                streamSettings = {
                    finalmask = hysteria.finalmask
                }
            })
        end

    elseif server.protocol == "shadowsocks" then
        clear_fields(target, VLESS_FIELDS)
        clear_fields(target, HYSTERIA_FIELDS)
        merge_target_custom_config(target, server.custom_config)
        local tls = server.tls or {}
        target.shadowsocks_security = tostring(server.security)
        target.shadowsocks_tls = tostring(tls.mode or "none")
        target.shadowsocks_tls_host = optional_value(tls.server_name)
        target.shadowsocks_tls_insecure = optional_value(tls.insecure)
        target.shadowsocks_tls_fingerprint = optional_value(tls.fingerprint)
        target.shadowsocks_tls_alpn = optional_list(tls.alpn)
        target.shadowsocks_udp_over_tcp = optional_value(server.shadowsocks_udp_over_tcp)
        target.username = optional_value(server.username)
        target.tcp_guise = "none"

    else
        return nil, "unsupported parsed protocol: " .. tostring(server.protocol)
    end

    return target
end

local function field_matches(field, expected, actual)
    if expected == false then
        return not present(actual)
    end

    if field == "server_port" or field == "vless_tls_alpn"
       or field == "hysteria_tls_alpn" or field == "shadowsocks_tls_alpn" then
        return list_equal(expected, actual)
    end

    if field == "custom_config" then
        return json_equal(expected, actual)
    end

    if type(actual) == "table" then
        if #actual == 1 then
            actual = actual[1]
        else
            return false
        end
    end

    return tostring(actual or "") == tostring(expected)
end

local function normalize_alias(value)
    return tostring(value or "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function plan_subscription_update(config, ext_id, sub, result)
    local by_alias = {}

    -- An alias is not necessarily unique: providers often publish several
    -- servers with the same remark (for example, multiple "Italy" entries).
    -- Keep each subscription-owned server in UCI section order. The Nth
    -- occurrence in the feed is matched to the Nth existing occurrence.
    for cfg, meta in pairs(config.server_meta or {}) do
        if tostring(meta.ext_id or "") == tostring(ext_id)
           and meta.alias and meta.alias ~= "" then
            local alias = normalize_alias(meta.alias)
            by_alias[alias] = by_alias[alias] or {}
            by_alias[alias][#by_alias[alias] + 1] = meta
        end
    end

    for _, group in pairs(by_alias) do
        table.sort(group, function(a, b)
            local a_order = tonumber(a._subscription_order) or math.huge
            local b_order = tonumber(b._subscription_order) or math.huge
            if a_order ~= b_order then
                return a_order < b_order
            end
            return tostring(a.cfg or "") < tostring(b.cfg or "")
        end)
    end

    local plan = {
        add = 0,
        update = 0,
        unchanged = 0,
        skipped = 0,
        missing = 0,
        clear_missing = 0,
        mark_missing = 0,
        already_missing = 0,
        delete = 0,
        missing_guarded = false,
        missing_mode = "none",
        missing_details = {},
        rows = {}
    }
    local seen_aliases = {}

    for _, server in ipairs(result.parsed_servers or {}) do
        local alias = normalize_alias(server.alias)
        if alias == "" then
            return nil, "parsed server has an empty alias"
        end

        -- alias_index is the occurrence number among servers with this alias.
        -- Parsers also expose it for diagnostics, but derive it here as a guard
        -- so every parser follows the same matching rule.
        local previous_index = seen_aliases[alias] or 0
        local alias_index = tonumber(server.alias_index)
        if not alias_index
           or alias_index < 1
           or alias_index ~= math.floor(alias_index)
           or alias_index <= previous_index then
            alias_index = previous_index + 1
        end
        seen_aliases[alias] = alias_index

        -- Validate representation even when this server would be skipped.
        local target, target_error = build_subscription_target(server)
        if not target then
            return nil, target_error
        end
        -- A returned server clears the soft-missing marker. This metadata-only
        -- change does not require an Xray outbound rebuild by itself.
        target.subscription_missing = false

        local existing_group = by_alias[alias] or {}
        local alias_count = tonumber(server.alias_count) or alias_index
        local current = existing_group[alias_index]
        if not current then
            if sub.add_new then
                plan.add = plan.add + 1
                plan.rows[#plan.rows + 1] = {
                    action = "add",
                    alias = alias,
                    alias_index = alias_index,
                    alias_count = alias_count,
                    fields = {},
                    target = target,
                    server = server
                }
            else
                plan.skipped = plan.skipped + 1
                plan.rows[#plan.rows + 1] = {
                    action = "skip",
                    alias = alias,
                    alias_index = alias_index,
                    alias_count = alias_count,
                    fields = {}
                }
            end
        else
            local changed = {}
            local requires_runtime_sync = false
            for field, expected in pairs(target) do
                if not field_matches(field, expected, current[field]) then
                    changed[#changed + 1] = field
                    if field ~= "subscription_missing" then
                        requires_runtime_sync = true
                    end
                end
            end
            table.sort(changed)

            if #changed > 0 then
                plan.update = plan.update + 1
                for _, field in ipairs(changed) do
                    if field == "subscription_missing" then
                        plan.clear_missing = plan.clear_missing + 1
                        break
                    end
                end
                plan.rows[#plan.rows + 1] = {
                    action = "update",
                    alias = alias,
                    alias_index = alias_index,
                    alias_count = alias_count,
                    fields = changed,
                    section = current.cfg,
                    target = target,
                    server = server,
                    requires_runtime_sync = requires_runtime_sync
                }
            else
                plan.unchanged = plan.unchanged + 1
            end
        end
    end

    -- A feed is allowed to declare a server absent only if the parser confirmed
    -- that the entire input was understood. Partial/unknown feeds may still
    -- update recognized entries, but never mark or delete missing entries.
    local missing_aliases = {}
    for alias, existing_group in pairs(by_alias) do
        local parsed_count = seen_aliases[alias] or 0
        for alias_index = parsed_count + 1, #existing_group do
            missing_aliases[#missing_aliases + 1] = {
                alias = alias,
                alias_index = alias_index,
                alias_count = #existing_group,
                current = existing_group[alias_index]
            }
        end
    end
    table.sort(missing_aliases, function(a, b)
        if a.alias ~= b.alias then
            return a.alias < b.alias
        end
        return a.alias_index < b.alias_index
    end)
    plan.missing = #missing_aliases

    if result.safe_to_remove == true then
        if #missing_aliases > 0 then
            plan.missing_mode = sub.auto_remove and "delete" or "mark"
        end
        for _, item in ipairs(missing_aliases) do
            local alias = item.alias
            local current = item.current

            if sub.auto_remove then
                plan.delete = plan.delete + 1
                plan.missing_details[#plan.missing_details + 1] = {
                    action = "delete",
                    alias = alias,
                    alias_index = item.alias_index,
                    alias_count = item.alias_count,
                    section = current.cfg
                }
                plan.rows[#plan.rows + 1] = {
                    action = "delete",
                    alias = alias,
                    alias_index = item.alias_index,
                    alias_count = item.alias_count,
                    section = current.cfg,
                    fields = { "server_section", "balancer_refs", "runtime_outbounds" }
                }
            elseif tostring(current.subscription_missing or "") ~= "1" then
                plan.mark_missing = plan.mark_missing + 1
                plan.missing_details[#plan.missing_details + 1] = {
                    action = "mark_missing",
                    alias = alias,
                    alias_index = item.alias_index,
                    alias_count = item.alias_count,
                    section = current.cfg
                }
                plan.rows[#plan.rows + 1] = {
                    action = "mark_missing",
                    alias = alias,
                    alias_index = item.alias_index,
                    alias_count = item.alias_count,
                    section = current.cfg,
                    fields = { "subscription_missing" },
                    target = { subscription_missing = "1" }
                }
            else
                plan.already_missing = plan.already_missing + 1
                plan.missing_details[#plan.missing_details + 1] = {
                    action = "already_marked",
                    alias = alias,
                    alias_index = item.alias_index,
                    alias_count = item.alias_count,
                    section = current.cfg
                }
            end
        end
    elseif #missing_aliases > 0 then
        plan.missing_guarded = true
        plan.missing_mode = "blocked_unsafe_parse"
        for _, item in ipairs(missing_aliases) do
            plan.missing_details[#plan.missing_details + 1] = {
                action = "blocked_unsafe_parse",
                alias = item.alias,
                alias_index = item.alias_index,
                alias_count = item.alias_count,
                section = item.current.cfg
            }
        end
    end

    return plan
end

local function fetch_and_parse_subscription(sub, config)
    if not subscription_parser and not subscription_json_parser then
        return false, "subscription parsers are unavailable"
    end

    if not sub or not sub.url or sub.url == "" then
        return false, "subscription URL is empty"
    end

    -- Keep wget's HTTP headers separate from the response body. Never log the URL:
    -- subscription URLs may contain access tokens.
    local headers_path = os.tmpname()
    if not headers_path or headers_path == "" then
        return false, "cannot allocate temporary headers file"
    end
    os.remove(headers_path)

    local wget_command =
        "/usr/bin/wget -S -T 20 -t 1 -O - " ..
        shell_quote(sub.url)

    if config and config.subscription_direct then
        -- UID 666 (xrayext) is permanently excluded from Xray TProxy by
        -- xray_core.general.uids_direct. Only this wget invocation runs as it.
        wget_command = "/sbin/start-stop-daemon -S -c xrayext:xrayext " ..
            "-x /usr/bin/wget -- --no-hsts -S -T 20 -t 1 -O - " ..
            shell_quote(sub.url)
    end

    local command = wget_command .. " 2>" .. shell_quote(headers_path)

    local pipe, popen_error = io.popen(command, "r")
    if not pipe then
        os.remove(headers_path)
        return false, "cannot start wget: " .. tostring(popen_error)
    end

    local body = pipe:read("*a") or ""
    local close_ok, close_reason, close_code = pipe:close()

    local header_file = io.open(headers_path, "r")
    local raw_headers = ""
    if header_file then
        raw_headers = header_file:read("*a") or ""
        header_file:close()
    end
    os.remove(headers_path)

    if body == "" then
        return false, "wget returned an empty response"
    end

    if close_ok == nil or close_ok == false then
        return false, "wget failed: " .. tostring(close_reason or "") ..
            " " .. tostring(close_code or "")
    end

    local body_probe = body:gsub("^\239\187\191", ""):match("^%s*(.)")
    local selected_parser
    if body_probe == "[" or body_probe == "{" then
        selected_parser = subscription_json_parser
        if not selected_parser then
            return false, "JSON subscription parser is unavailable"
        end
    else
        selected_parser = subscription_parser
        if not selected_parser then
            return false, "subscription parser is unavailable"
        end
    end

    local servers, info_or_error = selected_parser.parse(body)
    if not servers then
        return false, "parser rejected feed: " .. tostring(info_or_error)
    end

    local info = info_or_error or {}
    if #servers == 0 then
        return false, "parser returned zero supported servers"
    end

    return true, {
        bytes = #body,
        server_count = #servers,
        parsed_servers = servers,
        format = tostring(info.format or "unknown"),
        unsupported = tonumber(info.unsupported) or 0,
        ignored = tonumber(info.ignored) or 0,
        safe_to_remove = info.safe_to_remove == true,
        metadata = parse_subscription_response_headers(raw_headers)
    }
end

-- ============================================================
-- Apply planned subscription changes, including safe missing-server handling.
-- ============================================================

local UPDATE_LIST_FIELDS = {
    server_port = true,
    vless_tls_alpn = true,
    hysteria_tls_alpn = true,
    shadowsocks_tls_alpn = true
}

local pending_runtime_rebuilds = {}
local process_pending_runtime_rebuilds
local pending_runtime_removals = {}
local process_pending_runtime_removals

local function set_target_fields(cursor, section, target)
    for field, value in pairs(target) do
        if value == false then
            -- false in the target means that the old protocol/transport field
            -- must be removed, not stored as the string "false".
            cursor:delete("xray_core", section, field)

        elseif UPDATE_LIST_FIELDS[field] then
            -- libuci Lua cursor has set(), not add_list(). Passing a table
            -- to set() writes the complete UCI list value in one operation.
            local list_value = {}
            for _, item in ipairs(value) do
                list_value[#list_value + 1] = tostring(item)
            end

            local ok, err = cursor:set(
                "xray_core", section, field, list_value
            )
            if not ok then
                error("cannot write list field " .. field .. ": " .. tostring(err))
            end

        elseif type(value) == "string" or type(value) == "number" then
            local ok, err = cursor:set(
                "xray_core", section, field, tostring(value)
            )
            if not ok then
                error("cannot write field " .. field .. ": " .. tostring(err))
            end

        else
            error("unsupported target value for field " .. field)
        end
    end
end


local function find_subscription_section(ext_id)
    local cursor = uci.cursor()
    local found = nil
    local count = 0

    cursor:foreach("xray_ext", "subscription", function(section)
        if tostring(section.ext_id or "") == tostring(ext_id) then
            found = section[".name"]
            count = count + 1
        end
        return true
    end)

    if count ~= 1 or not found then
        return nil, "expected exactly one subscription section for ext_id " .. tostring(ext_id)
    end

    return found
end


local function save_subscription_last_update(ext_id, timestamp)
    local section, find_error = find_subscription_section(ext_id)
    if not section then
        return false, find_error
    end

    local cursor = uci.cursor()
    local ok, err = cursor:set(
        "xray_ext", section, "last_update", tostring(timestamp)
    )
    if not ok then
        return false, "cannot set last_update: " .. tostring(err)
    end

    local committed, commit_error = cursor:commit("xray_ext")
    if not committed then
        return false, "cannot commit xray_ext last_update: " .. tostring(commit_error)
    end

    return true
end


local BALANCER_LIST_FIELDS = {
    "tcp_balancer_v4",
    "tcp_balancer_v6",
    "udp_balancer_v4",
    "udp_balancer_v6"
}

local function remove_deleted_cfg_refs(cursor, config_name, delete_cfgs)
    local changed = false

    cursor:foreach(config_name, "general", function(section)
        local section_name = section[".name"]
        for _, field in ipairs(BALANCER_LIST_FIELDS) do
            local current = normalize_list(section[field])
            if #current > 0 then
                local kept = {}
                local field_changed = false
                for _, value in ipairs(current) do
                    if delete_cfgs[tostring(value)] then
                        field_changed = true
                    else
                        kept[#kept + 1] = tostring(value)
                    end
                end

                if field_changed then
                    if #kept == 0 then
                        cursor:delete(config_name, section_name, field)
                    else
                        local ok, err = cursor:set(
                            config_name, section_name, field, kept
                        )
                        if not ok then
                            error("cannot update " .. config_name .. "." .. field ..
                                ": " .. tostring(err))
                        end
                    end
                    changed = true
                end
            end
        end
        return true
    end)

    return changed
end

local function apply_subscription_plan(config, ext_id, sub, plan, now)
    local cursor = uci.cursor()
    local delete_cfgs = {}
    local delete_rows = {}
    for _, row in ipairs(plan.rows) do
        if row.action == "delete" and row.section then
            delete_cfgs[tostring(row.section)] = true
            delete_rows[#delete_rows + 1] = row
        end
    end

    local core_changed = (plan.add + plan.update + plan.mark_missing + plan.delete) > 0
    local ext_changed = false
    local ok, apply_error = pcall(function()
        for _, row in ipairs(plan.rows) do
            if row.action == "add" then
                local section = cursor:add("xray_core", "servers")
                if not section or section == "" then
                    error("UCI could not allocate a servers section")
                end

                row.section = section

                local defaults = {
                    alias = row.alias,
                    ext_id = tostring(ext_id),
                    auto = "1",
                    domain_strategy = config.domain_strategy or "UseIP",
                    domain_resolve_dns_method =
                        config.domain_resolve_dns_method or "udp",
                    dialer_proxy = "disabled"
                }

                -- Resolver configuration is global default for newly imported
                -- servers only; existing per-server settings remain untouched.
                if config.domain_resolve_dns
                   and config.domain_resolve_dns ~= "" then
                    defaults.domain_resolve_dns = config.domain_resolve_dns
                end

                for field, value in pairs(defaults) do
                    local set_ok, set_error = cursor:set(
                        "xray_core", section, field, tostring(value)
                    )
                    if not set_ok then
                        error("cannot initialize new server field " .. field ..
                            ": " .. tostring(set_error))
                    end
                end

                set_target_fields(cursor, section, row.target)

            elseif row.action == "update" then
                if not row.section or row.section == "" then
                    error("existing server section missing for alias " .. tostring(row.alias))
                end
                set_target_fields(cursor, row.section, row.target)

            elseif row.action == "mark_missing" then
                if not row.section or row.section == "" then
                    error("existing server section missing for missing marker " .. tostring(row.alias))
                end
                local set_ok, set_error = cursor:set(
                    "xray_core", row.section, "subscription_missing", "1"
                )
                if not set_ok then
                    error("cannot mark missing server " .. tostring(row.alias) ..
                        ": " .. tostring(set_error))
                end

            elseif row.action == "delete" then
                if not row.section or row.section == "" then
                    error("existing server section missing for deletion " .. tostring(row.alias))
                end
                local delete_ok, delete_error = cursor:delete(
                    "xray_core", row.section
                )
                if delete_ok == false then
                    error("cannot delete server section " .. tostring(row.section) ..
                        ": " .. tostring(delete_error))
                end
            end
        end

        if next(delete_cfgs) ~= nil then
            -- Remove all references from both primary and backup UCI lists.
            if remove_deleted_cfg_refs(cursor, "xray_core", delete_cfgs) then
                core_changed = true
            end
            ext_changed = remove_deleted_cfg_refs(cursor, "xray_ext", delete_cfgs)
        end
    end)

    if not ok then
        return false, "could not stage UCI changes: " .. tostring(apply_error), false
    end

    -- There is no cross-config UCI transaction. Commit backup-list cleanup first:
    -- if it fails, retain the servers and do not commit their deletion.
    if ext_changed then
        local committed, commit_error = cursor:commit("xray_ext")
        if not committed then
            return false, "could not commit xray_ext balancer-list cleanup: " ..
                tostring(commit_error), false
        end
    end

    if core_changed then
        local committed, commit_error = cursor:commit("xray_core")
        if not committed then
            return false, "could not commit xray_core: " ..
                tostring(commit_error), false
        end
    end

    -- Verify mark/delete results with a fresh UCI cursor. This distinguishes
    -- a successful set/delete + commit call from the state actually visible in UCI.
    if plan.mark_missing > 0 or plan.clear_missing > 0 or plan.delete > 0 then
        local verify_cursor = uci.cursor()
        for _, row in ipairs(plan.rows) do
            if row.action == "mark_missing" then
                local actual = verify_cursor:get(
                    "xray_core", row.section, "subscription_missing"
                )
                local marker_ok = tostring(actual or "") == "1"
                if type(actual) == "table" then
                    marker_ok = #actual == 1 and tostring(actual[1]) == "1"
                end
                if not marker_ok then
                    return false,
                        "UCI marker verification failed for alias " ..
                        tostring(row.alias) .. " section=" .. tostring(row.section),
                        false
                end
                print(
                    "xray_extd: MISSING MARK VERIFIED alias=" ..
                    string.format("%q", tostring(row.alias)) ..
                    " section=" .. tostring(row.section)
                )
            elseif row.action == "update" then
                local clears_missing_marker = false
                for _, field in ipairs(row.fields or {}) do
                    if field == "subscription_missing" then
                        clears_missing_marker = true
                        break
                    end
                end
                if clears_missing_marker then
                    local actual = verify_cursor:get(
                        "xray_core", row.section, "subscription_missing"
                    )
                    if present(actual) then
                        return false,
                            "UCI marker-clear verification failed for alias " ..
                            tostring(row.alias) .. " section=" .. tostring(row.section),
                            false
                    end
                    print(
                        "xray_extd: MISSING MARK CLEAR VERIFIED alias=" ..
                        string.format("%q", tostring(row.alias)) ..
                        " section=" .. tostring(row.section)
                    )
                end
            elseif row.action == "delete" then
                local remains = verify_cursor:get("xray_core", row.section)
                if remains ~= nil then
                    return false,
                        "UCI delete verification failed for alias " ..
                        tostring(row.alias) .. " section=" .. tostring(row.section),
                        false
                end
                print(
                    "xray_extd: MISSING DELETE UCI VERIFIED alias=" ..
                    string.format("%q", tostring(row.alias)) ..
                    " section=" .. tostring(row.section)
                )
            end
        end
    end

    -- Queue API removals only after the UCI deletion was committed. Check the
    -- current runtime once and schedule exactly the deleted server's existing
    -- outbound tags; if runtime is unavailable, queue all four tags for retry.
    if #delete_rows > 0 then
        local runtime = get_runtime_outbounds()
        for _, row in ipairs(delete_rows) do
            for _, list_name in ipairs(BALANCER_LIST_FIELDS) do
                local tag = list_name .. "@balancer_outbound:" .. row.section
                if not runtime or runtime.tags[tag] then
                    pending_runtime_removals[tag] = {
                        tag = tag,
                        last_log = 0
                    }
                end
            end
        end
    end

    -- Refresh only actual outbound field changes in primary lists. A change to
    -- subscription_missing alone is metadata and must not churn a live tunnel.
    local groups = {
        { list_name = "tcp_balancer_v4", list = config and config.tcp_v4 },
        { list_name = "tcp_balancer_v6", list = config and config.tcp_v6 },
        { list_name = "udp_balancer_v4", list = config and config.udp_v4 },
        { list_name = "udp_balancer_v6", list = config and config.udp_v6 }
    }

    for _, row in ipairs(plan.rows) do
        if row.action == "update" and row.section and row.requires_runtime_sync then
            for _, group in ipairs(groups) do
                for _, cfg in ipairs(group.list or {}) do
                    if cfg == row.section then
                        local tag = group.list_name .. "@balancer_outbound:" .. row.section
                        pending_runtime_rebuilds[tag] = {
                            tag = tag,
                            list_name = group.list_name,
                            cfg = row.section,
                            phase = "check",
                            last_log = 0
                        }
                    end
                end
            end
        end
    end

    local runtime_sync_pending =
        process_pending_runtime_rebuilds(os.time()) +
        process_pending_runtime_removals(os.time())

    local saved, save_error = save_subscription_last_update(ext_id, now)
    if not saved then
        return false, save_error, runtime_sync_pending > 0
    end

    return true, nil, runtime_sync_pending > 0
end

local function process_one_pending_runtime_removal(tag, state, now)
    if state.next_retry and now < state.next_retry then
        return true
    end

    local exists, check_error = runtime_has_outbound(tag)
    if exists == nil then
        state.next_retry = now + 10
        if now - (state.last_log or 0) >= 30 then
            print("xray_extd: DELETE RUNTIME SYNC PENDING tag=" .. tag ..
                " reason=" .. tostring(check_error))
            state.last_log = now
        end
        return true
    end

    if not exists then
        pending_runtime_removals[tag] = nil
        print("xray_extd: DELETE RUNTIME SYNC OK tag=" .. tag .. " already absent")
        return false
    end

    local removed, remove_error = xray_remove_outbound(tag)
    if removed then
        pending_runtime_removals[tag] = nil
        print("xray_extd: DELETE RUNTIME SYNC OK tag=" .. tag)
        return false
    end

    state.next_retry = now + 10
    if now - (state.last_log or 0) >= 30 then
        print("xray_extd: DELETE RUNTIME SYNC PENDING tag=" .. tag ..
            " reason=" .. tostring(remove_error or "remove/verification failed"))
        state.last_log = now
    end
    return true
end

process_pending_runtime_removals = function(now)
    local pending = 0
    for tag, state in pairs(pending_runtime_removals) do
        if process_one_pending_runtime_removal(tag, state, now) then
            pending = pending + 1
        end
    end
    return pending
end


local function process_one_pending_runtime_rebuild(tag, state, now)
    if state.next_retry and now < state.next_retry then
        return false
    end

    local exists, check_error = runtime_has_outbound(tag)
    if exists == nil then
        state.phase = "check"
        state.next_retry = now + 10
        if now - (state.last_log or 0) >= 30 then
            print("xray_extd: UPDATE RUNTIME SYNC PENDING tag=" .. tag ..
                " reason=" .. tostring(check_error))
            state.last_log = now
        end
        return true
    end

    if state.phase == "check" or state.phase == "remove" then
        if exists then
            local removed, remove_error = xray_remove_outbound(tag)
            if not removed then
                state.phase = "remove"
                state.next_retry = now + 10
                if now - (state.last_log or 0) >= 30 then
                    print("xray_extd: UPDATE RUNTIME SYNC PENDING tag=" .. tag ..
                        " reason=remove failed: " .. tostring(remove_error))
                    state.last_log = now
                end
                return true
            end
        end
        state.phase = "add"
        state.next_retry = nil
        exists = false
    end

    if state.phase == "add" then
        -- A tag present after reaching the add phase is already the refreshed
        -- outbound (or another retry succeeded); do not remove it again.
        if exists then
            pending_runtime_rebuilds[tag] = nil
            print("xray_extd: UPDATE RUNTIME SYNC OK tag=" .. tag)
            return false
        end

        local server = find_server_by_cfg(state.cfg)
        local outbound = server and build_outbound(server, state.list_name) or nil
        if not outbound then
            state.next_retry = now + 10
            if now - (state.last_log or 0) >= 30 then
                print("xray_extd: UPDATE RUNTIME SYNC PENDING tag=" .. tag ..
                    " reason=cannot build outbound")
                state.last_log = now
            end
            return true
        end

        local added, add_error = xray_add_outbound(outbound)
        if not added then
            state.next_retry = now + 10
            if now - (state.last_log or 0) >= 30 then
                print("xray_extd: UPDATE RUNTIME SYNC PENDING tag=" .. tag ..
                    " reason=add failed: " .. tostring(add_error))
                state.last_log = now
            end
            return true
        end

        local verified, verify_error = runtime_has_outbound(tag)
        if verified == true then
            pending_runtime_rebuilds[tag] = nil
            print("xray_extd: UPDATE RUNTIME SYNC OK tag=" .. tag)
            return false
        end

        state.next_retry = now + 10
        if now - (state.last_log or 0) >= 30 then
            print("xray_extd: UPDATE RUNTIME SYNC PENDING tag=" .. tag ..
                " reason=verification failed: " .. tostring(verify_error))
            state.last_log = now
        end
        return true
    end

    state.next_retry = now + 10
    return true
end


process_pending_runtime_rebuilds = function(now)
    local pending = 0
    for tag, state in pairs(pending_runtime_rebuilds) do
        if process_one_pending_runtime_rebuild(tag, state, now) then
            pending = pending + 1
        end
    end
    return pending
end


local function flush_update_requests(config, now)
    promote_due_update_requests(now)

    for ext_id, request in pairs(pending_update_requests) do
        local reasons = {}
        for reason, _ in pairs(request.reasons) do
            table.insert(reasons, reason)
        end
        table.sort(reasons)

        print(
            "xray_extd: UPDATE DECISION " ..
            "ext_id=" .. ext_id ..
            " name=" .. tostring(request.name) ..
            " role=" .. request.role ..
            " reasons=" .. table.concat(reasons, ",")
        )

        local sub = config.subscriptions[ext_id]
        local is_manual_request = request.reasons[MANUAL_REFRESH_REASON] == true
        local allowed =
            (is_manual_request and subscription_can_manual_update(sub, request.role)) or
            subscription_can_auto_update(sub, request.role)

        if not allowed then
            print(
                "xray_extd: UPDATE SKIPPED ext_id=" .. ext_id ..
                " reason=subscription is no longer enabled or eligible"
            )
            finish_manual_refresh_target(ext_id, false)
        else
            print(
                "xray_extd: UPDATE FETCH START ext_id=" .. ext_id ..
                " name=" .. tostring(sub.name)
            )

            local fetched, result = fetch_and_parse_subscription(sub, config)
            if fetched then
                local meta_ok, meta_saved, meta_error = pcall(
                    save_subscription_metadata,
                    ext_id,
                    result.metadata
                )
                if not meta_ok then
                    print("xray_extd: subscription metadata save failed ext_id=" .. ext_id ..
                        " error=" .. tostring(meta_saved))
                elseif not meta_saved then
                    print("xray_extd: subscription metadata save failed ext_id=" .. ext_id ..
                        " error=" .. tostring(meta_error))
                end

                print(
                    "xray_extd: UPDATE FETCH/PARSE OK ext_id=" .. ext_id ..
                    " format=" .. result.format ..
                    " bytes=" .. tostring(result.bytes) ..
                    " servers=" .. tostring(result.server_count) ..
                    " unsupported=" .. tostring(result.unsupported) ..
                    " ignored=" .. tostring(result.ignored) ..
                    " safe_to_remove=" .. tostring(result.safe_to_remove)
                )

                local plan, plan_error = plan_subscription_update(
                    config,
                    ext_id,
                    sub,
                    result
                )

                if not plan then
                    print(
                        "xray_extd: UPDATE PLAN FAILED ext_id=" .. ext_id ..
                        " error=" .. tostring(plan_error) ..
                        "; retrying in " .. tostring(UPDATE_RETRY_DELAY) .. " seconds"
                    )

                    for reason, _ in pairs(request.reasons) do
                        queue_update_request(
                            config,
                            ext_id,
                            reason,
                            request.role,
                            UPDATE_RETRY_DELAY
                        )
                    end
                    finish_manual_refresh_target(ext_id, false)
                else
                    print(
                        "xray_extd: UPDATE PLAN ext_id=" .. ext_id ..
                        " add=" .. tostring(plan.add) ..
                        " update=" .. tostring(plan.update) ..
                        " unchanged=" .. tostring(plan.unchanged) ..
                        " skipped=" .. tostring(plan.skipped) ..
                        " missing=" .. tostring(plan.missing) ..
                        " missing_mode=" .. tostring(plan.missing_mode) ..
                        " auto_remove=" .. tostring(sub.auto_remove) ..
                        " clear_missing=" .. tostring(plan.clear_missing) ..
                        " mark_missing=" .. tostring(plan.mark_missing) ..
                        " already_missing=" .. tostring(plan.already_missing) ..
                        " delete=" .. tostring(plan.delete) ..
                        (plan.missing_guarded and " missing_actions=blocked_unsafe_parse" or "")
                    )

                    local printed = 0
                    for _, row in ipairs(plan.rows) do
                        if row.action ~= "skip" and printed < 20 then
                            local detail = #row.fields > 0
                                and table.concat(row.fields, ",")
                                or "-"
                            print(
                                "xray_extd: UPDATE PLAN ITEM ext_id=" .. ext_id ..
                                " action=" .. row.action ..
                                " alias=" .. string.format("%q", row.alias) ..
                                " alias_index=" .. tostring(row.alias_index or 1) ..
                                " alias_count=" .. tostring(row.alias_count or 1) ..
                                " fields=" .. detail
                            )
                            printed = printed + 1
                        end
                    end

                    if #plan.rows > printed then
                        print(
                            "xray_extd: UPDATE PLAN ITEM remaining=" ..
                            tostring(#plan.rows - printed) ..
                            " (details omitted)"
                        )
                    end

                    for _, item in ipairs(plan.missing_details or {}) do
                        print(
                            "xray_extd: UPDATE MISSING ITEM ext_id=" .. ext_id ..
                            " action=" .. tostring(item.action) ..
                            " alias=" .. string.format("%q", tostring(item.alias)) ..
                            " alias_index=" .. tostring(item.alias_index or 1) ..
                            " alias_count=" .. tostring(item.alias_count or 1) ..
                            " section=" .. tostring(item.section)
                        )
                    end

                    local applied, apply_error, runtime_pending =
                        apply_subscription_plan(config, ext_id, sub, plan, now)

                    if applied then
                        last_subscription_fetch[ext_id] = now
                        finish_manual_refresh_target(ext_id, true)

                        print(
                            "xray_extd: UPDATE APPLIED ext_id=" .. ext_id ..
                            " add=" .. tostring(plan.add) ..
                            " update=" .. tostring(plan.update) ..
                            " unchanged=" .. tostring(plan.unchanged) ..
                            " skipped=" .. tostring(plan.skipped) ..
                            " missing=" .. tostring(plan.missing) ..
                            " missing_mode=" .. tostring(plan.missing_mode) ..
                            " clear_missing=" .. tostring(plan.clear_missing) ..
                            " mark_missing=" .. tostring(plan.mark_missing) ..
                            " already_missing=" .. tostring(plan.already_missing) ..
                            " delete=" .. tostring(plan.delete) ..
                            " runtime_sync_pending=" .. tostring(runtime_pending)
                        )
                    else
                        print(
                            "xray_extd: UPDATE APPLY FAILED ext_id=" .. ext_id ..
                            " error=" .. tostring(apply_error) ..
                            "; retrying in " .. tostring(UPDATE_RETRY_DELAY) .. " seconds"
                        )

                        for reason, _ in pairs(request.reasons) do
                            queue_update_request(
                                config,
                                ext_id,
                                reason,
                                request.role,
                                UPDATE_RETRY_DELAY
                            )
                        end
                        finish_manual_refresh_target(ext_id, false)
                    end
                end

                if result.safe_to_remove ~= true then
                    print(
                        "xray_extd: UPDATE SAFETY ext_id=" .. ext_id ..
                        " missing-server actions blocked because feed is not fully understood"
                    )
                end
            else
                print(
                    "xray_extd: UPDATE FETCH/PARSE FAILED ext_id=" .. ext_id ..
                    " error=" .. tostring(result) ..
                    "; retrying in " .. tostring(UPDATE_RETRY_DELAY) .. " seconds"
                )

                for reason, _ in pairs(request.reasons) do
                    queue_update_request(
                        config,
                        ext_id,
                        reason,
                        request.role,
                        UPDATE_RETRY_DELAY
                    )
                end
                finish_manual_refresh_target(ext_id, false)
            end
        end
    end

    pending_update_requests = {}
    finish_manual_refresh_if_complete()
end


local function analyze_subscription_list(result, server_meta, config, expected_role)
    local subscriptions = {}

    for cfg, state in pairs(result.states or {}) do
        local meta = server_meta[cfg]
        local ext_id = meta and meta.ext_id
        local subscription = ext_id and config.subscriptions[ext_id]

        -- Primary and backup health must be attributed only to servers owned by
        -- a subscription with the matching role. This prevents a stale or
        -- misconfigured balancer list from triggering an update for the wrong
        -- subscription role.
        if ext_id and ext_id ~= ""
           and subscription
           and subscription.role == expected_role then
            local sub = subscriptions[ext_id]

            if not sub then
                sub = {
                    total = 0,
                    live = 0,
                    dead = 0,
                    unknown = 0,
                    states = {}
                }
                subscriptions[ext_id] = sub
            end

            sub.total = sub.total + 1
            sub.states[cfg] = state

            if state == "live" then
                sub.live = sub.live + 1
            elseif state == "dead" then
                sub.dead = sub.dead + 1
            else
                sub.unknown = sub.unknown + 1
            end
        end
    end

    return subscriptions
end


local function subscription_has_confirmed_dead(ext_id)
    for key, confirmed in pairs(subscription_dead_confirmed) do
        if confirmed then
            local key_ext_id = key:match("^[^:]+:(.+)$")

            if key_ext_id == ext_id then
                return true
            end
        end
    end

    return false
end


local function update_request_exists(ext_id)
    return pending_update_requests[ext_id] ~= nil
        or scheduled_update_requests[ext_id] ~= nil
end


-- Health checks share the proven primary-subscription algorithm, but backup
-- subscriptions use independent confirmation thresholds and role-specific
-- update reasons. State is tracked per (group, ext_id), never for one combined
-- backup group. Thresholds are loaded from xray_ext.general.

local function process_subscription_states(
    group_name,
    result,
    server_meta,
    config,
    role,
    dead_confirm,
    live_confirm
)
    role = role or "primary"
    dead_confirm = dead_confirm or SUBSCRIPTION_DEAD_CONFIRM
    live_confirm = live_confirm or SUBSCRIPTION_LIVE_CONFIRM

    local label = role == "backup"
        and "BACKUP SUBSCRIPTION"
        or "SUBSCRIPTION"

    local dead_reason = role == "backup"
        and "backup_subscription_dead"
        or "subscription_dead"
    local retry_reason = role == "backup"
        and "backup_subscription_dead_retry"
        or "subscription_dead_retry"
    local role_suffix = role == "backup" and "; role=backup" or ""

    local subscriptions =
        analyze_subscription_list(
            result,
            server_meta,
            config,
            role
        )

    for ext_id, sub in pairs(subscriptions) do
        local state = get_group_state(sub)
        local key = group_name .. ":" .. ext_id
        local previous = last_subscription_states[key]

        if previous and previous ~= state then
            print(
                string.format(
                    "xray_extd: %s %s [%s] %s -> %s",
                    label,
                    ext_id,
                    group_name,
                    previous,
                    state
                )
            )
        end

        last_subscription_states[key] = state

        if state == "dead" then
            subscription_dead_streak[key] =
                (subscription_dead_streak[key] or 0) + 1
            subscription_live_streak[key] = 0

            if subscription_dead_streak[key] >= dead_confirm
               and not subscription_dead_confirmed[key] then

                print(
                    "xray_extd: " .. label .. " " ..
                    ext_id ..
                    " [" .. group_name .. "] " ..
                    "confirmed DEAD after " ..
                    tostring(subscription_dead_streak[key]) ..
                    " checks" .. role_suffix
                )

                subscription_dead_confirmed[key] = true

                queue_update_request(
                    config,
                    ext_id,
                    dead_reason,
                    role,
                    AUTO_UPDATE_DELAY
                )
            end

            -- If a previous update succeeded but this subscription is still
            -- confirmed dead, fetch fresh parameters again every retry interval.
            -- Do not compete with an update already pending/scheduled (including
            -- the normal five-minute retry after fetch/parse/apply failures).
            if subscription_dead_confirmed[key] then
                local last_fetch =
                    tonumber(last_subscription_fetch[ext_id]) or 0
                local now = os.time()

                if last_fetch > 0
                   and now - last_fetch >= AUTO_UPDATE_DELAY
                   and not update_request_exists(ext_id) then

                    print(
                        "xray_extd: " .. label .. " " ..
                        ext_id .. " [" .. group_name .. "] " ..
                        "still confirmed DEAD after update; queueing retry"
                    )

                    queue_update_request(
                        config,
                        ext_id,
                        retry_reason,
                        role
                    )
                end
            end

        elseif state == "available" then
            subscription_live_streak[key] =
                (subscription_live_streak[key] or 0) + 1
            subscription_dead_streak[key] = 0

            if subscription_live_streak[key] >= live_confirm
               and subscription_dead_confirmed[key] then

                print(
                    "xray_extd: " .. label .. " " ..
                    ext_id ..
                    " [" .. group_name .. "] " ..
                    "confirmed AVAILABLE after " ..
                    tostring(subscription_live_streak[key]) ..
                    " checks"
                )

                subscription_dead_confirmed[key] = false

                if not subscription_has_confirmed_dead(ext_id) then
                    cancel_scheduled_update_reason(
                        ext_id,
                        dead_reason
                    )
                    cancel_scheduled_update_reason(
                        ext_id,
                        retry_reason
                    )
                end
            end

        else
            subscription_dead_streak[key] = 0
            subscription_live_streak[key] = 0
        end
    end
end


local function get_result_subscription_ids(
    result,
    server_meta
)
    local ext_ids = {}

    for cfg, _ in pairs(result.states or {}) do
        local meta = server_meta[cfg]
        local ext_id = meta and meta.ext_id

        if ext_id and ext_id ~= "" then
            ext_ids[ext_id] = true
        end
    end

    return ext_ids
end


-- ============================================================
-- Запустить failover для группы
-- ============================================================

local function start_failover_group(group_name, list_name, backup_list)
    if failover_active[group_name] then
        return true
    end

    if not backup_list or #backup_list == 0 then
        print(
            "xray_extd: FAILOVER " ..
            group_name ..
            ": no backup servers configured"
        )
        return false
    end

    failover_active[group_name] = true
    failover_tags[group_name] = {}

    print(
        "xray_extd: FAILOVER START " ..
        group_name
    )

    for _, cfg in ipairs(backup_list or {}) do
        local server = find_server_by_cfg(cfg)

        if not server then
            print(
                "xray_extd: FAILOVER " ..
                group_name ..
                ": server not found " ..
                cfg
            )
        else
            local outbound =
                build_outbound(
                    server,
                    list_name
                )

            if not outbound then
                print(
                    "xray_extd: FAILOVER " ..
                    group_name ..
                    ": cannot build outbound " ..
                    cfg
                )
            else
                local exists, err =
                    runtime_has_outbound(
                        outbound.tag
                    )

                if exists == nil then
                    print(
                        "xray_extd: FAILOVER " ..
                        group_name ..
                        ": lso error for " ..
                        cfg ..
                        ": " ..
                        tostring(err)
                    )
                elseif exists == true then
                    print(
                        "xray_extd: FAILOVER " ..
                        group_name ..
                        ": already exists " ..
                        cfg
                    )
                else
                    print(
                        "xray_extd: FAILOVER " ..
                        group_name ..
                        ": adding " ..
                        cfg
                    )

                    local added, add_err =
                        xray_add_outbound(
                            outbound
                        )

                    if added then
                        failover_tags[group_name][cfg] = true

                        print(
                            "xray_extd: FAILOVER " ..
                            group_name ..
                            ": added " ..
                            cfg
                        )
                    else
                        print(
                            "xray_extd: FAILOVER " ..
                            group_name ..
                            ": add failed " ..
                            cfg ..
                            ": " ..
                            tostring(add_err)
                        )
                    end
                end
            end
        end
    end
end


-- ============================================================
-- Завершить failover для группы
-- ============================================================

local function stop_failover_group(group_name, list_name, backup_list)
    if not failover_active[group_name] then
        return true
    end

    print(
        "xray_extd: FAILOVER CLEANUP START " ..
        group_name
    )

    local remove_cfgs = {}
    local remaining = {}
    local cleanup_ok = true

    for cfg, _ in pairs(failover_tags[group_name]) do
        remove_cfgs[cfg] = true
    end

    for _, cfg in ipairs(backup_list or {}) do
        remove_cfgs[cfg] = true
    end

    for cfg, _ in pairs(remove_cfgs) do
        local tag =
            list_name ..
            "@balancer_outbound:" ..
            cfg

        local exists, err =
            runtime_has_outbound(tag)

        if exists == nil then
            cleanup_ok = false
            remaining[cfg] = true

            print(
                "xray_extd: FAILOVER " ..
                group_name ..
                ": lso error while removing " ..
                cfg ..
                ": " ..
                tostring(err)
            )

        elseif exists == true then
            print(
                "xray_extd: FAILOVER " ..
                group_name ..
                ": removing " ..
                cfg
            )

            local removed, remove_err =
                xray_remove_outbound(tag)

            if not removed then
                cleanup_ok = false
                remaining[cfg] = true

                print(
                    "xray_extd: FAILOVER " ..
                    group_name ..
                    ": remove failed " ..
                    cfg ..
                    ": " ..
                    tostring(remove_err)
                )
            end
        end
    end

    failover_tags[group_name] = remaining

    if cleanup_ok then
        failover_active[group_name] = false

        print(
            "xray_extd: FAILOVER CLEANUP COMPLETE " ..
            group_name
        )

        return true
    end

    print(
        "xray_extd: FAILOVER CLEANUP PENDING " ..
        group_name
    )

    return false
end


local function process_failover_group(
    group_name,
    result,
    list_name,
    backup_list,
    server_meta,
    config
)
    local state = get_group_state(result)

    if state == "dead" then
        group_dead_streak[group_name] =
            group_dead_streak[group_name] + 1
        group_live_streak[group_name] = 0

        if last_group_states[group_name] ~= state then
            print(
                "xray_extd: GROUP " ..
                group_name ..
                " " ..
                tostring(last_group_states[group_name]) ..
                " -> " ..
                state
            )
            last_group_states[group_name] = state
        end

        if group_dead_streak[group_name] >= FAILOVER_DEAD_CONFIRM
           and not group_dead_confirmed[group_name] then

            print(
                "xray_extd: GROUP " ..
                group_name ..
                " confirmed DEAD after " ..
                tostring(group_dead_streak[group_name]) ..
                " checks"
            )

            group_dead_confirmed[group_name] = true

            start_failover_group(
                group_name,
                list_name,
                backup_list
            )

            queue_updates_for_subscription_ids(
                config,
                get_result_subscription_ids(
                    result,
                    server_meta
                ),
                "group_dead",
                "primary",
                AUTO_UPDATE_DELAY
            )
        end

        return
    end

    if state == "available" then
        group_live_streak[group_name] =
            group_live_streak[group_name] + 1
        group_dead_streak[group_name] = 0

        if last_group_states[group_name] ~= state then
            print(
                "xray_extd: GROUP " ..
                group_name ..
                " " ..
                tostring(last_group_states[group_name]) ..
                " -> " ..
                state
            )
            last_group_states[group_name] = state
        end

        if failover_active[group_name]
           and group_live_streak[group_name] >= FAILOVER_LIVE_CONFIRM then

            if group_live_streak[group_name] == FAILOVER_LIVE_CONFIRM then
                print(
                    "xray_extd: GROUP " ..
                    group_name ..
                    " confirmed AVAILABLE after " ..
                    tostring(group_live_streak[group_name]) ..
                    " checks"
                )
            end

            local cleanup_done =
                stop_failover_group(
                    group_name,
                    list_name,
                    backup_list
                )

            if cleanup_done then
                group_dead_confirmed[group_name] = false

                local recovered_ext_ids =
                    get_result_subscription_ids(
                        result,
                        server_meta
                    )

                for ext_id, _ in pairs(recovered_ext_ids) do
                    cancel_scheduled_update_reason(
                        ext_id,
                        "group_dead"
                    )
                end
            end
        else
            if not failover_active[group_name] then
                group_dead_confirmed[group_name] = false
            end
        end

        return
    end

    group_dead_streak[group_name] = 0
    group_live_streak[group_name] = 0

    if last_group_states[group_name] ~= state then
        print(
            "xray_extd: GROUP " ..
            group_name ..
            " " ..
            tostring(last_group_states[group_name]) ..
            " -> " ..
            state
        )
        last_group_states[group_name] = state
    end
end


-- ============================================================
-- Основной цикл
-- ============================================================

local function heartbeat()
    local wan_up = is_wan_up()

    if last_wan_up ~= wan_up then
        if wan_up then
            print("xray_extd: WAN UP; resuming daemon actions")
        else
            print("xray_extd: WAN DOWN or status unavailable; pausing daemon actions")
        end

        last_wan_up = wan_up
    end

    if not wan_up then
        if manual_refresh_requested then
            manual_refresh_status.state = "waiting_wan"
            manual_refresh_status.message = "Waiting for WAN connectivity"
        end
        return
    end

    local config = read_xray_config()

    FAILOVER_DEAD_CONFIRM = config.failover_dead_confirm
    FAILOVER_LIVE_CONFIRM = config.failover_live_confirm
    SUBSCRIPTION_DEAD_CONFIRM = config.subscription_dead_confirm
    SUBSCRIPTION_LIVE_CONFIRM = config.subscription_live_confirm

    process_pending_runtime_rebuilds(os.time())
    process_pending_runtime_removals(os.time())

    local backup_probe_tcp_v4_cfgs =
        reconcile_backup_tcp_v4_probes(config, os.time())

    local observatory =
        get_observatory(
            config.metrics_port
        ) or {}

    local backup_probe_tcp_v4 =
        analyze_observatory_list(
            backup_probe_tcp_v4_cfgs,
            BACKUP_PROBE_TCP_V4_PREFIX,
            observatory
        )

    -- log_observatory_list("BACKUP PROBE TCP v4", backup_probe_tcp_v4)
    log_server_state_changes("BACKUP PROBE TCP v4", backup_probe_tcp_v4)

    process_subscription_states(
        "backup_tcp_v4",
        backup_probe_tcp_v4,
        config.server_meta,
        config,
        "backup",
        config.backup_subscription_dead_confirm,
        config.backup_subscription_live_confirm
    )

    local primary_tcp_v4 =
        analyze_observatory_list(
            config.tcp_v4,
            "tcp_balancer_v4@balancer_outbound:",
            observatory
        )

    local primary_tcp_v6 =
        analyze_observatory_list(
            config.tcp_v6,
            "tcp_balancer_v6@balancer_outbound:",
            observatory
        )

    local primary_udp_v4 =
        analyze_observatory_list(
            config.udp_v4,
            "udp_balancer_v4@balancer_outbound:",
            observatory
        )

    local primary_udp_v6 =
        analyze_observatory_list(
            config.udp_v6,
            "udp_balancer_v6@balancer_outbound:",
            observatory
        )

    -- log_observatory_list("PRIMARY TCP v4", primary_tcp_v4)
    -- log_observatory_list("PRIMARY UDP v4", primary_udp_v4)

    log_server_state_changes("PRIMARY TCP v4", primary_tcp_v4)
    log_server_state_changes("PRIMARY TCP v6", primary_tcp_v6)
    log_server_state_changes("PRIMARY UDP v4", primary_udp_v4)
    log_server_state_changes("PRIMARY UDP v6", primary_udp_v6)

    process_subscription_states(
        "tcp_v4",
        primary_tcp_v4,
        config.server_meta,
        config
    )

    process_subscription_states(
        "tcp_v6",
        primary_tcp_v6,
        config.server_meta,
        config
    )

    process_subscription_states(
        "udp_v4",
        primary_udp_v4,
        config.server_meta,
        config
    )

    process_subscription_states(
        "udp_v6",
        primary_udp_v6,
        config.server_meta,
        config
    )

    process_failover_group(
        "tcp_v4",
        primary_tcp_v4,
        "tcp_balancer_v4",
        config.backup_tcp_v4,
        config.server_meta,
        config
    )

    process_failover_group(
        "tcp_v6",
        primary_tcp_v6,
        "tcp_balancer_v6",
        config.backup_tcp_v6,
        config.server_meta,
        config
    )

    process_failover_group(
        "udp_v4",
        primary_udp_v4,
        "udp_balancer_v4",
        config.backup_udp_v4,
        config.server_meta,
        config
    )

    process_failover_group(
        "udp_v6",
        primary_udp_v6,
        "udp_balancer_v6",
        config.backup_udp_v6,
        config.server_meta,
        config
    )

    -- Daily refresh of backup subscriptions in auto mode is disabled.
    -- A future health-based backup refresh mechanism will own this path.

    queue_manual_refreshes(config)
    flush_update_requests(config, os.time())
end


local ubus_conn = ubus.connect()
if ubus_conn then
    local control_object = {
        xray_extd = {
            refresh = {
                function(req, msg)
                    if manual_refresh_requested or
                       manual_refresh_status.state == "queued" or
                       manual_refresh_status.state == "waiting_wan" or
                       manual_refresh_status.state == "running" then
                        ubus_conn:reply(req, {
                            accepted = false,
                            state = manual_refresh_status.state,
                            message = "A manual refresh is already pending or running"
                        })
                        return
                    end

                    manual_refresh_requested = true
                    manual_refresh_status = {
                        state = "queued",
                        message = "Manual refresh request accepted",
                        requested_at = os.time(),
                        started_at = 0,
                        finished_at = 0,
                        total = 0,
                        completed = 0,
                        succeeded = 0,
                        failed = 0
                    }
                    manual_refresh_targets = {}

                    print("xray_extd: MANUAL REFRESH requested via ubus")
                    ubus_conn:reply(req, {
                        accepted = true,
                        state = manual_refresh_status.state,
                        message = manual_refresh_status.message
                    })
                end,
                {}
            },
            status = {
                function(req, msg)
                    ubus_conn:reply(req, {
                        state = manual_refresh_status.state,
                        message = manual_refresh_status.message,
                        requested_at = manual_refresh_status.requested_at or 0,
                        started_at = manual_refresh_status.started_at or 0,
                        finished_at = manual_refresh_status.finished_at or 0,
                        total = manual_refresh_status.total or 0,
                        completed = manual_refresh_status.completed or 0,
                        succeeded = manual_refresh_status.succeeded or 0,
                        failed = manual_refresh_status.failed or 0
                    })
                end,
                {}
            }
        }
    }

    local add_ok, add_error = pcall(function()
        ubus_conn:add(control_object)
    end)

    if add_ok then
        print("xray_extd: ubus control API ready (xray_extd.refresh/status)")
    else
        print("xray_extd: failed to register ubus control API: " .. tostring(add_error))
    end
else
    print("xray_extd: ubus connection failed; manual control API unavailable")
end


local timer =
    uloop.interval(
        heartbeat,
        INTERVAL
    )

heartbeat()


local function stop(signo)
    print(
        "xray_extd: stopping, signal=" ..
        tostring(signo)
    )

    timer:cancel()
    uloop.cancel()
end


uloop.signal(
    stop,
    uloop.SIGTERM
)

uloop.signal(
    stop,
    uloop.SIGINT
)


uloop.run()

print("xray_extd: stopped")
