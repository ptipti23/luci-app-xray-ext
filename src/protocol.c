
#include "xray_grpc_internal.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <lauxlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/*
 * =========================================================
 * VLESS outbound builder
 * Xray-core v26.10.21
 *
 * Supported:
 *   One server
 *   One user
 *   UUID
 *   Email
 *   Flow
 *   Encryption = none
 *
 * Other encryption modes use CLI fallback.
 * =========================================================
 */

#define VLESS_CONFIG_TYPE \
    "xray.proxy.vless.outbound.Config"

#define VLESS_ACCOUNT_TYPE \
    "xray.proxy.vless.Account"

#define HYSTERIA_CLIENT_CONFIG_TYPE \
    "xray.proxy.hysteria.ClientConfig"

#define SHADOWSOCKS_2022_CLIENT_CONFIG_TYPE \
    "xray.proxy.shadowsocks_2022.ClientConfig"


/* =========================================================
 * Lua helpers
 * =========================================================
 */

static int lua_abs_index(lua_State *L, int index)
{
    if (index > 0 || index <= LUA_REGISTRYINDEX)
        return index;

    return lua_gettop(L) + index + 1;
}


static void protocol_error(
    char *error,
    size_t error_len,
    const char *format,
    ...)
{
    va_list args;

    if (error == NULL || error_len == 0)
        return;

    va_start(args, format);
    vsnprintf(error, error_len, format, args);
    va_end(args);
}


/*
 * Strictly check supported fields.
 */
static xray_build_result check_settings_keys(
    lua_State *L,
    int table_index,
    char *error,
    size_t error_len)
{
    static const char * const allowed[] = {
        "address",
        "port",
        "id",
        "email",
        "flow",
        "encryption"
    };

    int top = lua_gettop(L);
    size_t i;

    table_index = lua_abs_index(L, table_index);

    if (lua_type(L, table_index) != LUA_TTABLE) {
        protocol_error(
            error,
            error_len,
            "VLESS settings must be a table"
        );

        return XRAY_BUILD_ERROR;
    }

    lua_pushnil(L);

    while (lua_next(L, table_index) != 0) {
        const char *key;
        size_t key_len;
        int found = 0;

        if (lua_type(L, -2) != LUA_TSTRING) {
            lua_settop(L, top);

            protocol_error(
                error,
                error_len,
                "VLESS settings contains a non-string key"
            );

            return XRAY_BUILD_ERROR;
        }

        key = lua_tolstring(L, -2, &key_len);

        for (i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
            if (strlen(allowed[i]) == key_len &&
                memcmp(key, allowed[i], key_len) == 0) {
                found = 1;
                break;
            }
        }

        if (!found) {
            protocol_error(
                error,
                error_len,
                "unsupported VLESS setting: %.*s",
                (int)key_len,
                key
            );

            lua_settop(L, top);

            return XRAY_BUILD_UNSUPPORTED;
        }

        lua_pop(L, 1);
    }

    lua_settop(L, top);

    return XRAY_BUILD_OK;
}


/*
 * Read an optional string field.
 */
static int get_string_field(
    lua_State *L,
    int table_index,
    const char *key,
    const char **value,
    size_t *value_len,
    char *error,
    size_t error_len)
{
    table_index = lua_abs_index(L, table_index);

    *value = NULL;
    *value_len = 0;

    lua_getfield(L, table_index, key);

    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }

    if (lua_type(L, -1) != LUA_TSTRING) {
        lua_pop(L, 1);

        protocol_error(
            error,
            error_len,
            "VLESS setting '%s' must be a string",
            key
        );

        return -1;
    }

    *value = lua_tolstring(L, -1, value_len);

    if (memchr(*value, '\0', *value_len) != NULL) {
        lua_pop(L, 1);

        protocol_error(
            error,
            error_len,
            "VLESS setting '%s' contains NUL",
            key
        );

        *value = NULL;
        *value_len = 0;

        return -1;
    }

    lua_pop(L, 1);

    return 0;
}


/* =========================================================
 * UUID validation and normalization
 *
 * Standard 36-character and compact 32-character UUIDs.
 *
 * Other formats are left to the CLI fallback.
 * =========================================================
 */

