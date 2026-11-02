-- xray_subscription_json_parser.lua
-- Parse provider feeds containing an array of Xray configuration objects.
-- One top-level object is treated as one server: only outbounds[1] is used.
-- The module is standalone and performs no UCI writes or network operations.

local M = {}

local ok_cjson, cjson = pcall(require, "cjson")
if not ok_cjson or not cjson or type(cjson.decode) ~= "function" then
    cjson = nil
elseif type(cjson.decode_array_with_array_mt) == "function" then
    -- Keep empty JSON arrays distinguishable from empty objects where the
    -- installed lua-cjson version supports array metatables.
    pcall(cjson.decode_array_with_array_mt, true)
end

local function is_json_null(value)
    return cjson ~= nil and cjson.null ~= nil and value == cjson.null
end

local function first_nonempty(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if trim(value) ~= "" then
            return value
        end
    end
    return nil
end

local function normalize_transport(value)
    local network = trim(value)
    if network == "" or network == "raw" then
        return "tcp"
    elseif network == "xhttp" then
        return "splithttp"
    elseif network == "websocket" then
        return "ws"
    end
    return network
end

local function string_list(value)
    local result = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            local text = trim(item)
            if text ~= "" then
                result[#result + 1] = text
            end
        end
    else
        local text = trim(value)
        if text ~= "" then
            result[1] = text
        end
    end
    return result
end

local function as_table(value)
    if type(value) == "table" then
        return value
    end
    return {}
end

local function copy_table(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[key] = copy_table(item)
    end
    local mt = getmetatable(value)
    if mt then
        setmetatable(result, mt)
    end
    return result
end

local function without_keys(value, excluded)
    local result = {}
    if type(value) ~= "table" then
        return result
    end

    for key, item in pairs(value) do
        if not excluded[key] then
            result[key] = copy_table(item)
        end
    end
    return result
end

local function has_values(value)
    return type(value) == "table" and next(value) ~= nil
end

local function first(value)
    if type(value) == "table" then
        return value[1]
    end
    return nil
end

local function number_port(value)
    local port = tonumber(value)
    if not port or port < 1 or port > 65535 or port ~= math.floor(port) then
        return nil
    end
    return port
end

local function boolean_value(value)
    if value == nil then
        return nil
    end
    if value == true or value == 1 or value == "1" or value == "true" then
        return "1"
    end
    if value == false or value == 0 or value == "0" or value == "false" then
        return "0"
    end
    return nil
end

local function rate_value(value)
    if value == nil then
        return nil
    end
    local text = trim(value):lower():gsub("mbps$", "")
    if text == "" then
        return nil
    end
    local number = tonumber(text)
    if not number or number < 0 then
        return nil
    end
    return tostring(number)
end

local function normalize_method(method)
    method = trim(method)
    if method == "chacha20-ietf-poly1305" then
        return "chacha20-poly1305"
    end
    return method
end

local function get_first_outbound(config)
    if type(config) ~= "table" or type(config.outbounds) ~= "table" then
        return nil
    end
    return config.outbounds[1]
end

-- Copy only fields which do not have a normal luci-app-xray/UCI control.
-- Known values are copied into the corresponding UCI fields by parse_*().
local function collect_stream_extras(stream, protocol)
    local result = {}
    local mapped_stream_keys = {
        network = true,
        security = true
    }

    if type(stream) ~= "table" then
        return result
    end

    for key, value in pairs(stream) do
        if not mapped_stream_keys[key] then
            if key == "realitySettings" and protocol == "vless" then
                local extras = without_keys(value, {
                    serverName = true,
                    fingerprint = true,
                    publicKey = true,
                    password = true,
                    shortId = true,
                    show = true,
                    spiderX = true
                })
                if has_values(extras) then
                    result.realitySettings = extras
                end

            elseif key == "tlsSettings" and
                (protocol == "vless" or protocol == "hysteria" or protocol == "shadowsocks") then
                local extras = without_keys(value, {
                    serverName = true,
                    fingerprint = true,
                    alpn = true,
                    allowInsecure = true
                })
                if has_values(extras) then
                    result.tlsSettings = extras
                end

            elseif (key == "xhttpSettings" or key == "splithttpSettings") and
                protocol == "vless" then
                local split = copy_table(value)
                if type(split) ~= "table" then
                    split = {}
                end
                -- path and host have first-class UCI fields.
                split.path = nil
                split.host = nil
                if has_values(split) then
                    result.splithttpSettings = split
                end

            elseif key == "hysteriaSettings" and protocol == "hysteria" then
                local extras = without_keys(value, {
                    version = true,
                    auth = true,
                    up = true,
                    down = true,
                    udphop = true
                })
                if has_values(extras) then
                    result.hysteriaSettings = extras
                end

            elseif key == "sockopt" then
                local sockopt = without_keys(value, {
                    mark = true,
                    domainStrategy = true
                })
                if has_values(sockopt) then
                    result.sockopt = sockopt
                end

            else
                result[key] = copy_table(value)
            end
        end
    end

    return result
end

local function collect_settings_extras(settings, protocol)
    if type(settings) ~= "table" then
        return {}
    end

    if protocol == "vless" then
        -- vnext is represented by server/password/port UCI fields. Keeping its
        -- array in custom_config would make it override later LuCI edits.
        return without_keys(settings, { vnext = true })
    elseif protocol == "shadowsocks" then
        -- servers[] is represented by the normal server/password/port fields.
        return without_keys(settings, { servers = true })
    elseif protocol == "hysteria" then
        -- address/port/version are handled by the normal server fields.
        return without_keys(settings, {
            address = true,
            port = true,
            version = true,
            auth = true
        })
    end

    return {}
end

local function make_custom_config(outbound, protocol)
    local custom = {}
    local settings = collect_settings_extras(outbound.settings, protocol)
    local stream = collect_stream_extras(outbound.streamSettings, protocol)
    local standard_keys = {
        tag = true,
        protocol = true,
        settings = true,
        streamSettings = true
    }

    if has_values(settings) then
        custom.settings = settings
    end
    if has_values(stream) then
        custom.streamSettings = stream
    end

    -- Preserve outbound-level extensions too (for example mux or proxySettings).
    -- Identity and protocol are always generated by Xray Extended itself.
    for key, value in pairs(outbound) do
        if not standard_keys[key] then
            custom[key] = copy_table(value)
        end
    end

    if has_values(custom) then
        return custom
    end
    return nil
end

local function parse_vless(outbound, config, alias)
    local settings = as_table(outbound.settings)
    local vnext = as_table(settings.vnext)
    local endpoint = first(vnext)
    if type(endpoint) ~= "table" then
        return nil, "VLESS outbound has no settings.vnext[1]"
    end

    local user = first(endpoint.users)
    if type(user) ~= "table" then
        return nil, "VLESS outbound has no settings.vnext[1].users[1]"
    end

    local address = trim(endpoint.address)
    local port = number_port(endpoint.port)
    local uuid = trim(user.id)
    if address == "" or not port or uuid == "" then
        return nil, "VLESS outbound is missing address, port or UUID"
    end

    local stream = as_table(outbound.streamSettings)
    local security = trim(stream.security)
    if security == "" then
        security = "none"
    end
    local transport_type = normalize_transport(stream.network)
    local reality = as_table(stream.realitySettings)
    local tls = as_table(stream.tlsSettings)
    local item_tls = {
        mode = security,
        flow = trim(user.flow),
        server_name = "",
        fingerprint = "",
        public_key = "",
        short_id = "",
        spider_x = "",
        show = nil,
        insecure = nil,
        alpn = {}
    }

    if security == "reality" then
        item_tls.server_name = trim(reality.serverName)
        item_tls.fingerprint = trim(reality.fingerprint)
        item_tls.public_key = trim(reality.publicKey) ~= ""
            and trim(reality.publicKey) or trim(reality.password)
        item_tls.short_id = trim(reality.shortId)
        item_tls.spider_x = trim(reality.spiderX)
        item_tls.show = boolean_value(reality.show)
    elseif security == "tls" then
        item_tls.server_name = trim(tls.serverName)
        item_tls.fingerprint = trim(tls.fingerprint)
        item_tls.insecure = boolean_value(tls.allowInsecure) or "0"
        item_tls.alpn = string_list(tls.alpn)
    elseif security ~= "none" and security ~= "" then
        return nil, "unsupported VLESS security mode: " .. security
    end

    local xhttp
    if type(stream.xhttpSettings) == "table" then
        xhttp = stream.xhttpSettings
    else
        xhttp = as_table(stream.splithttpSettings)
    end
    local custom_config = make_custom_config(outbound, "vless")

    return {
        source_scheme = "json",
        protocol = "vless",
        alias = alias,
        server = address,
        port = port,
        password = uuid,
        username = trim(user.email),
        vless_encryption = trim(user.encryption),
        domain_strategy = trim(as_table(stream.sockopt).domainStrategy),
        security = security,
        transport = {
            type = transport_type,
            path = trim(xhttp.path),
            host = trim(xhttp.host),
            mode = trim(xhttp.mode),
            -- mode/extra are already retained in custom_config under
            -- splithttpSettings; do not duplicate or flatten them here.
            extra = ""
        },
        tls = item_tls,
        custom_config = custom_config,
        source_tag = trim(outbound.tag),
        source_remarks = trim(config.remarks)
    }
end

local function parse_hysteria(outbound, config, alias)
    local settings = as_table(outbound.settings)
    local stream = as_table(outbound.streamSettings)
    local hysteria_settings = as_table(stream.hysteriaSettings)

    local address = trim(settings.address)
    local port = number_port(settings.port)
    local auth = trim(first_nonempty(
        hysteria_settings.auth, settings.auth, settings.password
    ))
    if address == "" or not port or auth == "" then
        return nil, "Hysteria outbound is missing address, port or authentication"
    end

    local version = tonumber(hysteria_settings.version)
        or tonumber(settings.version)
        or 2
    if version ~= 2 then
        return nil, "only Hysteria version 2 is supported"
    end

    local tls = as_table(stream.tlsSettings)
    local udphop = as_table(hysteria_settings.udphop)
    local hysteria = {
        up_mbps = rate_value(first_nonempty(hysteria_settings.up, settings.up)),
        down_mbps = rate_value(first_nonempty(hysteria_settings.down, settings.down)),
        udphop_port = trim(udphop.port) ~= "" and trim(udphop.port) or nil,
        udphop_interval = trim(udphop.interval) ~= "" and trim(udphop.interval) or nil
    }

    local item_tls = {
        mode = "tls",
        server_name = trim(tls.serverName),
        fingerprint = trim(tls.fingerprint),
        insecure = boolean_value(tls.allowInsecure) or "0",
        alpn = {}
    }
    item_tls.alpn = string_list(tls.alpn)

    return {
        source_scheme = "json",
        protocol = "hysteria",
        alias = alias,
        server = address,
        port = port,
        password = auth,
        security = "tls",
        transport = { type = "hysteria" },
        tls = item_tls,
        hysteria = hysteria,
        domain_strategy = trim(as_table(stream.sockopt).domainStrategy),
        custom_config = make_custom_config(outbound, "hysteria"),
        source_tag = trim(outbound.tag),
        source_remarks = trim(config.remarks)
    }
end

local function parse_shadowsocks(outbound, config, alias)
    local settings = as_table(outbound.settings)
    local server = first(as_table(settings.servers))
    local address, port, password, method, username, uot

    if type(server) == "table" then
        address = server.address
        port = server.port
        password = server.password
        method = server.method
        username = first_nonempty(server.email, server.username)
        uot = server.uot
    else
        -- Also accept the legacy flat form handled by the user's old shell parser.
        address = settings.address
        port = settings.port
        password = settings.password
        method = settings.method
        username = first_nonempty(settings.email, settings.username)
        uot = settings.uot
    end

    address = trim(address)
    port = number_port(port)
    password = trim(password)
    method = normalize_method(method)
    if address == "" or not port or password == "" or method == "" then
        return nil, "Shadowsocks outbound is missing address, port, method or password"
    end

    local stream = as_table(outbound.streamSettings)
    local security = trim(stream.security)
    if security == "" then
        security = "none"
    end
    local tls = as_table(stream.tlsSettings)
    local item_tls = {
        mode = security,
        server_name = trim(tls.serverName),
        fingerprint = trim(tls.fingerprint),
        insecure = boolean_value(tls.allowInsecure) or "0",
        alpn = {}
    }
    item_tls.alpn = string_list(tls.alpn)

    local custom_config = make_custom_config(outbound, "shadowsocks")
    if security ~= "tls" and security ~= "none" and security ~= "" then
        return nil, "unsupported Shadowsocks security mode: " .. security
    end

    return {
        source_scheme = "json",
        protocol = "shadowsocks",
        alias = alias,
        server = address,
        port = port,
        password = password,
        security = method,
        username = trim(username),
        domain_strategy = trim(as_table(stream.sockopt).domainStrategy),
        shadowsocks_udp_over_tcp = boolean_value(uot),
        transport = { type = normalize_transport(stream.network) },
        tls = item_tls,
        custom_config = custom_config,
        source_tag = trim(outbound.tag),
        source_remarks = trim(config.remarks)
    }
end

local PARSERS = {
    vless = parse_vless,
    hysteria = parse_hysteria,
    shadowsocks = parse_shadowsocks
}

function M.parse(content)
    if not cjson then
        return nil, "lua-cjson is unavailable"
    end

    content = tostring(content or ""):gsub("^\239\187\191", "")
    local ok, decoded = pcall(cjson.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid JSON subscription: " .. tostring(decoded)
    end

    local configs = decoded
    if type(decoded.outbounds) == "table" then
        configs = { decoded }
    elseif #decoded == 0 then
        return nil, "JSON root must be an array of Xray configurations or one Xray configuration object"
    end

    local info = {
        format = "json",
        lines = 0,
        parsed = 0,
        ignored = 0,
        unsupported = 0,
        safe_to_remove = true,
        errors = {}
    }
    local servers = {}
    local alias_indexes = {}

    for index, config in ipairs(configs) do
        info.lines = info.lines + 1
        local outbound = get_first_outbound(config)
        if type(outbound) ~= "table" then
            info.ignored = info.ignored + 1
            info.safe_to_remove = false
            info.errors[#info.errors + 1] = "item " .. index .. " has no outbounds[1]"
        else
            local protocol = trim(outbound.protocol):lower()
            local alias = trim(config.remarks)
            if alias == "" then
                alias = trim(outbound.tag)
            end
            if alias == "" then
                alias = protocol .. "-" .. tostring(index)
            end

            -- Count each named item in the feed, even if its protocol is not
            -- supported. This keeps later duplicate aliases on their original
            -- occurrence index while the result remains unsafe for deletion.
            alias_indexes[alias] = (alias_indexes[alias] or 0) + 1
            local alias_index = alias_indexes[alias]

            local parser = PARSERS[protocol]
            if not parser then
                info.unsupported = info.unsupported + 1
                info.safe_to_remove = false
                info.errors[#info.errors + 1] = "item " .. index .. " uses unsupported protocol " .. protocol
            else
                local item, err = parser(outbound, config, alias)
                if not item then
                    info.ignored = info.ignored + 1
                    info.safe_to_remove = false
                    info.errors[#info.errors + 1] = "item " .. index .. " (" .. protocol .. "): " .. tostring(err)
                else
                    -- The normal UCI server model stores only one endpoint/user
                    -- per section. Do not allow a partial import to delete the rest.
                    if protocol == "vless" then
                        local settings = as_table(outbound.settings)
                        local vnext = as_table(settings.vnext)
                        local endpoint = as_table(first(vnext))
                        local users = as_table(endpoint.users)
                        if #vnext > 1 or #users > 1 then
                            info.safe_to_remove = false
                            info.errors[#info.errors + 1] = "item " .. index .. " contains multiple VLESS endpoints or users; only the first was imported"
                        end
                    elseif protocol == "shadowsocks" then
                        local settings = as_table(outbound.settings)
                        local ss_servers = as_table(settings.servers)
                        if #ss_servers > 1 then
                            info.safe_to_remove = false
                            info.errors[#info.errors + 1] = "item " .. index .. " contains multiple Shadowsocks servers; only the first was imported"
                        end
                    end

                    item.alias_index = alias_index
                    servers[#servers + 1] = item
                    info.parsed = info.parsed + 1
                end
            end
        end
    end

    if #servers == 0 then
        return nil, "JSON contains no supported server outbounds"
    end

    for _, server in ipairs(servers) do
        server.alias_count = alias_indexes[server.alias] or 1
    end

    return servers, info
end

return M
