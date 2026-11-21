
#include "xray_grpc_internal.h"

#include <lauxlib.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <stdlib.h>

/*
 * =========================================================
 * Transport and security builders
 * Xray-core v26.10.21
 *
 * Currently supported:
 *   TCP + REALITY
 *   SplitHTTP
 *   TLS
 *   TCP custom settings
 *   FinalMask
 * =========================================================
 */

#define REALITY_TYPE \
    "xray.transport.internet.reality.Config"

#define TLS_TYPE \
    "xray.transport.internet.tls.Config"

#define SPLITHTTP_TYPE \
    "xray.transport.internet.splithttp.Config"

#define HYSTERIA_TRANSPORT_TYPE \
    "xray.transport.internet.hysteria.Config"

#define SENDER_CONFIG_TYPE \
    "xray.app.proxyman.SenderConfig"


/* =========================================================
 * Lua helpers
 * =========================================================
 */

/*
 * Lua 5.1 does not provide lua_absindex().
 */
static int lua_abs_index(lua_State *L, int index)
{
    if (index > 0 || index <= LUA_REGISTRYINDEX)
        return index;

    return lua_gettop(L) + index + 1;
}


static void builder_error(
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
 * Check that a Lua table contains only supported keys.
 *
 * Returns:
 *   XRAY_BUILD_OK
 *   XRAY_BUILD_UNSUPPORTED
 *   XRAY_BUILD_ERROR
 */
static xray_build_result check_table_keys(
    lua_State *L,
    int table_index,
    const char *object_name,
    const char * const *allowed,
    size_t allowed_count,
    char *error,
    size_t error_len)
{
    int top = lua_gettop(L);

    table_index = lua_abs_index(L, table_index);

    if (lua_type(L, table_index) != LUA_TTABLE) {
        builder_error(
            error,
            error_len,
            "%s must be a table",
            object_name
        );

        return XRAY_BUILD_ERROR;
    }

    lua_pushnil(L);

    while (lua_next(L, table_index) != 0) {
        const char *key;
        size_t key_len;
        size_t i;
        int found = 0;

        if (lua_type(L, -2) != LUA_TSTRING) {
            lua_settop(L, top);

            builder_error(
                error,
                error_len,
                "%s contains a non-string key",
                object_name
            );

            return XRAY_BUILD_ERROR;
        }

        key = lua_tolstring(L, -2, &key_len);

        for (i = 0; i < allowed_count; i++) {
            if (strlen(allowed[i]) == key_len &&
                memcmp(allowed[i], key, key_len) == 0) {
                found = 1;
                break;
            }
        }

        if (!found) {
            builder_error(
                error,
                error_len,
                "%s: unsupported field '%.*s'",
                object_name,
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
 * Read an optional string.
 *
 * Returns:
 *   0  success
 *  -1  invalid type or value
 */
static int get_optional_string(
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

        builder_error(
            error,
            error_len,
            "field '%s' must be a string",
            key
        );

        return -1;
    }

    *value = lua_tolstring(L, -1, value_len);

    if (memchr(*value, '\0', *value_len) != NULL) {
        lua_pop(L, 1);

        builder_error(
            error,
            error_len,
            "field '%s' contains a NUL byte",
            key
        );

        *value = NULL;
        *value_len = 0;

        return -1;
    }

    /*
     * The original Lua table still holds the string,
     * so the returned pointer remains valid.
     */
    lua_pop(L, 1);

    return 0;
}


static int get_optional_bool(
    lua_State *L,
    int table_index,
    const char *key,
    int *value,
    char *error,
    size_t error_len)
{
    table_index = lua_abs_index(L, table_index);

    *value = 0;

    lua_getfield(L, table_index, key);

    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }

    if (lua_type(L, -1) != LUA_TBOOLEAN) {
        lua_pop(L, 1);

        builder_error(
            error,
            error_len,
            "field '%s' must be a boolean",
            key
        );

        return -1;
    }

    *value = lua_toboolean(L, -1);

    lua_pop(L, 1);

    return 0;
}


static int get_optional_int32(
    lua_State *L,
    int table_index,
    const char *key,
    int32_t *value,
    char *error,
    size_t error_len)
{
    lua_Number number;
    lua_Integer integer;

    table_index = lua_abs_index(L, table_index);

    *value = 0;

    lua_getfield(L, table_index, key);

    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }

    if (lua_type(L, -1) != LUA_TNUMBER) {
        lua_pop(L, 1);

        builder_error(
            error,
            error_len,
            "field '%s' must be a number",
            key
        );

        return -1;
    }

    number = lua_tonumber(L, -1);

    if (number < (lua_Number)INT32_MIN ||
        number > (lua_Number)INT32_MAX) {
        lua_pop(L, 1);

        builder_error(
            error,
            error_len,
            "field '%s' is outside int32 range",
            key
        );

        return -1;
    }

    integer = lua_tointeger(L, -1);

    if ((lua_Number)integer != number) {
        lua_pop(L, 1);

        builder_error(
            error,
            error_len,
            "field '%s' must be an integer",
            key
        );

        return -1;
    }

    *value = (int32_t)integer;

    lua_pop(L, 1);

    return 0;
}


/* =========================================================
 * DomainStrategy
 * =========================================================
 */

static int map_domain_strategy(
    const char *value,
    uint64_t *result)
{
    if (value == NULL || value[0] == '\0' ||
        strcasecmp(value, "AsIs") == 0 ||
        strcasecmp(value, "AS_IS") == 0) {
        *result = 0;
        return 0;
    }

    if (strcasecmp(value, "UseIP") == 0) {
        *result = 1;
        return 0;
    }

    if (strcasecmp(value, "UseIPv4") == 0) {
        *result = 2;
        return 0;
    }

    if (strcasecmp(value, "UseIPv6") == 0) {
        *result = 3;
        return 0;
    }

    if (strcasecmp(value, "UseIPv4v6") == 0) {
        *result = 4;
        return 0;
    }

    if (strcasecmp(value, "UseIPv6v4") == 0) {
        *result = 5;
        return 0;
    }

    if (strcasecmp(value, "ForceIP") == 0) {
        *result = 6;
        return 0;
    }

    if (strcasecmp(value, "ForceIPv4") == 0) {
        *result = 7;
        return 0;
    }

    if (strcasecmp(value, "ForceIPv6") == 0) {
        *result = 8;
        return 0;
    }

    if (strcasecmp(value, "ForceIPv4v6") == 0) {
        *result = 9;
        return 0;
    }

    if (strcasecmp(value, "ForceIPv6v4") == 0) {
        *result = 10;
        return 0;
    }

    return -1;
}


/* =========================================================
 * Base64 URL decoder
 *
 * Equivalent to Go:
 *   base64.RawURLEncoding.DecodeString()
 * =========================================================
 */

static int base64url_value(char ch)
{
    if (ch >= 'A' && ch <= 'Z')
        return ch - 'A';

    if (ch >= 'a' && ch <= 'z')
        return ch - 'a' + 26;

    if (ch >= '0' && ch <= '9')
        return ch - '0' + 52;

    if (ch == '-')
        return 62;

    if (ch == '_')
        return 63;

    return -1;
}


static int decode_base64url_32(
    const char *input,
    size_t input_len,
    uint8_t output[32])
{
    uint32_t accumulator = 0;
    unsigned int bits = 0;
    size_t output_len = 0;
    size_t i;

    if (input == NULL || input_len == 0)
        return -1;

    for (i = 0; i < input_len; i++) {
        int value = base64url_value(input[i]);

        if (value < 0)
            return -1;

        accumulator =
            (accumulator << 6) | (uint32_t)value;

        bits += 6;

        if (bits >= 8) {
            bits -= 8;

            if (output_len >= 32)
                return -1;

            output[output_len++] =
                (uint8_t)(accumulator >> bits);
        }
    }

    /*
     * A 32-byte key has 43 unpadded Base64URL
     * characters and exactly two trailing zero bits.
     */
    if (output_len != 32 || bits != 2 ||
        (accumulator & 0x03) != 0)
        return -1;

    return 0;
}


/* =========================================================
 * Hex decoder for REALITY shortId
 * =========================================================
 */

static int hex_value(char ch)
{
    if (ch >= '0' && ch <= '9')
        return ch - '0';

    if (ch >= 'a' && ch <= 'f')
        return ch - 'a' + 10;

    if (ch >= 'A' && ch <= 'F')
        return ch - 'A' + 10;

    return -1;
}


static int decode_short_id(
    const char *input,
    size_t input_len,
    uint8_t output[8],
    size_t *output_len)
{
    size_t i;

    *output_len = 0;

    if (input_len == 0)
        return 0;

    if (input_len > 16 || (input_len % 2) != 0)
        return -1;

    for (i = 0; i < input_len; i += 2) {
        int high = hex_value(input[i]);
        int low = hex_value(input[i + 1]);

        if (high < 0 || low < 0)
            return -1;

        output[*output_len] =
            (uint8_t)((high << 4) | low);

        (*output_len)++;
    }

    return 0;
}


/* =========================================================
 * REALITY Config -> TypedMessage
 * =========================================================
 */

static xray_build_result build_reality_settings(
    lua_State *L,
    int reality_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    static const char * const allowed_keys[] = {
        "show",
        "fingerprint",
        "serverName",
        "password",
        "publicKey",
        "shortId",
        "spiderX"
    };

    xray_pb_buffer payload;

    const char *password = NULL;
    size_t password_len = 0;

    const char *public_key = NULL;
    size_t public_key_len = 0;

    const char *server_name = NULL;
    size_t server_name_len = 0;

    const char *fingerprint = NULL;
    size_t fingerprint_len = 0;

    const char *short_id = NULL;
    size_t short_id_len = 0;

    const char *spider_x = NULL;
    size_t spider_x_len = 0;

    uint8_t public_key_bytes[32];
    uint8_t short_id_bytes[8];
    size_t short_id_bytes_len = 0;

    int show = 0;

    xray_build_result status = XRAY_BUILD_ERROR;

    reality_index = lua_abs_index(L, reality_index);

    xray_pb_buffer_init(&payload);
    xray_pb_buffer_init(result);

    status = check_table_keys(
        L,
        reality_index,
        "realitySettings",
        allowed_keys,
        sizeof(allowed_keys) / sizeof(allowed_keys[0]),
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    if (get_optional_string(
            L, reality_index, "password",
            &password, &password_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_string(
            L, reality_index, "publicKey",
            &public_key, &public_key_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_string(
            L, reality_index, "serverName",
            &server_name, &server_name_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_string(
            L, reality_index, "fingerprint",
            &fingerprint, &fingerprint_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_string(
            L, reality_index, "shortId",
            &short_id, &short_id_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_string(
            L, reality_index, "spiderX",
            &spider_x, &spider_x_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_bool(
            L, reality_index, "show",
            &show,
            error, error_len) != 0)
        goto cleanup;

    /*
     * Xray v26.10.21 supports "password" as an alias
     * of "publicKey". Password takes precedence.
     */
    if (password != NULL && password_len != 0) {
        public_key = password;
        public_key_len = password_len;
    }

    if (public_key == NULL || public_key_len == 0) {
        builder_error(
            error,
            error_len,
            "REALITY public key is missing"
        );

        goto cleanup;
    }

    if (decode_base64url_32(
            public_key,
            public_key_len,
            public_key_bytes) != 0) {
        builder_error(
            error,
            error_len,
            "invalid REALITY public key: expected 32-byte Base64URL"
        );

        goto cleanup;
    }

    if (decode_short_id(
            short_id,
            short_id_len,
            short_id_bytes,
            &short_id_bytes_len) != 0) {
        builder_error(
            error,
            error_len,
            "invalid REALITY shortId"
        );

        goto cleanup;
    }

    /*
     * REALITY Config:
     *
     * show        = 1
     * fingerprint = 21
     * server_name = 22
     * public_key  = 23
     * short_id    = 24
     * spider_x    = 26
     */

    if (show &&
        xray_pb_append_uint(
            &payload, 1, 1) != 0)
        goto encode_error;

    if (fingerprint_len != 0 &&
        xray_pb_append_string(
            &payload, 21, fingerprint) != 0)
        goto encode_error;

    if (server_name_len != 0 &&
        xray_pb_append_string(
            &payload, 22, server_name) != 0)
        goto encode_error;

    if (xray_pb_append_bytes(
            &payload,
            23,
            public_key_bytes,
            sizeof(public_key_bytes)) != 0)
        goto encode_error;

    if (short_id_bytes_len != 0 &&
        xray_pb_append_bytes(
            &payload,
            24,
            short_id_bytes,
            short_id_bytes_len) != 0)
        goto encode_error;

    if (spider_x_len != 0 &&
        xray_pb_append_string(
            &payload, 26, spider_x) != 0)
        goto encode_error;

    if (xray_pb_make_typed_message(
            REALITY_TYPE,
            &payload,
            result) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    builder_error(
        error,
        error_len,
        "cannot encode REALITY protobuf"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    xray_pb_buffer_clear(&payload);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}


/* =========================================================
 * TLS Config -> TypedMessage
 * Xray-core v26.10.21
 * =========================================================
 */

static int append_tls_alpn(
    lua_State *L,
    int tls_index,
    xray_pb_buffer *payload,
    char *error,
    size_t error_len)
{
    int top = lua_gettop(L);

    tls_index = lua_abs_index(L, tls_index);

    lua_getfield(L, tls_index, "alpn");

    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }

    /*
     * Xray StringList accepts either:
     *   ["h2", "h3"]
     * or:
     *   "h2,h3"
     */

    if (lua_type(L, -1) == LUA_TSTRING) {
        const char *value;
        size_t len;
        size_t start = 0;
        size_t i;

        value = lua_tolstring(L, -1, &len);

        if (memchr(value, '\0', len) != NULL) {
            lua_settop(L, top);
            builder_error(error, error_len,
                          "TLS ALPN contains NUL");
            return -1;
        }

        for (i = 0; i <= len; i++) {
            if (i == len || value[i] == ',') {
                if (xray_pb_append_bytes(
                        payload,
                        4,
                        value + start,
                        i - start) != 0) {
                    lua_settop(L, top);
                    return -1;
                }

                start = i + 1;
            }
        }

        lua_settop(L, top);
        return 0;
    }

    if (lua_type(L, -1) == LUA_TTABLE) {
        int list_index = lua_abs_index(L, -1);
        size_t count = lua_objlen(L, list_index);
        size_t i;

        for (i = 1; i <= count; i++) {
            const char *value;
            size_t len;

            lua_rawgeti(L, list_index, (int)i);

            if (lua_type(L, -1) != LUA_TSTRING) {
                lua_settop(L, top);
                builder_error(
                    error, error_len,
                    "TLS ALPN entry must be a string"
                );
                return -1;
            }

            value = lua_tolstring(L, -1, &len);

            if (memchr(value, '\0', len) != NULL) {
                lua_settop(L, top);
                builder_error(
                    error, error_len,
                    "TLS ALPN contains NUL"
                );
                return -1;
            }

            if (xray_pb_append_bytes(
                    payload, 4, value, len) != 0) {
                lua_settop(L, top);
                return -1;
            }

            lua_pop(L, 1);
        }

        lua_settop(L, top);
        return 0;
    }

    lua_settop(L, top);

    builder_error(
        error,
        error_len,
        "TLS ALPN must be a string or array"
    );

    return -1;
}


static xray_build_result build_tls_settings(
    lua_State *L,
    int tls_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    static const char * const allowed_keys[] = {
        "serverName",
        "alpn",
        "fingerprint",
        "allowInsecure"
    };

    xray_pb_buffer payload;

    const char *server_name = NULL;
    size_t server_name_len = 0;

    const char *fingerprint = NULL;
    size_t fingerprint_len = 0;

    int allow_insecure = 0;
    int top;

    xray_build_result status = XRAY_BUILD_ERROR;

    top = lua_gettop(L);

    xray_pb_buffer_init(&payload);
    xray_pb_buffer_init(result);

    tls_index = lua_abs_index(L, tls_index);

    /*
     * Missing tlsSettings means an empty TLS Config.
     */

    if (!lua_isnil(L, tls_index)) {
        status = check_table_keys(
            L,
            tls_index,
            "tlsSettings",
            allowed_keys,
            sizeof(allowed_keys) / sizeof(allowed_keys[0]),
            error,
            error_len
        );

        if (status != XRAY_BUILD_OK)
            goto cleanup;

        if (get_optional_string(
                L,
                tls_index,
                "serverName",
                &server_name,
                &server_name_len,
                error,
                error_len) != 0)
            goto cleanup;

        if (get_optional_string(
                L,
                tls_index,
                "fingerprint",
                &fingerprint,
                &fingerprint_len,
                error,
                error_len) != 0)
            goto cleanup;

        if (get_optional_bool(
                L,
                tls_index,
                "allowInsecure",
                &allow_insecure,
                error,
                error_len) != 0)
            goto cleanup;

        /*
         * allowInsecure was removed by current Xray.
         * false is the normal/default behaviour and is omitted.
         */
        if (allow_insecure) {
            builder_error(
                error,
                error_len,
                "TLS allowInsecure=true is no longer supported by Xray"
            );
            goto cleanup;
        }

        if (append_tls_alpn(
                L,
                tls_index,
                &payload,
                error,
                error_len) != 0)
            goto cleanup;
    }

    /*
     * TLS Config:
     *
     * server_name = 3
     * next_protocol = 4 (repeated)
     * fingerprint = 11
     */

    if (server_name_len != 0 &&
        xray_pb_append_string(
            &payload, 3, server_name) != 0)
        goto encode_error;

    if (fingerprint_len != 0 &&
        xray_pb_append_string(
            &payload, 11, fingerprint) != 0)
        goto encode_error;

    if (xray_pb_make_typed_message(
            TLS_TYPE,
            &payload,
            result) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    builder_error(
        error,
        error_len,
        "cannot encode TLS protobuf"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    lua_settop(L, top);

    xray_pb_buffer_clear(&payload);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}


/* =========================================================
 * SplitHTTP RangeConfig / XMUX
 * Xray-core v26.10.21
 * =========================================================
 */

typedef struct {
    int32_t from;
    int32_t to;
} split_range_value;


/*
 * Parse Int32Range.
 *
 * Accepted:
 *   3
 *   "3"
 *   "1140-1260"
 *   "-5--1"
 *
 * Values are normalized so from <= to,
 * matching Xray's Int32Range.UnmarshalJSON().
 */
static int parse_split_range(
    lua_State *L,
    int index,
    split_range_value *range,
    char *error,
    size_t error_len)
{
    int type = lua_type(L, index);

    range->from = 0;
    range->to = 0;

    if (type == LUA_TNUMBER) {
        lua_Number number = lua_tonumber(L, index);

        if (!(number >= INT32_MIN && number <= INT32_MAX)) {
            builder_error(
                error, error_len,
                "XMUX range is outside int32 range"
            );
            return -1;
        }

        range->from = (int32_t)number;

        if ((lua_Number)range->from != number) {
            builder_error(
                error, error_len,
                "XMUX range must be an integer"
            );
            return -1;
        }

        range->to = range->from;
        return 0;
    }

    if (type == LUA_TSTRING) {
        const char *value;
        size_t value_len;
        char input[128];

        char *end;
        char *right;
        char *right_end;

        long left_value;
        long right_value;

        value = lua_tolstring(L, index, &value_len);

        if (value_len >= sizeof(input) ||
            memchr(value, '\0', value_len) != NULL) {
            builder_error(
                error, error_len,
                "invalid XMUX range string"
            );
            return -1;
        }

        memcpy(input, value, value_len);
        input[value_len] = '\0';

        if (value_len == 0)
            return 0;

        errno = 0;
        left_value = strtol(input, &end, 10);

        if (errno == ERANGE || end == input) {
            builder_error(
                error, error_len,
                "invalid XMUX range: %s",
                input
            );
            return -1;
        }

        if (*end == '\0') {
            right_value = left_value;
        }
        else if (*end == '-') {
            right = end + 1;

            errno = 0;
            right_value = strtol(right, &right_end, 10);

            if (errno == ERANGE ||
                right_end == right ||
                *right_end != '\0') {
                builder_error(
                    error, error_len,
                    "invalid XMUX range: %s",
                    input
                );
                return -1;
            }
        }
        else {
            builder_error(
                error, error_len,
                "invalid XMUX range: %s",
                input
            );
            return -1;
        }

        if (left_value < INT32_MIN ||
            left_value > INT32_MAX ||
            right_value < INT32_MIN ||
            right_value > INT32_MAX) {
            builder_error(
                error, error_len,
                "XMUX range is outside int32 range"
            );
            return -1;
        }

        range->from = (int32_t)left_value;
        range->to = (int32_t)right_value;

        if (range->from > range->to) {
            int32_t temp = range->from;
            range->from = range->to;
            range->to = temp;
        }

        return 0;
    }

    builder_error(
        error, error_len,
        "XMUX range must be a number or range string"
    );

    return -1;
}


/*
 * Read optional Int32Range field.
 */

static int get_split_range(
    lua_State *L,
    int table_index,
    const char *key,
    split_range_value *range,
    char *error,
    size_t error_len)
{
    table_index = lua_abs_index(L, table_index);

    lua_getfield(L, table_index, key);

    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);

        range->from = 0;
        range->to = 0;

        return 0;
    }

    if (parse_split_range(
            L, -1, range, error, error_len) != 0) {
        lua_pop(L, 1);
        return -1;
    }

    lua_pop(L, 1);

    return 0;
}


/*
 * Append RangeConfig:
 *
 * from = 1
 * to   = 2
 */

static int append_split_range(
    xray_pb_buffer *parent,
    uint32_t field,
    const split_range_value *range)
{
    xray_pb_buffer message;

    int rc = -1;

    xray_pb_buffer_init(&message);

    if (xray_pb_append_uint(
            &message,
            1,
            (uint64_t)(int64_t)range->from) != 0)
        goto cleanup;

    if (xray_pb_append_uint(
            &message,
            2,
            (uint64_t)(int64_t)range->to) != 0)
        goto cleanup;

    if (xray_pb_append_message(
            parent,
            field,
            &message) != 0)
        goto cleanup;

    rc = 0;

cleanup:
    xray_pb_buffer_clear(&message);
    return rc;
}


/* =========================================================
 * XMUX Config
 *
 * maxReuseTimes is deliberately ignored.
 *
 * Xray v26.10.21 does not have this field in XmuxConfig.
 * Its standard JSON decoder ignores unknown fields.
 * =========================================================
 */

static xray_build_result build_split_xmux(
    lua_State *L,
    int source_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    static const char * const allowed_keys[] = {
        "maxConcurrency",
        "maxConnections",
        "cMaxReuseTimes",
        "hMaxRequestTimes",
        "hMaxReusableSecs",
        "hKeepAlivePeriod",

        /* Legacy subscription alias: intentionally ignored. */
        "maxReuseTimes"
    };

    split_range_value max_concurrency = {0, 0};
    split_range_value max_connections = {0, 0};
    split_range_value c_max_reuse_times = {0, 0};
    split_range_value h_max_request_times = {0, 0};
    split_range_value h_max_reusable_secs = {0, 0};

    int32_t h_keep_alive_period = 0;

    int top = lua_gettop(L);
    int xmux_index = 0;

    int xmux_is_empty;

    xray_build_result status = XRAY_BUILD_ERROR;

    xray_pb_buffer_init(result);

    source_index = lua_abs_index(L, source_index);

    if (source_index != 0) {
        lua_getfield(L, source_index, "xmux");

        if (!lua_isnil(L, -1)) {
            if (lua_type(L, -1) != LUA_TTABLE) {
                builder_error(
                    error, error_len,
                    "SplitHTTP xmux must be a table"
                );
                goto cleanup;
            }

            xmux_index = lua_abs_index(L, -1);

            status = check_table_keys(
                L,
                xmux_index,
                "SplitHTTP xmux",
                allowed_keys,
                sizeof(allowed_keys) / sizeof(allowed_keys[0]),
                error,
                error_len
            );

            if (status != XRAY_BUILD_OK)
                goto cleanup;

            if (get_split_range(
                    L, xmux_index,
                    "maxConcurrency",
                    &max_concurrency,
                    error, error_len) != 0)
                goto cleanup;

            if (get_split_range(
                    L, xmux_index,
                    "maxConnections",
                    &max_connections,
                    error, error_len) != 0)
                goto cleanup;

            if (get_split_range(
                    L, xmux_index,
                    "cMaxReuseTimes",
                    &c_max_reuse_times,
                    error, error_len) != 0)
                goto cleanup;

            if (get_split_range(
                    L, xmux_index,
                    "hMaxRequestTimes",
                    &h_max_request_times,
                    error, error_len) != 0)
                goto cleanup;

            if (get_split_range(
                    L, xmux_index,
                    "hMaxReusableSecs",
                    &h_max_reusable_secs,
                    error, error_len) != 0)
                goto cleanup;

            if (get_optional_int32(
                    L,
                    xmux_index,
                    "hKeepAlivePeriod",
                    &h_keep_alive_period,
                    error,
                    error_len) != 0)
                goto cleanup;
        }
    }

    /*
     * Xray defaults apply only when the entire XMUX
     * configuration is zero-valued.
     */

    xmux_is_empty =
        max_concurrency.from == 0 &&
        max_concurrency.to == 0 &&
        max_connections.from == 0 &&
        max_connections.to == 0 &&
        c_max_reuse_times.from == 0 &&
        c_max_reuse_times.to == 0 &&
        h_max_request_times.from == 0 &&
        h_max_request_times.to == 0 &&
        h_max_reusable_secs.from == 0 &&
        h_max_reusable_secs.to == 0 &&
        h_keep_alive_period == 0;

    if (xmux_is_empty) {
        max_connections.from = 3;
        max_connections.to = 3;

        h_max_request_times.from = 600;
        h_max_request_times.to = 900;

        h_max_reusable_secs.from = 1800;
        h_max_reusable_secs.to = 3000;
    }

    if (max_connections.to > 0 &&
        max_concurrency.to > 0) {
        builder_error(
            error, error_len,
            "XMUX maxConnections and maxConcurrency cannot both be set"
        );

        goto cleanup;
    }

    /*
     * XmuxConfig:
     *
     * maxConcurrency   = 1
     * maxConnections   = 2
     * cMaxReuseTimes   = 3
     * hMaxRequestTimes = 4
     * hMaxReusableSecs = 5
     * hKeepAlivePeriod = 6
     */

    if (append_split_range(
            result, 1, &max_concurrency) != 0)
        goto encode_error;

    if (append_split_range(
            result, 2, &max_connections) != 0)
        goto encode_error;

    if (append_split_range(
            result, 3, &c_max_reuse_times) != 0)
        goto encode_error;

    if (append_split_range(
            result, 4, &h_max_request_times) != 0)
        goto encode_error;

    if (append_split_range(
            result, 5, &h_max_reusable_secs) != 0)
        goto encode_error;

    if (h_keep_alive_period != 0 &&
        xray_pb_append_uint(
            result,
            6,
            (uint64_t)(int64_t)h_keep_alive_period) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    builder_error(
        error, error_len,
        "cannot encode SplitHTTP XMUX protobuf"
    );

cleanup:
    lua_settop(L, top);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}


/* =========================================================
 * SplitHTTP Config -> TypedMessage
 *
 * Currently supported:
 *   host
 *   path
 *   mode
 *   extra.xmux
 *
 * Unknown SplitHTTP options use CLI fallback.
 * =========================================================
 */

static xray_build_result build_splithttp_settings(
    lua_State *L,
    int settings_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    static const char * const allowed_keys[] = {
        "host",
        "path",
        "mode",
        "extra",
        "xmux"
    };

    static const char * const extra_allowed_keys[] = {
        "host",
        "path",
        "mode",
        "xmux"
    };

    xray_pb_buffer config;
    xray_pb_buffer xmux;

    const char *host = NULL;
    size_t host_len = 0;

    const char *path = NULL;
    size_t path_len = 0;

    const char *mode = NULL;
    size_t mode_len = 0;

    int top;
    int extra_index = 0;
    int xmux_source_index;

    xray_build_result status = XRAY_BUILD_ERROR;

    top = lua_gettop(L);

    settings_index = lua_abs_index(L, settings_index);

    xray_pb_buffer_init(result);
    xray_pb_buffer_init(&config);
    xray_pb_buffer_init(&xmux);

    status = check_table_keys(
        L,
        settings_index,
        "splithttpSettings",
        allowed_keys,
        sizeof(allowed_keys) / sizeof(allowed_keys[0]),
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    if (get_optional_string(
            L, settings_index, "host",
            &host, &host_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_string(
            L, settings_index, "path",
            &path, &path_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_string(
            L, settings_index, "mode",
            &mode, &mode_len,
            error, error_len) != 0)
        goto cleanup;

    /*
     * Xray's SplitHTTPConfig.Build():
     *
     * If extra is present, it unmarshals extra into a new
     * SplitHTTPConfig, then overwrites host/path/mode with
     * the outer settings.
     *
     * Therefore XMUX is taken from extra when it exists,
     * otherwise from the outer settings.
     */

    lua_getfield(L, settings_index, "extra");

    if (!lua_isnil(L, -1)) {
        if (lua_type(L, -1) != LUA_TTABLE) {
            builder_error(
                error, error_len,
                "SplitHTTP extra must be a table"
            );
            goto cleanup;
        }

        extra_index = lua_abs_index(L, -1);

        status = check_table_keys(
            L,
            extra_index,
            "SplitHTTP extra",
            extra_allowed_keys,
            sizeof(extra_allowed_keys) /
                sizeof(extra_allowed_keys[0]),
            error,
            error_len
        );

        if (status != XRAY_BUILD_OK)
            goto cleanup;

        xmux_source_index = extra_index;
    }
    else {
        xmux_source_index = settings_index;
    }

    /*
     * Xray defaults an empty mode to "auto".
     */

    if (mode == NULL || mode_len == 0) {
        mode = "auto";
        mode_len = 4;
    }

    if (!(
        (mode_len == 4 && memcmp(mode, "auto", 4) == 0) ||
        (mode_len == 9 && memcmp(mode, "packet-up", 9) == 0) ||
        (mode_len == 9 && memcmp(mode, "stream-up", 9) == 0) ||
        (mode_len == 10 && memcmp(mode, "stream-one", 10) == 0)
    )) {
        builder_error(
            error, error_len,
            "unsupported SplitHTTP mode: %.*s",
            (int)mode_len,
            mode
        );

        status = XRAY_BUILD_ERROR;
        goto cleanup;
    }

    status = build_split_xmux(
        L,
        xmux_source_index,
        &xmux,
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    /*
     * SplitHTTP Config:
     *
     * host = 1
     * path = 2
     * mode = 3
     * xmux = 12
     */

    if (host_len != 0 &&
        xray_pb_append_string(
            &config, 1, host) != 0)
        goto encode_error;

    if (path_len != 0 &&
        xray_pb_append_string(
            &config, 2, path) != 0)
        goto encode_error;

    if (xray_pb_append_string(
            &config, 3, mode) != 0)
        goto encode_error;

    if (xray_pb_append_message(
            &config, 12, &xmux) != 0)
        goto encode_error;

    if (xray_pb_make_typed_message(
            SPLITHTTP_TYPE,
            &config,
            result) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    builder_error(
        error, error_len,
        "cannot encode SplitHTTP protobuf"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    lua_settop(L, top);

    xray_pb_buffer_clear(&config);
    xray_pb_buffer_clear(&xmux);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}


/* =========================================================
 * Hysteria v2 transport Config
 * Xray-core v26.10.21
 * =========================================================
 */

static xray_build_result build_hysteria_transport_settings(
    lua_State *L,
    int settings_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    static const char * const allowed_keys[] = {
        "version",
        "auth",
        "udpIdleTimeout",
        "up",
        "down",
        "udphop",
        "masquerade"
    };

    xray_pb_buffer payload;

    const char *auth = NULL;
    size_t auth_len = 0;

    int32_t version = 0;
    int32_t udp_idle_timeout = 0;

    int top;
    xray_build_result status = XRAY_BUILD_ERROR;

    top = lua_gettop(L);
    settings_index = lua_abs_index(L, settings_index);

    xray_pb_buffer_init(result);
    xray_pb_buffer_init(&payload);

    status = check_table_keys(
        L,
        settings_index,
        "hysteriaSettings",
        allowed_keys,
        sizeof(allowed_keys) / sizeof(allowed_keys[0]),
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    /*
     * Version must be 2.
     */

    if (get_optional_int32(
            L, settings_index, "version",
            &version, error, error_len) != 0)
        goto cleanup;

    if (version != 2) {
        builder_error(
            error, error_len,
            "Hysteria version must be 2"
        );
        goto cleanup;
    }

    /*
     * Auth is protobuf field 2.
     */

    if (get_optional_string(
            L, settings_index, "auth",
            &auth, &auth_len,
            error, error_len) != 0)
        goto cleanup;

    /*
     * UDP idle timeout:
     * 0 / absent -> 60 seconds.
     */

    if (get_optional_int32(
            L, settings_index, "udpIdleTimeout",
            &udp_idle_timeout,
            error, error_len) != 0)
        goto cleanup;

    if (udp_idle_timeout == 0)
        udp_idle_timeout = 60;

    if (udp_idle_timeout < 2 ||
        udp_idle_timeout > 600) {
        builder_error(
            error, error_len,
            "Hysteria udpIdleTimeout must be 2..600"
        );
        goto cleanup;
    }

    /*
     * up/down/udphop are intentionally ignored.
     *
     * They are not members of HysteriaConfig in
     * Xray v26.10.21 and the Go JSON decoder ignores them.
     */

    /*
     * Masquerade exists in Xray but is not implemented
     * by our native builder yet.
     */

    lua_getfield(L, settings_index, "masquerade");

    if (!lua_isnil(L, -1)) {
        lua_pop(L, 1);

        builder_error(
            error, error_len,
            "Hysteria masquerade is not supported natively"
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    lua_pop(L, 1);

    /*
     * Hysteria Config:
     *
     * auth             = 2
     * udp_idle_timeout = 3
     */

    if (auth_len != 0 &&
        xray_pb_append_string(
            &payload, 2, auth) != 0)
        goto encode_error;

    if (xray_pb_append_uint(
            &payload,
            3,
            (uint64_t)udp_idle_timeout) != 0)
        goto encode_error;

    if (xray_pb_make_typed_message(
            HYSTERIA_TRANSPORT_TYPE,
            &payload,
            result) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    builder_error(
        error, error_len,
        "cannot encode Hysteria transport protobuf"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    lua_settop(L, top);

    xray_pb_buffer_clear(&payload);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}


/* =========================================================
 * QUIC parameters from finalmask.quicParams
 *
 * Currently supported:
 *   congestion
 *   bbrProfile
 *   debug=false
 * =========================================================
 */

static xray_build_result check_empty_mask_list(
    lua_State *L,
    int finalmask_index,
    const char *key,
    char *error,
    size_t error_len)
{
    int top = lua_gettop(L);

    lua_getfield(L, finalmask_index, key);

    if (lua_isnil(L, -1)) {
        lua_settop(L, top);
        return XRAY_BUILD_OK;
    }

    if (lua_type(L, -1) != LUA_TTABLE) {
        lua_settop(L, top);

        builder_error(
            error, error_len,
            "finalmask.%s must be an array",
            key
        );

        return XRAY_BUILD_ERROR;
    }

    lua_pushnil(L);

    if (lua_next(L, -2) != 0) {
        lua_settop(L, top);

        builder_error(
            error, error_len,
            "finalmask.%s masks are not supported natively",
            key
        );

        return XRAY_BUILD_UNSUPPORTED;
    }

    lua_settop(L, top);

    return XRAY_BUILD_OK;
}


static xray_build_result build_quic_params(
    lua_State *L,
    int stream_index,
    xray_pb_buffer *result,
    int *present,
    char *error,
    size_t error_len)
{
    static const char * const finalmask_keys[] = {
        "quicParams",
        "tcp",
        "udp"
    };

    static const char * const quic_keys[] = {
        "congestion",
        "bbrProfile",
        "debug"
    };

    xray_build_result status = XRAY_BUILD_ERROR;

    const char *congestion = NULL;
    size_t congestion_len = 0;

    const char *profile = NULL;
    size_t profile_len = 0;

    const char *profile_value = "standard";

    int debug = 0;
    int top;
    int finalmask_index;
    int params_index;

    if (present != NULL)
        *present = 0;

    top = lua_gettop(L);
    stream_index = lua_abs_index(L, stream_index);

    xray_pb_buffer_init(result);

    /*
     * finalmask is optional.
     */

    lua_getfield(L, stream_index, "finalmask");

    if (lua_isnil(L, -1)) {
        status = XRAY_BUILD_OK;
        goto cleanup;
    }

    if (lua_type(L, -1) != LUA_TTABLE) {
        builder_error(
            error, error_len,
            "finalmask must be a table"
        );

        goto cleanup;
    }

    finalmask_index = lua_abs_index(L, -1);

    status = check_table_keys(
        L,
        finalmask_index,
        "finalmask",
        finalmask_keys,
        sizeof(finalmask_keys) / sizeof(finalmask_keys[0]),
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    status = check_empty_mask_list(
        L, finalmask_index, "tcp",
        error, error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    status = check_empty_mask_list(
        L, finalmask_index, "udp",
        error, error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    /*
     * Read quicParams.
     */

    lua_getfield(L, finalmask_index, "quicParams");

    if (lua_isnil(L, -1)) {
        status = XRAY_BUILD_OK;
        goto cleanup;
    }

    if (lua_type(L, -1) != LUA_TTABLE) {
        builder_error(
            error, error_len,
            "finalmask.quicParams must be a table"
        );

        goto cleanup;
    }

    params_index = lua_abs_index(L, -1);

    status = check_table_keys(
        L,
        params_index,
        "quicParams",
        quic_keys,
        sizeof(quic_keys) / sizeof(quic_keys[0]),
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    if (get_optional_string(
            L, params_index, "congestion",
            &congestion, &congestion_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_string(
            L, params_index, "bbrProfile",
            &profile, &profile_len,
            error, error_len) != 0)
        goto cleanup;

    if (get_optional_bool(
            L, params_index, "debug",
            &debug,
            error, error_len) != 0)
        goto cleanup;

    /*
     * Debug=true requires environment changes inside
     * the Xray process. We cannot do that through ADO.
     * debug=false has no protobuf representation.
     */

    if (debug) {
        builder_error(
            error, error_len,
            "QUIC debug=true is not supported natively"
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    /*
     * BBR profile defaults to "standard" in Xray.
     */

    if (profile_len != 0) {
        if (strcasecmp(profile, "conservative") == 0)
            profile_value = "conservative";
        else if (strcasecmp(profile, "standard") == 0)
            profile_value = "standard";
        else if (strcasecmp(profile, "aggressive") == 0)
            profile_value = "aggressive";
        else {
            builder_error(
                error, error_len,
                "unknown QUIC bbrProfile: %s",
                profile
            );

            goto cleanup;
        }
    }

    /*
     * Congestion values are normalized to lowercase
     * by Xray's QuicParamsConfig.Build().
     */

    if (congestion_len != 0) {
        if (strcasecmp(congestion, "bbr") != 0 &&
            strcasecmp(congestion, "reno") != 0 &&
            strcasecmp(congestion, "brutal") != 0) {

            if (strcasecmp(congestion, "force-brutal") == 0) {
                builder_error(
                    error, error_len,
                    "force-brutal requires unsupported brutalUp"
                );

                status = XRAY_BUILD_UNSUPPORTED;
                goto cleanup;
            }

            builder_error(
                error, error_len,
                "unknown QUIC congestion: %s",
                congestion
            );

            goto cleanup;
        }

        if (xray_pb_append_string(
                result,
                1,
                strcasecmp(congestion, "bbr") == 0 ? "bbr" :
                strcasecmp(congestion, "reno") == 0 ? "reno" :
                "brutal") != 0)
            goto encode_error;
    }

    /*
     * QuicParams:
     *
     * congestion  = 1
     * bbr_profile = 2
     *
     * The profile is always emitted, because Xray's
     * Build() replaces an empty profile with "standard".
     */

    if (xray_pb_append_string(
            result,
            2,
            profile_value) != 0)
        goto encode_error;

    if (present != NULL)
        *present = 1;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    builder_error(
        error, error_len,
        "cannot encode QUIC parameters"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    lua_settop(L, top);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}


/* =========================================================
 * SocketConfig
 * =========================================================
 */

static xray_build_result build_socket_settings(
    lua_State *L,
    int socket_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    static const char * const allowed_keys[] = {
        "mark",
        "domainStrategy"
    };

    int32_t mark = 0;

    const char *domain_strategy = NULL;
    size_t domain_strategy_len = 0;

    uint64_t domain_strategy_value = 0;

    xray_build_result status;

    socket_index = lua_abs_index(L, socket_index);

    xray_pb_buffer_init(result);

    status = check_table_keys(
        L,
        socket_index,
        "sockopt",
        allowed_keys,
        sizeof(allowed_keys) / sizeof(allowed_keys[0]),
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        return status;

    if (get_optional_int32(
            L,
            socket_index,
            "mark",
            &mark,
            error,
            error_len) != 0) {
        return XRAY_BUILD_ERROR;
    }

    if (get_optional_string(
            L,
            socket_index,
            "domainStrategy",
            &domain_strategy,
            &domain_strategy_len,
            error,
            error_len) != 0) {
        return XRAY_BUILD_ERROR;
    }

    if (domain_strategy_len != 0 &&
        map_domain_strategy(
            domain_strategy,
            &domain_strategy_value) != 0) {
        builder_error(
            error,
            error_len,
            "unsupported sockopt.domainStrategy: %s",
            domain_strategy
        );

        return XRAY_BUILD_UNSUPPORTED;
    }

    /*
     * SocketConfig:
     *
     * mark            = 1
     * domain_strategy = 8
     */

    if (mark != 0 &&
        xray_pb_append_uint(
            result,
            1,
            (uint64_t)(int64_t)mark) != 0)
        goto encode_error;

    if (domain_strategy_value != 0 &&
        xray_pb_append_uint(
            result,
            8,
            domain_strategy_value) != 0)
        goto encode_error;

    return XRAY_BUILD_OK;

encode_error:
    builder_error(
        error,
        error_len,
        "cannot encode SocketConfig protobuf"
    );

    xray_pb_buffer_clear(result);

    return XRAY_BUILD_ERROR;
}


/* =========================================================
 * StreamConfig + SenderConfig
 * =========================================================
 */

xray_build_result xray_build_sender_settings(
    lua_State *L,
    int outbound_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len)
{
    static const char * const stream_allowed_keys[] = {
        "network",
        "security",
        "realitySettings",
        "tlsSettings",
        "splithttpSettings",
        "hysteriaSettings",
        "finalmask",
        "sockopt"
    };

    xray_pb_buffer security_settings;
    xray_pb_buffer socket;
    xray_pb_buffer split_settings;
    xray_pb_buffer hysteria_settings;
    xray_pb_buffer transport_config;
    xray_pb_buffer quic_params;
    xray_pb_buffer stream;
    xray_pb_buffer sender;

    const char *network = NULL;
    size_t network_len = 0;
    const char *network_name = "tcp";

    const char *security = NULL;
    size_t security_len = 0;
    const char *security_type = NULL;

    int top;
    int stream_index;
    int settings_index;

    int socket_present = 0;
    int transport_present = 0;
    int quic_present = 0;

    int hysteria_network = 0;
    int splithttp_network = 0;

    xray_build_result status = XRAY_BUILD_ERROR;

    if (error != NULL && error_len != 0)
        error[0] = '\0';

    if (L == NULL || result == NULL) {
        builder_error(
            error, error_len,
            "invalid sender builder arguments"
        );

        return XRAY_BUILD_ERROR;
    }

    top = lua_gettop(L);
    outbound_index = lua_abs_index(L, outbound_index);

    xray_pb_buffer_init(result);
    xray_pb_buffer_init(&security_settings);
    xray_pb_buffer_init(&socket);
    xray_pb_buffer_init(&split_settings);
    xray_pb_buffer_init(&hysteria_settings);
    xray_pb_buffer_init(&transport_config);
    xray_pb_buffer_init(&quic_params);
    xray_pb_buffer_init(&stream);
    xray_pb_buffer_init(&sender);

    if (lua_type(L, outbound_index) != LUA_TTABLE) {
        builder_error(
            error, error_len,
            "outbound must be a table"
        );

        goto cleanup;
    }

    lua_getfield(L, outbound_index, "streamSettings");

    if (lua_type(L, -1) != LUA_TTABLE) {
        builder_error(
            error, error_len,
            "outbound.streamSettings must be a table"
        );

        goto cleanup;
    }

    stream_index = lua_abs_index(L, -1);

    status = check_table_keys(
        L,
        stream_index,
        "streamSettings",
        stream_allowed_keys,
        sizeof(stream_allowed_keys) /
            sizeof(stream_allowed_keys[0]),
        error,
        error_len
    );

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    /*
     * Network.
     */

    if (get_optional_string(
            L, stream_index, "network",
            &network, &network_len,
            error, error_len) != 0) {
        status = XRAY_BUILD_ERROR;
        goto cleanup;
    }

    if (network_len != 0) {
        if (strcasecmp(network, "tcp") == 0 ||
            strcasecmp(network, "raw") == 0) {

            network_name = "tcp";
        }
        else if (strcasecmp(network, "splithttp") == 0 ||
                 strcasecmp(network, "xhttp") == 0) {

            network_name = "splithttp";
            splithttp_network = 1;
        }
        else if (strcasecmp(network, "hysteria") == 0) {

            network_name = "hysteria";
            hysteria_network = 1;
        }
        else {
            builder_error(
                error, error_len,
                "unsupported transport network: %s",
                network
            );

            status = XRAY_BUILD_UNSUPPORTED;
            goto cleanup;
        }
    }

    /*
     * Build SplitHTTP transport.
     */

    if (splithttp_network) {
        lua_getfield(L, stream_index, "splithttpSettings");

        if (lua_type(L, -1) != LUA_TTABLE) {
            builder_error(
                error, error_len,
                "splithttpSettings must be a table"
            );

            status = XRAY_BUILD_ERROR;
            goto cleanup;
        }

        settings_index = lua_abs_index(L, -1);

        status = build_splithttp_settings(
            L,
            settings_index,
            &split_settings,
            error,
            error_len
        );

        lua_pop(L, 1);

        if (status != XRAY_BUILD_OK)
            goto cleanup;

        if (xray_pb_append_message(
                &transport_config,
                2,
                &split_settings) != 0)
            goto encode_error;

        if (xray_pb_append_string(
                &transport_config,
                3,
                "splithttp") != 0)
            goto encode_error;

        transport_present = 1;
    }

    /*
     * Build Hysteria transport.
     */

    if (hysteria_network) {
        lua_getfield(L, stream_index, "hysteriaSettings");

        if (lua_type(L, -1) != LUA_TTABLE) {
            builder_error(
                error, error_len,
                "hysteriaSettings must be a table"
            );

            status = XRAY_BUILD_ERROR;
            goto cleanup;
        }

        settings_index = lua_abs_index(L, -1);

        status = build_hysteria_transport_settings(
            L,
            settings_index,
            &hysteria_settings,
            error,
            error_len
        );

        lua_pop(L, 1);

        if (status != XRAY_BUILD_OK)
            goto cleanup;

        if (xray_pb_append_message(
                &transport_config,
                2,
                &hysteria_settings) != 0)
            goto encode_error;

        if (xray_pb_append_string(
                &transport_config,
                3,
                "hysteria") != 0)
            goto encode_error;

        transport_present = 1;

        /*
         * finalmask.quicParams -> StreamConfig.quic_params
         */

        status = build_quic_params(
            L,
            stream_index,
            &quic_params,
            &quic_present,
            error,
            error_len
        );

        if (status != XRAY_BUILD_OK)
            goto cleanup;
    }
    else {
        /*
         * Do not silently ignore Hysteria-only settings.
         */

        lua_getfield(L, stream_index, "hysteriaSettings");

        if (!lua_isnil(L, -1)) {
            lua_pop(L, 1);

            builder_error(
                error, error_len,
                "hysteriaSettings present with non-Hysteria network"
            );

            status = XRAY_BUILD_UNSUPPORTED;
            goto cleanup;
        }

        lua_pop(L, 1);

        lua_getfield(L, stream_index, "finalmask");

        if (!lua_isnil(L, -1)) {
            lua_pop(L, 1);

            builder_error(
                error, error_len,
                "finalmask is currently supported natively only for Hysteria"
            );

            status = XRAY_BUILD_UNSUPPORTED;
            goto cleanup;
        }

        lua_pop(L, 1);
    }

    /*
     * Security: REALITY or TLS.
     */

    if (get_optional_string(
            L, stream_index, "security",
            &security, &security_len,
            error, error_len) != 0) {
        status = XRAY_BUILD_ERROR;
        goto cleanup;
    }

    if (security == NULL) {
        builder_error(
            error, error_len,
            "transport security is missing"
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    if (strcasecmp(security, "reality") == 0) {
        if (hysteria_network) {
            builder_error(
                error, error_len,
                "Hysteria requires TLS security"
            );

            goto cleanup;
        }

        security_type = REALITY_TYPE;

        lua_getfield(L, stream_index, "realitySettings");

        if (lua_type(L, -1) != LUA_TTABLE) {
            builder_error(
                error, error_len,
                "realitySettings must be a table"
            );

            status = XRAY_BUILD_ERROR;
            goto cleanup;
        }

        settings_index = lua_abs_index(L, -1);

        status = build_reality_settings(
            L,
            settings_index,
            &security_settings,
            error,
            error_len
        );

        lua_pop(L, 1);

        if (status != XRAY_BUILD_OK)
            goto cleanup;
    }
    else if (strcasecmp(security, "tls") == 0) {
        security_type = TLS_TYPE;

        lua_getfield(L, stream_index, "tlsSettings");

        settings_index = lua_abs_index(L, -1);

        status = build_tls_settings(
            L,
            settings_index,
            &security_settings,
            error,
            error_len
        );

        lua_pop(L, 1);

        if (status != XRAY_BUILD_OK)
            goto cleanup;
    }
    else {
        builder_error(
            error, error_len,
            "unsupported transport security: %s",
            security
        );

        status = XRAY_BUILD_UNSUPPORTED;
        goto cleanup;
    }

    /*
     * SocketConfig.
     */

    lua_getfield(L, stream_index, "sockopt");

    if (!lua_isnil(L, -1)) {
        if (lua_type(L, -1) != LUA_TTABLE) {
            builder_error(
                error, error_len,
                "sockopt must be a table"
            );

            status = XRAY_BUILD_ERROR;
            goto cleanup;
        }

        settings_index = lua_abs_index(L, -1);

        status = build_socket_settings(
            L,
            settings_index,
            &socket,
            error,
            error_len
        );

        if (status != XRAY_BUILD_OK)
            goto cleanup;

        socket_present = 1;
    }

    lua_pop(L, 1);

    /*
     * StreamConfig:
     *
     * transport_settings = 2 (repeated)
     * security_type      = 3
     * security_settings  = 4
     * protocol_name      = 5
     * socket_settings    = 6
     * quic_params        = 12
     */

    if (xray_pb_append_string(
            &stream,
            5,
            network_name) != 0)
        goto encode_error;

    if (xray_pb_append_string(
            &stream,
            3,
            security_type) != 0)
        goto encode_error;

    if (xray_pb_append_message(
            &stream,
            4,
            &security_settings) != 0)
        goto encode_error;

    if (transport_present &&
        xray_pb_append_message(
            &stream,
            2,
            &transport_config) != 0)
        goto encode_error;

    if (socket_present &&
        xray_pb_append_message(
            &stream,
            6,
            &socket) != 0)
        goto encode_error;

    if (quic_present &&
        xray_pb_append_message(
            &stream,
            12,
            &quic_params) != 0)
        goto encode_error;

    /*
     * SenderConfig:
     *
     * stream_settings = 2
     */

    if (xray_pb_append_message(
            &sender,
            2,
            &stream) != 0)
        goto encode_error;

    if (xray_pb_make_typed_message(
            SENDER_CONFIG_TYPE,
            &sender,
            result) != 0)
        goto encode_error;

    status = XRAY_BUILD_OK;
    goto cleanup;

encode_error:
    builder_error(
        error, error_len,
        "cannot encode SenderConfig protobuf"
    );

    status = XRAY_BUILD_ERROR;

cleanup:
    lua_settop(L, top);

    xray_pb_buffer_clear(&security_settings);
    xray_pb_buffer_clear(&socket);
    xray_pb_buffer_clear(&split_settings);
    xray_pb_buffer_clear(&hysteria_settings);
    xray_pb_buffer_clear(&transport_config);
    xray_pb_buffer_clear(&quic_params);
    xray_pb_buffer_clear(&stream);
    xray_pb_buffer_clear(&sender);

    if (status != XRAY_BUILD_OK)
        xray_pb_buffer_clear(result);

    return status;
}
