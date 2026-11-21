
#ifndef XRAY_GRPC_INTERNAL_H
#define XRAY_GRPC_INTERNAL_H

#include <lua.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Shared protobuf buffer.
 *
 * Used by protocol.c and transport.c to construct
 * nested Xray protobuf messages.
 */
typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    size_t limit;
} xray_pb_buffer;


/*
 * Configuration builder result.
 *
 * OK:
 *     Configuration successfully encoded.
 *
 * UNSUPPORTED:
 *     Configuration is valid but not implemented
 *     by our native builder. Lua may use CLI fallback.
 *
 * ERROR:
 *     Invalid input or internal encoding error.
 *     CLI fallback must NOT be used.
 */
typedef enum {
    XRAY_BUILD_ERROR = -1,
    XRAY_BUILD_OK = 0,
    XRAY_BUILD_UNSUPPORTED = 1
} xray_build_result;


/*
 * Common protobuf buffer helpers.
 * Implemented in xray_grpc.c.
 */

void xray_pb_buffer_init(xray_pb_buffer *buffer);
void xray_pb_buffer_clear(xray_pb_buffer *buffer);

int xray_pb_append_varint(
    xray_pb_buffer *buffer,
    uint64_t value
);

int xray_pb_append_uint(
    xray_pb_buffer *buffer,
    uint32_t field,
    uint64_t value
);

int xray_pb_append_bytes(
    xray_pb_buffer *buffer,
    uint32_t field,
    const void *data,
    size_t len
);

int xray_pb_append_string(
    xray_pb_buffer *buffer,
    uint32_t field,
    const char *value
);

int xray_pb_append_message(
    xray_pb_buffer *buffer,
    uint32_t field,
    const xray_pb_buffer *message
);

int xray_pb_make_typed_message(
    const char *type_name,
    const xray_pb_buffer *payload,
    xray_pb_buffer *result
);


/*
 * Protocol builders.
 * Implemented in protocol.c.
 */

xray_build_result xray_build_vless_proxy_settings(
    lua_State *L,
    int outbound_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len
);

xray_build_result xray_build_hysteria_proxy_settings(
    lua_State *L,
    int outbound_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len
);

xray_build_result xray_build_shadowsocks_2022_proxy_settings(
    lua_State *L,
    int outbound_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len
);

/*
 * Transport builders.
 * Implemented in transport.c.
 */

xray_build_result xray_build_sender_settings(
    lua_State *L,
    int outbound_index,
    xray_pb_buffer *result,
    char *error,
    size_t error_len
);

#endif