static int normalize_uuid(
    const char *input,
    size_t input_len,
    char output[37])
{
    char compact[32];
    size_t i;
    size_t out = 0;

    if (input == NULL)
        return -1;

    if (input_len != 32 && input_len != 36)
        return 1;

    if (input_len == 36) {
        if (input[8] != '-' ||
            input[13] != '-' ||
            input[18] != '-' ||
            input[23] != '-')
            return -1;
    }

    for (i = 0; i < input_len; i++) {
        unsigned char ch = (unsigned char)input[i];

        if (ch == '-')
            continue;

        if (!isxdigit(ch))
            return -1;

        if (out >= sizeof(compact))
            return -1;

        compact[out++] = (char)tolower(ch);
    }

    if (out != sizeof(compact))
        return -1;

    memcpy(output, compact, 8);
    output[8] = '-';

    memcpy(output + 9, compact + 8, 4);
    output[13] = '-';

    memcpy(output + 14, compact + 12, 4);
    output[18] = '-';

    memcpy(output + 19, compact + 16, 4);
    output[23] = '-';

    memcpy(output + 24, compact + 20, 12);

    output[36] = '\0';

    return 0;
}


/* =========================================================
 * IPOrDomain builder
 *
 * IPOrDomain:
 *   field 1 = IPv4/IPv6 bytes
 *   field 2 = domain string
 * =========================================================
 */

static int build_address(
    const char *address,
    size_t address_len,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    char host[256];

    uint8_t ip[16];

    size_t host_len;

    if (address == NULL || address_len == 0) {
        protocol_error(
            error,
            error_len,
            "VLESS server address is missing"
        );

        return -1;
    }

    if (address_len >= sizeof(host)) {
        protocol_error(
            error,
            error_len,
            "VLESS server address is too long"
        );

        return -1;
    }

    memcpy(host, address, address_len);
    host[address_len] = '\0';

    host_len = address_len;

    if (inet_pton(AF_INET, host, ip) == 1) {
        return xray_pb_append_bytes(
            result,
            1,
            ip,
            4
        );
    }

    if (inet_pton(AF_INET6, host, ip) == 1) {
        return xray_pb_append_bytes(
            result,
            1,
            ip,
            16
        );
    }

    /*
     * A string containing ':' but not a valid IPv6 address
     * is not treated as a domain.
     */
    if (strchr(host, ':') != NULL ||
        host[0] == '[' ||
        host[host_len - 1] == ']') {
        protocol_error(
            error,
            error_len,
            "invalid VLESS IP address: %s",
            host
        );

        return -1;
    }

    return xray_pb_append_string(
        result,
        2,
        host
    );
}


/* =========================================================
 * VLESS Account
 * =========================================================
 */

static int build_vless_account(
    const char *id,
    const char *flow,
    const char *encryption,
    xray_pb_buffer *result)
{
    xray_pb_buffer account;

    int rc = -1;

    xray_pb_buffer_init(&account);
    xray_pb_buffer_init(result);

    /*
     * Account:
     *
     * id         = 1
     * flow       = 2
     * encryption = 3
     */

    if (xray_pb_append_string(
            &account,
            1,
            id) != 0)
        goto cleanup;

    if (flow != NULL && flow[0] != '\0' &&
        xray_pb_append_string(
            &account,
            2,
            flow) != 0)
        goto cleanup;

    if (xray_pb_append_string(
            &account,
            3,
            encryption) != 0)
        goto cleanup;

    if (xray_pb_make_typed_message(
            VLESS_ACCOUNT_TYPE,
            &account,
            result) != 0)
        goto cleanup;

    rc = 0;

cleanup:
    xray_pb_buffer_clear(&account);

    if (rc != 0)
        xray_pb_buffer_clear(result);

    return rc;
}


/* =========================================================
 * VLESS User
 * =========================================================
 */

static int build_vless_user(
    const char *email,
    const char *id,
    const char *flow,
    const char *encryption,
    xray_pb_buffer *result)
{
    xray_pb_buffer account;

    int rc = -1;

    xray_pb_buffer_init(&account);
    xray_pb_buffer_init(result);

    if (build_vless_account(
            id,
            flow,
            encryption,
            &account) != 0)
        goto cleanup;

    /*
     * User:
     *
     * level   = 1 (default 0, omitted)
     * email   = 2
     * account = 3 (TypedMessage)
     */

    if (email != NULL && email[0] != '\0' &&
        xray_pb_append_string(
            result,
            2,
            email) != 0)
        goto cleanup;

    if (xray_pb_append_message(
            result,
            3,
            &account) != 0)
        goto cleanup;

    rc = 0;

cleanup:
    xray_pb_buffer_clear(&account);

    if (rc != 0)
        xray_pb_buffer_clear(result);

    return rc;
}


