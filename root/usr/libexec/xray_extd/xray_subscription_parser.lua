-- xray_subscription_parser.lua
-- Pure parsing layer for Xray Extended subscription updates.
-- No UCI writes, service restarts, or network requests are performed here.

local M = {}

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUE = {}
for i = 1, #B64_ALPHABET do
    B64_VALUE[B64_ALPHABET:sub(i, i)] = i - 1
end

local function url_decode(value)
    value = tostring(value or "")
    value = value:gsub("%+", " ")
    value = value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return value
end

local function base64_decode(value)
    if type(value) ~= "string" then
        return nil, "base64 input is not a string"
    end

    value = value:gsub("%s", ""):gsub("-", "+"):gsub("_", "/")
    if value == "" then
        return nil, "empty base64 input"
    end

    if value:find("[^A-Za-z0-9+/=]") then
        return nil, "invalid character in base64 input"
    end

    if #value % 4 == 1 then
        return nil, "invalid base64 length"
    end

    while #value % 4 ~= 0 do
        value = value .. "="
    end

    local output = {}
    local pos = 1
    while pos <= #value do
        local c1 = value:sub(pos, pos)
        local c2 = value:sub(pos + 1, pos + 1)
        local c3 = value:sub(pos + 2, pos + 2)
        local c4 = value:sub(pos + 3, pos + 3)

        local a = B64_VALUE[c1]
        local b = B64_VALUE[c2]
        if a == nil or b == nil then
            return nil, "invalid base64 quartet"
        end

        local pad3 = c3 == "="
        local pad4 = c4 == "="
        if pad3 and not pad4 then
            return nil, "invalid base64 padding"
        end
        if (pad3 or pad4) and pos + 3 < #value then
            return nil, "base64 padding before end of input"
        end

        local c = pad3 and 0 or B64_VALUE[c3]
        local d = pad4 and 0 or B64_VALUE[c4]
        if c == nil or d == nil then
            return nil, "invalid base64 quartet"
        end

        local n = a * 262144 + b * 4096 + c * 64 + d
        output[#output + 1] = string.char(math.floor(n / 65536) % 256)
        if not pad3 then
            output[#output + 1] = string.char(math.floor(n / 256) % 256)
        end
        if not pad4 then
            output[#output + 1] = string.char(n % 256)
        end

        pos = pos + 4
    end

    return table.concat(output)
end

local function has_uri_line(content)
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        line = trim(line)
        if line:match("^[%w+%.%-]+://") then
            return true
        end
    end
    return false
end

local function decode_subscription_body(content)
    content = tostring(content or "")
    content = content:gsub("^\239\187\191", "") -- UTF-8 BOM

    if has_uri_line(content) then
        return content, "plain"
    end

    local decoded, err = base64_decode(content)
    if not decoded or not has_uri_line(decoded) then
        return nil, "content is neither a recognised URI list nor base64 URI list" ..
            (err and (" (" .. err .. ")") or "")
    end

    return decoded, "base64"
end

local function split_fragment(value)
    local before, fragment = value:match("^(.-)#(.*)$")
    if before == nil then
        return value, ""
    end
    return before, trim(url_decode(fragment))
end

local function split_query(value)
    local before, query = value:match("^(.-)%?(.*)$")
    if before == nil then
        return value, ""
    end
    return before, query
end

local function parse_query(query)
    local params = {}
    if not query or query == "" then
        return params
    end

    for item in (query .. "&"):gmatch("(.-)&") do
        if item ~= "" then
            local key, value = item:match("^([^=]*)=(.*)$")
            if key == nil then
                key, value = item, ""
            end
            key = url_decode(key)
            value = url_decode(value)
            params[key] = value
        end
    end

    return params
end

local function parse_hostport(value)
    value = trim(value)
    if value == "" then
        return nil, nil, "missing host and port"
    end

    local host, port = value:match("^%[(.-)%]:(%d+)$")
    if not host then
        -- Greedy host preserves unbracketed IPv6 by splitting on the final colon.
        host, port = value:match("^(.+):(%d+)$")
    end

    if not host or host == "" or not port then
        return nil, nil, "host must be followed by a numeric port"
    end

    port = tonumber(port)
    if not port or port < 1 or port > 65535 then
        return nil, nil, "port is outside 1..65535"
    end

    return host, port
end

local function common_uri_parts(uri)
    local scheme, body = uri:match("^([%w+%.%-]+)://(.*)$")
    if not scheme then
        return nil, nil, nil, nil, "invalid URI scheme"
    end

    local without_fragment, alias = split_fragment(body)
    local authority_and_path, query = split_query(without_fragment)
    local userinfo, hostport = authority_and_path:match("^(.-)@(.+)$")
    if not userinfo then
        return scheme:lower(), nil, nil, alias, query, "missing user information or @ separator"
    end

    return scheme:lower(), userinfo, hostport, alias, query
end

local function parse_vless(uri)
    local scheme, uuid, hostport, alias, query, common_error = common_uri_parts(uri)
    if common_error then
        return nil, common_error
    end

    uuid = url_decode(uuid)
    if uuid == "" then
        return nil, "VLESS UUID is empty"
    end
    if alias == "" then
        return nil, "VLESS URI has no alias after #"
    end

    local server, port, host_error = parse_hostport(hostport)
    if not server then
        return nil, host_error
    end

    local params = parse_query(query)
    local security = (params.security or "none"):lower()
    local network = (params.type or params.net or "tcp"):lower()
    local transport_type = network == "xhttp" and "splithttp" or network
    local fingerprint = params.fp or "random"

    local item = {
        source_scheme = scheme,
        protocol = "vless",
        alias = alias,
        server = server,
        port = port,
        password = uuid,
        security = security,
        transport = {
            type = transport_type,
            source_type = network,
            path = params.path or "",
            mode = params.mode or "",
            extra = params.extra or ""
        },
        tls = {
            mode = security,
            server_name = params.sni or "",
            fingerprint = fingerprint,
            public_key = params.pbk or "",
            short_id = params.sid or "",
            flow = params.flow or "",
            insecure = params.insecure or "",
            alpn = params.alpn or ""
        },
        source_uri = uri
    }

    return item
end

local function parse_hysteria2(uri)
    local scheme, auth, hostport, alias, query, common_error = common_uri_parts(uri)
    if common_error then
        return nil, common_error
    end

    auth = url_decode(auth)
    if auth == "" then
        return nil, "Hysteria2 authentication/password is empty"
    end
    if alias == "" then
        return nil, "Hysteria2 URI has no alias after #"
    end

    local server, port, host_error = parse_hostport(hostport)
    if not server then
        return nil, host_error
    end

    local params = parse_query(query)
    local extra_raw = params["xray-extra-params"] or ""
    local extra_json = ""
    local extra_options = {}

    if extra_raw ~= "" then
        local decoded = base64_decode(extra_raw)
        if decoded then
            extra_json = decoded
            local ok_cjson, cjson = pcall(require, "cjson")
            if ok_cjson and cjson and cjson.decode then
                local ok_json, value = pcall(cjson.decode, decoded)
                if ok_json and type(value) == "table" then
                    extra_options = value
                end
            end
        end
    end

    local item = {
        source_scheme = scheme,
        protocol = "hysteria",
        alias = alias,
        server = server,
        port = port,
        password = auth,
        security = "tls",
        transport = {
            type = "hysteria"
        },
        tls = {
            mode = "tls",
            server_name = params.sni or "",
            fingerprint = extra_options.fingerprint or "",
            alpn = params.alpn or ""
        },
        hysteria = {
            extra = extra_json,
            finalmask = extra_options.finalmask
        },
        source_uri = uri
    }

    return item
end

local function parse_shadowsocks(uri)
    local body = uri:match("^ss://(.*)$")
    if not body then
        return nil, "invalid Shadowsocks URI"
    end

    local without_fragment, alias = split_fragment(body)
    local authority, query = split_query(without_fragment)
    local method_password, hostport = authority:match("^(.-)@(.+)$")

    if not method_password then
        -- SIP002 variant: the entire method:password@host:port is base64 encoded.
        local decoded, err = base64_decode(authority)
        if not decoded then
            return nil, "Shadowsocks URI lacks @ separator and is not valid base64: " .. tostring(err)
        end
        method_password, hostport = decoded:match("^(.-)@(.+)$")
        if not method_password then
            return nil, "decoded Shadowsocks URI lacks method:password@host:port"
        end
    else
        -- The common legacy form encodes only method:password.
        local decoded = base64_decode(method_password)
        if decoded then
            method_password = decoded
        else
            method_password = url_decode(method_password)
        end
    end

    if alias == "" then
        return nil, "Shadowsocks URI has no alias after #"
    end

    local method, password = method_password:match("^([^:]+):(.*)$")
    if not method or password == nil or password == "" then
        return nil, "Shadowsocks authentication must be method:password"
    end

    local server, port, host_error = parse_hostport(hostport)
    if not server then
        return nil, host_error
    end

    if method == "chacha20-ietf-poly1305" then
        method = "chacha20-poly1305"
    end

    return {
        source_scheme = "ss",
        protocol = "shadowsocks",
        alias = alias,
        server = server,
        port = port,
        password = password,
        security = method,
        transport = {
            type = "tcp"
        },
        tls = {
            mode = "none"
        },
        source_uri = uri,
        ignored_query = query
    }
end

local PARSERS = {
    vless = parse_vless,
    hysteria2 = parse_hysteria2,
    ss = parse_shadowsocks
}

function M.decode_base64(value)
    return base64_decode(value)
end

function M.url_decode(value)
    return url_decode(value)
end

-- Returns servers, info on success; nil, error on unsafe/malformed input.
-- info.safe_to_remove is false if unsupported URI schemes were present, because
-- deleting servers from an incomplete parse could remove still-valid entries.
function M.parse(content)
    local body, format_or_error = decode_subscription_body(content)
    if not body then
        return nil, format_or_error
    end

    local info = {
        format = format_or_error,
        lines = 0,
        parsed = 0,
        ignored = 0,
        unsupported = 0,
        safe_to_remove = true,
        errors = {}
    }

    local servers = {}
    local alias_indexes = {}

    for line in (body .. "\n"):gmatch("(.-)\r?\n") do
        line = trim(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            info.lines = info.lines + 1
            local scheme = line:match("^([%w+%.%-]+)://")
            if not scheme then
                info.ignored = info.ignored + 1
                -- Do not permit deletion if the feed contains non-comment lines
                -- that this parser cannot account for.
                info.safe_to_remove = false
            else
                scheme = scheme:lower()
                local parser = PARSERS[scheme]
                if not parser then
                    info.unsupported = info.unsupported + 1
                    info.safe_to_remove = false
                    local uri_body = line:match("^[%w+%.%-]+://(.*)$") or line
                    local _, unknown_alias = split_fragment(uri_body)
                    if unknown_alias ~= "" then
                        alias_indexes[unknown_alias] = (alias_indexes[unknown_alias] or 0) + 1
                    end
                else
                    local item, err = parser(line)
                    if not item then
                        return nil, string.format("line %d (%s): %s", info.lines, scheme, tostring(err))
                    end

                    if item.server == "" or not item.port or not item.alias or item.alias == "" then
                        return nil, string.format("line %d (%s): missing required server fields", info.lines, scheme)
                    end

                    alias_indexes[item.alias] = (alias_indexes[item.alias] or 0) + 1
                    item.alias_index = alias_indexes[item.alias]
                    servers[#servers + 1] = item
                    info.parsed = info.parsed + 1
                end
            end
        end
    end

    if #servers == 0 then
        return nil, "no supported servers found in subscription"
    end

    if info.unsupported > 0 then
        info.safe_to_remove = false
    end

    for _, server in ipairs(servers) do
        server.alias_count = alias_indexes[server.alias] or 1
    end

    return servers, info
end

return M