/* =========================================================
 * VLESS outbound Config
 * =========================================================
 */

xray_build_result xray_build_vless_proxy_settings(
    lua_State *L,
    int outbound_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    xray_pb_buffer address_message;
    xray_pb_buffer user_message;
    xray_pb_buffer endpoint;
    xray_pb_buffer config;

    const char *protocol = NULL;
    size_t protocol_len = 0;

    const char *address = NULL;
    size_t address_len = 0;

    const char *id = NULL;
    size_t id_len = 0;

    const char *email = NULL;
    size_t email_len = 0;

    const char *flow = NULL;
    size_t flow_len = 0;

    const char *encryption = NULL;
    size_t encryption_len = 0;

    char normalized_id[37];

    char *end = NULL;

    lua_Number port_number;
    lua_Integer port_integer;

    uint32_t port;

    int top;
    int settings_index;

    xray_build_result status = XRAY_BUILD_ERROR;

    if (error != NULL && error_len != 0)
        error[0] = '\0';

    if (L == NULL || result == NULL) {
        protocol_error(
            error,
            error_len,
            "invalid VLESS builder arguments"
        );

        return XRAY_BUILD_ERROR;
    }

    top = lua_gettop(L);
    outbound_index = lua_abs_index(L, outbound_index);

    xray_pb_buffer_init(result);
    xray_pb_buffer_init(&address_message);
    xray_pb_buffer_init(&user_message);
    xray_pb_buffer_init(&endpoint);
    xray_pb_buffer_init(&config);

    if (lua_type(L, outbound_index) != LUA_TTABLE) {
        protocol_error(
            error,
            error_len,
            "outbound must be a table"
        );

        goto cleanup;
    }

    /*
     * Check protocol.
     */

    if (get_string_field(
            L,
            outbound_index,
            "protocol",
            &protocol,
            &protocol_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (protocol == NULL ||
        protocol_len != 5 ||
        memcmp(protocol, "vless", 5) != 0) {
        protocol_error(
            error,
            error_len,
            "native VLESS builder received another protocol"
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    /*
     * Read settings table.
     */

    lua_getfield(
        L,
        outbound_index,
        "settings"
    );

    if (lua_type(L, -1) != LUA_TTABLE) {
        protocol_error(
            error,
            error_len,
            "VLESS settings must be a table"
        );

        goto cleanup;
    }

    settings_index = lua_abs_index(L, -1);

    status = check_settings_keys(
        L,
        settings_index,
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    if (get_string_field(
            L,
            settings_index,
            "address",
            &address,
            &address_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (get_string_field(
            L,
            settings_index,
            "id",
            &id,
            &id_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (get_string_field(
            L,
            settings_index,
            "email",
            &email,
            &email_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (get_string_field(
            L,
            settings_index,
            "flow",
            &flow,
            &flow_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (get_string_field(
            L,
            settings_index,
            "encryption",
            &encryption,
            &encryption_len,
            error,
            error_len) != 0)
        goto cleanup;

    /*
     * Required values.
     */

    if (address == NULL || address_len == 0) {
        protocol_error(
            error,
            error_len,
            "VLESS server address is missing"
        );

        goto cleanup;
    }

    if (id == NULL || id_len == 0) {
        protocol_error(
            error,
            error_len,
            "VLESS user ID is missing"
        );

        goto cleanup;
    }

    if (encryption == NULL || encryption_len == 0) {
        protocol_error(
            error,
            error_len,
            "VLESS encryption is missing"
        );

        goto cleanup;
    }

    /*
     * UUID normalization.
     *
     * Xray supports additional UUID formats through its own
     * parser. Those are delegated to the CLI fallback.
     */

    {
        int uuid_result = normalize_uuid(
            id,
            id_len,
            normalized_id
        );

        if (uuid_result > 0) {
            protocol_error(
                error,
                error_len,
                "non-standard VLESS ID format"
            );

            status = XRAY_BUILD_UNSUPPORTED;
            goto cleanup;
        }

        if (uuid_result < 0) {
            protocol_error(
                error,
                error_len,
                "invalid VLESS UUID"
            );

            goto cleanup;
        }
    }

    /*
     * Flow validation.
     */

    if (flow != NULL && flow_len != 0 &&
        strcmp(flow, "xtls-rprx-vision") != 0 &&
        strcmp(flow, "xtls-rprx-vision-udp443") != 0) {
        protocol_error(
            error,
            error_len,
            "unsupported VLESS flow: %s",
            flow
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    /*
     * Encryption:
     *
     * Native builder initially supports only "none".
     * New ML-KEM modes are delegated to CLI.
     */

    if (strcmp(encryption, "none") != 0) {
        protocol_error(
            error,
            error_len,
            "unsupported VLESS encryption mode"
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    /*
     * Validate and read port.
     */

    lua_getfield(
        L,
        settings_index,
        "port"
    );

    if (lua_type(L, -1) != LUA_TNUMBER) {
        lua_pop(L, 1);

        protocol_error(
            error,
            error_len,
            "VLESS port must be a number"
        );

        goto cleanup;
    }

    port_number = lua_tonumber(L, -1);
    port_integer = lua_tointeger(L, -1);

    lua_pop(L, 1);

    if (port_number < 1 ||
        port_number > 65535 ||
        (lua_Number)port_integer != port_number) {
        protocol_error(
            error,
            error_len,
            "VLESS port must be an integer from 1 to 65535"
        );

        goto cleanup;
    }

    port = (uint32_t)port_integer;

    /*
     * Build IPOrDomain.
     */

    if (build_address(
            address,
            address_len,
            &address_message,
            error,
            error_len) != 0)
        goto cleanup;

    /*
     * Build User.
     */

    if (build_vless_user(
            email,
            normalized_id,
            flow,
            encryption,
            &user_message) != 0) {
        protocol_error(
            error,
            error_len,
            "cannot encode VLESS User"
        );

        goto cleanup;
    }

    /*
     * ServerEndpoint:
     *
     * address = 1
     * port    = 2
     * user    = 3
     */

    if (xray_pb_append_message(
            &endpoint,
            1,
            &address_message) != 0)
        goto encode_error;

    if (xray_pb_append_uint(
            &endpoint,
            2,
            port) != 0)
        goto encode_error;

    if (xray_pb_append_message(
            &endpoint,
            3,
            &user_message) != 0)
        goto encode_error;

    /*
     * VLESS outbound Config:
     *
     * vnext = 1
     */

    if (xray_pb_append_message(
            &config,
            1,
            &endpoint) != 0)
        goto encode_error;

    if (xray_pb_make_typed_message(
            VLESS_CONFIG_TYPE,
            &config,
            result) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    protocol_error(
        error,
        error_len,
        "cannot encode VLESS protobuf"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    lua_settop(L, top);

    xray_pb_buffer_clear(&address_message);
    xray_pb_buffer_clear(&user_message);
    xray_pb_buffer_clear(&endpoint);
    xray_pb_buffer_clear(&config);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}


/* =========================================================
 * Hysteria v2 outbound builder
 * Xray-core v26.10.21
 * =========================================================
 */

static xray_build_result check_hysteria_settings_keys(
    lua_State *L,
    int table_index,
    char *error,
    size_t error_len)
{
    static const char * const allowed[] = {
        "version",
        "address",
        "port"
    };

    int top = lua_gettop(L);
    size_t i;

    table_index = lua_abs_index(L, table_index);

    if (lua_type(L, table_index) != LUA_TTABLE) {
        protocol_error(
            error, error_len,
            "Hysteria settings must be a table"
        );

        return XRAY_BUILD_ERROR;
    }

    lua_pushnil(L);

    while (lua_next(L, table_index) != 0) {
        const char *key;
        size_t key_len;
        int found = 0;

        if (lua_type(L, -2) != LUA_TSTRING) {
            lua_settop(L, top);

            protocol_error(
                error, error_len,
                "Hysteria settings contains a non-string key"
            );

            return XRAY_BUILD_ERROR;
        }

        key = lua_tolstring(L, -2, &key_len);

        for (i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
            if (strlen(allowed[i]) == key_len &&
                memcmp(key, allowed[i], key_len) == 0) {
                found = 1;
                break;
            }
        }

        if (!found) {
            protocol_error(
                error, error_len,
                "unsupported Hysteria setting: %.*s",
                (int)key_len, key
            );

            lua_settop(L, top);
            return XRAY_BUILD_UNSUPPORTED;
        }

        lua_pop(L, 1);
    }

    lua_settop(L, top);

    return XRAY_BUILD_OK;
}

xray_build_result xray_build_hysteria_proxy_settings(
    lua_State *L,
    int outbound_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    xray_pb_buffer address_message;
    xray_pb_buffer endpoint;
    xray_pb_buffer config;

    const char *protocol = NULL;
    size_t protocol_len = 0;

    const char *address = NULL;
    size_t address_len = 0;

    lua_Number version_number;
    lua_Number port_number;

    lua_Integer version_integer;
    lua_Integer port_integer;

    int top;
    int settings_index;

    xray_build_result status = XRAY_BUILD_ERROR;

    if (error != NULL && error_len != 0)
        error[0] = '\0';

    if (L == NULL || result == NULL) {
        protocol_error(
            error, error_len,
            "invalid Hysteria builder arguments"
        );

        return XRAY_BUILD_ERROR;
    }

    top = lua_gettop(L);
    outbound_index = lua_abs_index(L, outbound_index);

    xray_pb_buffer_init(result);
    xray_pb_buffer_init(&address_message);
    xray_pb_buffer_init(&endpoint);
    xray_pb_buffer_init(&config);

    if (lua_type(L, outbound_index) != LUA_TTABLE) {
        protocol_error(
            error, error_len,
            "outbound must be a table"
        );

        goto cleanup;
    }

    /*
     * Verify protocol.
     */

    if (get_string_field(
            L,
            outbound_index,
            "protocol",
            &protocol,
            &protocol_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (protocol == NULL ||
        protocol_len != 8 ||
        memcmp(protocol, "hysteria", 8) != 0) {
        protocol_error(
            error, error_len,
            "native Hysteria builder received another protocol"
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    /*
     * Read settings.
     */

    lua_getfield(L, outbound_index, "settings");

    if (lua_type(L, -1) != LUA_TTABLE) {
        protocol_error(
            error, error_len,
            "Hysteria settings must be a table"
        );

        goto cleanup;
    }

    settings_index = lua_abs_index(L, -1);

    status = check_hysteria_settings_keys(
        L,
        settings_index,
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    /*
     * Version must be exactly 2.
     *
     * Version is validated by Xray but is not
     * serialized into ClientConfig.
     */

    lua_getfield(L, settings_index, "version");

    if (lua_type(L, -1) != LUA_TNUMBER) {
        lua_pop(L, 1);

        protocol_error(
            error, error_len,
            "Hysteria version must be 2"
        );

        goto cleanup;
    }

    version_number = lua_tonumber(L, -1);
    version_integer = lua_tointeger(L, -1);

    lua_pop(L, 1);

    if ((lua_Number)version_integer != version_number ||
        version_integer != 2) {
        protocol_error(
            error, error_len,
            "unsupported Hysteria version"
        );

        goto cleanup;
    }

    /*
     * Server address.
     */

    if (get_string_field(
            L,
            settings_index,
            "address",
            &address,
            &address_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (address == NULL || address_len == 0) {
        protocol_error(
            error, error_len,
            "Hysteria server address is missing"
        );

        goto cleanup;
    }

    /*
     * Server port.
     */

    lua_getfield(L, settings_index, "port");

    if (lua_type(L, -1) != LUA_TNUMBER) {
        lua_pop(L, 1);

        protocol_error(
            error, error_len,
            "Hysteria port must be a number"
        );

        goto cleanup;
    }

    port_number = lua_tonumber(L, -1);
    port_integer = lua_tointeger(L, -1);

    lua_pop(L, 1);

    if (port_number < 1 ||
        port_number > 65535 ||
        (lua_Number)port_integer != port_number) {
        protocol_error(
            error, error_len,
            "Hysteria port must be an integer from 1 to 65535"
        );

        goto cleanup;
    }

    /*
     * Build IPOrDomain.
     *
     * IPv4 / IPv6 -> field 1
     * Domain      -> field 2
     */

    if (build_address(
            address,
            address_len,
            &address_message,
            error,
            error_len) != 0)
        goto cleanup;

    /*
     * ServerEndpoint:
     *
     * address = 1
     * port    = 2
     */

    if (xray_pb_append_message(
            &endpoint,
            1,
            &address_message) != 0)
        goto encode_error;

    if (xray_pb_append_uint(
            &endpoint,
            2,
            (uint32_t)port_integer) != 0)
        goto encode_error;

    /*
     * Hysteria ClientConfig:
     *
     * server = 1
     */

    if (xray_pb_append_message(
            &config,
            1,
            &endpoint) != 0)
        goto encode_error;

    if (xray_pb_make_typed_message(
            HYSTERIA_CLIENT_CONFIG_TYPE,
            &config,
            result) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    protocol_error(
        error, error_len,
        "cannot encode Hysteria ClientConfig protobuf"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    lua_settop(L, top);

    xray_pb_buffer_clear(&address_message);
    xray_pb_buffer_clear(&endpoint);
    xray_pb_buffer_clear(&config);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}


/* =========================================================
 * Shadowsocks 2022 outbound builder
 * Xray-core v26.10.21
 * =========================================================
 */

static xray_build_result check_shadowsocks_2022_settings_keys(
    lua_State *L,
    int table_index,
    char *error,
    size_t error_len)
{
    static const char * const allowed[] = {
        "address",
        "port",
        "password",
        "method",
        "email",
        "uot"
    };

    int top = lua_gettop(L);
    size_t i;

    table_index = lua_abs_index(L, table_index);

    if (lua_type(L, table_index) != LUA_TTABLE) {
        protocol_error(
            error, error_len,
            "Shadowsocks settings must be a table"
        );

        return XRAY_BUILD_ERROR;
    }

    lua_pushnil(L);

    while (lua_next(L, table_index) != 0) {
        const char *key;
        size_t key_len;
        int found = 0;

        if (lua_type(L, -2) != LUA_TSTRING) {
            lua_settop(L, top);

            protocol_error(
                error, error_len,
                "Shadowsocks settings contains a non-string key"
            );

            return XRAY_BUILD_ERROR;
        }

        key = lua_tolstring(L, -2, &key_len);

        for (i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
            if (strlen(allowed[i]) == key_len &&
                memcmp(key, allowed[i], key_len) == 0) {
                found = 1;
                break;
            }
        }

        if (!found) {
            protocol_error(
                error, error_len,
                "unsupported Shadowsocks setting: %.*s",
                (int)key_len, key
            );

            lua_settop(L, top);
            return XRAY_BUILD_UNSUPPORTED;
        }

        lua_pop(L, 1);
    }

    lua_settop(L, top);

    return XRAY_BUILD_OK;
}


xray_build_result xray_build_shadowsocks_2022_proxy_settings(
    lua_State *L,
    int outbound_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    static const char * const supported_methods[] = {
        "2022-blake3-aes-128-gcm",
        "2022-blake3-aes-256-gcm",
        "2022-blake3-chacha20-poly1305"
    };

    xray_pb_buffer address_message;
    xray_pb_buffer config;

    const char *protocol = NULL;
    size_t protocol_len = 0;

    const char *address = NULL;
    size_t address_len = 0;

    const char *method = NULL;
    size_t method_len = 0;

    const char *password = NULL;
    size_t password_len = 0;

    lua_Number port_number;
    lua_Integer port_integer;

    size_t i;
    int method_supported = 0;

    int top;
    int settings_index;

    xray_build_result status = XRAY_BUILD_ERROR;

    if (error != NULL && error_len != 0)
        error[0] = '\0';

    if (L == NULL || result == NULL) {
        protocol_error(
            error, error_len,
            "invalid Shadowsocks builder arguments"
        );

        return XRAY_BUILD_ERROR;
    }

    top = lua_gettop(L);
    outbound_index = lua_abs_index(L, outbound_index);

    xray_pb_buffer_init(result);
    xray_pb_buffer_init(&address_message);
    xray_pb_buffer_init(&config);

    if (lua_type(L, outbound_index) != LUA_TTABLE) {
        protocol_error(
            error, error_len,
            "outbound must be a table"
        );

        goto cleanup;
    }

    /*
     * Verify protocol.
     */

    if (get_string_field(
            L,
            outbound_index,
            "protocol",
            &protocol,
            &protocol_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (protocol == NULL ||
        protocol_len != 11 ||
        memcmp(protocol, "shadowsocks", 11) != 0) {
        protocol_error(
            error, error_len,
            "native Shadowsocks builder received another protocol"
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    /*
     * Read settings.
     */

    lua_getfield(L, outbound_index, "settings");

    if (lua_type(L, -1) != LUA_TTABLE) {
        protocol_error(
            error, error_len,
            "Shadowsocks settings must be a table"
        );

        goto cleanup;
    }

    settings_index = lua_abs_index(L, -1);

    status = check_shadowsocks_2022_settings_keys(
        L,
        settings_index,
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    /*
     * UDP-over-TCP is not represented in SS2022 ClientConfig.
     * Keep the existing CLI fallback for this case.
     */

    lua_getfield(L, settings_index, "uot");

    if (lua_type(L, -1) != LUA_TNIL &&
        lua_type(L, -1) != LUA_TBOOLEAN) {
        lua_pop(L, 1);

        protocol_error(
            error, error_len,
            "Shadowsocks uot must be a boolean"
        );

        goto cleanup;
    }

    if (lua_toboolean(L, -1)) {
        lua_pop(L, 1);

        protocol_error(
            error, error_len,
            "native SS2022 does not support UDP-over-TCP"
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    lua_pop(L, 1);

    /*
     * Encryption method.
     */

    if (get_string_field(
            L,
            settings_index,
            "method",
            &method,
            &method_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (method == NULL || method_len == 0) {
        protocol_error(
            error, error_len,
            "Shadowsocks method is missing"
        );

        goto cleanup;
    }

    for (i = 0;
         i < sizeof(supported_methods) / sizeof(supported_methods[0]);
         i++) {
        if (strlen(supported_methods[i]) == method_len &&
            memcmp(method, supported_methods[i], method_len) == 0) {
            method_supported = 1;
            break;
        }
    }

    if (!method_supported) {
        protocol_error(
            error, error_len,
            "unsupported native Shadowsocks method: %.*s",
            (int)method_len, method
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    /*
     * Password / SS2022 key.
     *
     * Keep the complete value unchanged.
     * In particular, do not split the two Base64 components.
     */

    if (get_string_field(
            L,
            settings_index,
            "password",
            &password,
            &password_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (password == NULL || password_len == 0) {
        protocol_error(
            error, error_len,
            "Shadowsocks password is missing"
        );

        goto cleanup;
    }

    /*
     * Server address.
     */

    if (get_string_field(
            L,
            settings_index,
            "address",
            &address,
            &address_len,
            error,
            error_len) != 0)
        goto cleanup;

    if (address == NULL || address_len == 0) {
        protocol_error(
            error, error_len,
            "Shadowsocks server address is missing"
        );

        goto cleanup;
    }

    /*
     * Server port.
     */

    lua_getfield(L, settings_index, "port");

    if (lua_type(L, -1) != LUA_TNUMBER) {
        lua_pop(L, 1);

        protocol_error(
            error, error_len,
            "Shadowsocks port must be a number"
        );

        goto cleanup;
    }

    port_number = lua_tonumber(L, -1);
    port_integer = lua_tointeger(L, -1);

    lua_pop(L, 1);

    if (port_number < 1 ||
        port_number > 65535 ||
        (lua_Number)port_integer != port_number) {
        protocol_error(
            error, error_len,
            "Shadowsocks port must be an integer from 1 to 65535"
        );

        goto cleanup;
    }

    /*
     * Build IPOrDomain.
     */

    if (build_address(
            address,
            address_len,
            &address_message,
            error,
            error_len) != 0)
        goto cleanup;

    /*
     * Shadowsocks 2022 ClientConfig:
     *
     * address = 1
     * port    = 2
     * method  = 3
     * key     = 4
     */

    if (xray_pb_append_message(
            &config,
            1,
            &address_message) != 0)
        goto encode_error;

    if (xray_pb_append_uint(
            &config,
            2,
            (uint32_t)port_integer) != 0)
        goto encode_error;

    if (xray_pb_append_string(
            &config,
            3,
            method) != 0)
        goto encode_error;

    if (xray_pb_append_string(
            &config,
            4,
            password) != 0)
        goto encode_error;

    if (xray_pb_make_typed_message(
            SHADOWSOCKS_2022_CLIENT_CONFIG_TYPE,
            &config,
            result) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    protocol_error(
        error, error_len,
        "cannot encode Shadowsocks 2022 ClientConfig protobuf"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    lua_settop(L, top);

    xray_pb_buffer_clear(&address_message);
    xray_pb_buffer_clear(&config);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}
