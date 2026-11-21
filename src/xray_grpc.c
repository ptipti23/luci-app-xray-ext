#define _POSIX_C_SOURCE 200809L

#include "xray_grpc_internal.h"
#include <lua.h>
#include <lauxlib.h>
#include <nghttp2/nghttp2.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define XRAY_GRPC_HOST          "127.0.0.1"
#define XRAY_GRPC_PORT          8080
#define XRAY_GRPC_TIMEOUT_SEC  3
#define XRAY_GRPC_MAX_BODY      (8u * 1024u * 1024u)
#define XRAY_GRPC_MAX_JSON      (2u * 1024u * 1024u)
#define XRAY_GRPC_ERROR_SIZE    256

#define LIST_OUTBOUNDS_PATH \
    "/xray.app.proxyman.command.HandlerService/ListOutbounds"

#define REMOVE_OUTBOUND_PATH \
    "/xray.app.proxyman.command.HandlerService/RemoveOutbound"

#define GET_BALANCER_INFO_PATH \
    "/xray.app.router.command.RoutingService/GetBalancerInfo"

#define ADD_OUTBOUND_PATH \
    "/xray.app.proxyman.command.HandlerService/AddOutbound"

typedef xray_pb_buffer byte_buffer;

typedef struct {
    const uint8_t *data;
    size_t len;
    size_t offset;
} request_source;

typedef struct {
    int fd;
    nghttp2_session *session;
    int32_t stream_id;
    int stream_closed;
    uint32_t stream_error;
    int http_status;
    int grpc_status;
    int grpc_status_seen;
    int grpc_content_type;
    byte_buffer body;
    char error[XRAY_GRPC_ERROR_SIZE];
} grpc_client;

static grpc_client g_client = { .fd = -1, .body = { .limit = XRAY_GRPC_MAX_BODY } };

static void set_error(grpc_client *client, const char *message)
{
    if (client == NULL || client->error[0] != '\0')
        return;

    snprintf(client->error, sizeof(client->error), "%s", message);
}

static void buffer_reset(byte_buffer *buffer)
{
    if (buffer == NULL)
        return;

    buffer->len = 0;
}

static void buffer_clear(byte_buffer *buffer)
{
    if (buffer == NULL)
        return;

    free(buffer->data);
    buffer->data = NULL;
    buffer->len = 0;
    buffer->cap = 0;
}

static int buffer_reserve(byte_buffer *buffer, size_t extra)
{
    size_t needed;
    size_t capacity;
    unsigned char *next;

    if (extra > buffer->limit || buffer->len > buffer->limit - extra)
        return -1;

    needed = buffer->len + extra;
    if (needed <= buffer->cap)
        return 0;

    capacity = buffer->cap ? buffer->cap : 4096;
    while (capacity < needed) {
        if (capacity > buffer->limit / 2) {
            capacity = buffer->limit;
            break;
        }
        capacity *= 2;
    }

    if (capacity < needed)
        return -1;

    next = (unsigned char *)realloc(buffer->data, capacity);
    if (next == NULL)
        return -1;

    buffer->data = next;
    buffer->cap = capacity;
    return 0;
}

static int buffer_append(byte_buffer *buffer, const void *data, size_t len)
{
    if (buffer_reserve(buffer, len) != 0)
        return -1;

    if (len != 0)
        memcpy(buffer->data + buffer->len, data, len);

    buffer->len += len;
    return 0;
}

static void client_reset_response(grpc_client *client)
{
    client->stream_id = -1;
    client->stream_closed = 0;
    client->stream_error = NGHTTP2_NO_ERROR;
    client->http_status = 0;
    client->grpc_status = -1;
    client->grpc_status_seen = 0;
    client->grpc_content_type = 0;
    client->error[0] = '\0';
    buffer_reset(&client->body);
}

static void client_disconnect(grpc_client *client)
{
    if (client->session != NULL) {
        nghttp2_session_del(client->session);
        client->session = NULL;
    }

    if (client->fd >= 0) {
        close(client->fd);
        client->fd = -1;
    }

    client_reset_response(client);
    buffer_clear(&client->body);
}

static nghttp2_ssize send_callback(nghttp2_session *session,
                                  const uint8_t *data,
                                  size_t length,
                                  int flags,
                                  void *user_data)
{
    grpc_client *client = (grpc_client *)user_data;
    ssize_t sent;

    (void)session;
    (void)flags;

    do {
#ifdef MSG_NOSIGNAL
        sent = send(client->fd, data, length, MSG_NOSIGNAL);
#else
        sent = send(client->fd, data, length, 0);
#endif
    } while (sent < 0 && errno == EINTR);

    if (sent < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return NGHTTP2_ERR_WOULDBLOCK;

        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }

    return (nghttp2_ssize)sent;
}

static int on_header_callback(nghttp2_session *session,
                              const nghttp2_frame *frame,
                              const uint8_t *name,
                              size_t namelen,
                              const uint8_t *value,
                              size_t valuelen,
                              uint8_t flags,
                              void *user_data)
{
    grpc_client *client = (grpc_client *)user_data;
    char number[16];
    char *end;
    long parsed;

    (void)session;
    (void)flags;

    if (frame->hd.stream_id != client->stream_id)
        return 0;

    if (namelen == 7 && memcmp(name, ":status", 7) == 0) {
        if (valuelen == 3) {
            memcpy(number, value, 3);
            number[3] = '\0';
            parsed = strtol(number, &end, 10);
            if (*end == '\0')
                client->http_status = (int)parsed;
        }
    } else if (namelen == 11 && memcmp(name, "grpc-status", 11) == 0) {
        if (valuelen == 0 || valuelen >= sizeof(number))
            return 0;

        memcpy(number, value, valuelen);
        number[valuelen] = '\0';
        errno = 0;
        parsed = strtol(number, &end, 10);
        if (errno == 0 && *end == '\0' && parsed >= 0 && parsed <= 16) {
            client->grpc_status = (int)parsed;
            client->grpc_status_seen = 1;
        }
    } else if (namelen == 12 && memcmp(name, "content-type", 12) == 0) {
        if (valuelen >= 16 && strncasecmp((const char *)value, "application/grpc", 16) == 0)
            client->grpc_content_type = 1;
    }

    return 0;
}

static int on_data_chunk_recv_callback(nghttp2_session *session,
                                       uint8_t flags,
                                       int32_t stream_id,
                                       const uint8_t *data,
                                       size_t len,
                                       void *user_data)
{
    grpc_client *client = (grpc_client *)user_data;

    (void)session;
    (void)flags;

    if (stream_id != client->stream_id)
        return 0;

    if (buffer_append(&client->body, data, len) != 0) {
        set_error(client, "gRPC response exceeds 8 MiB or memory allocation failed");
        return NGHTTP2_ERR_CALLBACK_FAILURE;
    }

    return 0;
}

static int on_stream_close_callback(nghttp2_session *session,
                                    int32_t stream_id,
                                    uint32_t error_code,
                                    void *user_data)
{
    grpc_client *client = (grpc_client *)user_data;

    (void)session;

    if (stream_id == client->stream_id) {
        client->stream_closed = 1;
        client->stream_error = error_code;
    }

    return 0;
}

static int client_connect(grpc_client *client)
{
    struct sockaddr_in address;
    struct timeval timeout;
    nghttp2_session_callbacks *callbacks = NULL;
    int fd = -1;
    int flags;
    int rv;

    if (client->session != NULL && client->fd >= 0)
        return 0;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        snprintf(client->error, sizeof(client->error),
                 "socket: %s", strerror(errno));
        return -1;
    }

    flags = fcntl(fd, F_GETFD, 0);
    if (flags >= 0)
        (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);

    timeout.tv_sec = XRAY_GRPC_TIMEOUT_SEC;
    timeout.tv_usec = 0;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(XRAY_GRPC_PORT);
    if (inet_pton(AF_INET, XRAY_GRPC_HOST, &address.sin_addr) != 1) {
        snprintf(client->error, sizeof(client->error), "invalid API address");
        close(fd);
        return -1;
    }

    do {
        rv = connect(fd, (struct sockaddr *)&address, sizeof(address));
    } while (rv < 0 && errno == EINTR);

    if (rv < 0) {
        snprintf(client->error, sizeof(client->error),
                 "connect to %s:%d: %s",
                 XRAY_GRPC_HOST, XRAY_GRPC_PORT, strerror(errno));
        close(fd);
        return -1;
    }

    rv = nghttp2_session_callbacks_new(&callbacks);
    if (rv != 0) {
        snprintf(client->error, sizeof(client->error),
                 "nghttp2 callbacks: %s", nghttp2_strerror(rv));
        close(fd);
        return -1;
    }

    nghttp2_session_callbacks_set_send_callback2(callbacks, send_callback);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, on_header_callback);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(
        callbacks, on_data_chunk_recv_callback);
    nghttp2_session_callbacks_set_on_stream_close_callback(
        callbacks, on_stream_close_callback);

    client->fd = fd;
    rv = nghttp2_session_client_new(&client->session, callbacks, client);
    nghttp2_session_callbacks_del(callbacks);

    if (rv != 0) {
        snprintf(client->error, sizeof(client->error),
                 "nghttp2 client session: %s", nghttp2_strerror(rv));
        if (client->fd >= 0)
            close(client->fd);
        client->fd = -1;
        client->session = NULL;
        buffer_clear(&client->body);
        return -1;
    }

    rv = nghttp2_submit_settings(
        client->session,
        NGHTTP2_FLAG_NONE,
        NULL,
        0
    );

    if (rv != 0) {
        snprintf(client->error, sizeof(client->error),
                 "nghttp2 submit SETTINGS: %s", nghttp2_strerror(rv));

        nghttp2_session_del(client->session);
        client->session = NULL;

        if (client->fd >= 0) {
            close(client->fd);
            client->fd = -1;
        }

        buffer_clear(&client->body);
        return -1;
    }

    client_reset_response(client);
    return 0;
}

static nghttp2_ssize request_data_callback(nghttp2_session *session,
                                           int32_t stream_id,
                                           uint8_t *buf,
                                           size_t length,
                                           uint32_t *data_flags,
                                           nghttp2_data_source *source,
                                           void *user_data)
{
    request_source *request = (request_source *)source->ptr;
    size_t remaining;
    size_t amount;

    (void)session;
    (void)stream_id;
    (void)user_data;

    remaining = request->len - request->offset;
    amount = remaining < length ? remaining : length;

    if (amount != 0) {
        memcpy(buf, request->data + request->offset, amount);
        request->offset += amount;
    }

    if (request->offset == request->len)
        *data_flags |= NGHTTP2_DATA_FLAG_EOF;

    return (nghttp2_ssize)amount;
}

static int wait_readable(grpc_client *client)
{
    fd_set readfds;
    struct timeval timeout;
    int rv;

    for (;;) {
        FD_ZERO(&readfds);
        FD_SET(client->fd, &readfds);
        timeout.tv_sec = XRAY_GRPC_TIMEOUT_SEC;
        timeout.tv_usec = 0;

        rv = select(client->fd + 1, &readfds, NULL, NULL, &timeout);
        if (rv > 0)
            return 0;
        if (rv == 0) {
            set_error(client, "gRPC response timed out");
            return -1;
        }
        if (errno == EINTR)
            continue;

        snprintf(client->error, sizeof(client->error),
                 "select: %s", strerror(errno));
        return -1;
    }
}

static int perform_grpc_request(grpc_client *client,
                                const char *path_value,
                                const uint8_t *request_data,
                                size_t request_len,
                                const char *method_name)
{
    static const uint8_t method[] = ":method";
    static const uint8_t post[] = "POST";
    static const uint8_t scheme[] = ":scheme";
    static const uint8_t http[] = "http";
    static const uint8_t authority[] = ":authority";
    static const uint8_t authority_value[] = "127.0.0.1:8080";
    static const uint8_t path[] = ":path";
    static const uint8_t content_type[] = "content-type";
    static const uint8_t content_type_value[] = "application/grpc";
    static const uint8_t te[] = "te";
    static const uint8_t trailers[] = "trailers";
    static const uint8_t user_agent[] = "user-agent";
    static const uint8_t user_agent_value[] = "xray-extd-grpc/1.0";

    nghttp2_nv headers[] = {
        { (uint8_t *)method, (uint8_t *)post, sizeof(method) - 1,
          sizeof(post) - 1, NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)scheme, (uint8_t *)http, sizeof(scheme) - 1,
          sizeof(http) - 1, NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)authority, (uint8_t *)authority_value,
          sizeof(authority) - 1, sizeof(authority_value) - 1,
          NGHTTP2_NV_FLAG_NONE },
		{ (uint8_t *)path, (uint8_t *)path_value,
		  sizeof(path) - 1, strlen(path_value), NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)content_type, (uint8_t *)content_type_value,
          sizeof(content_type) - 1, sizeof(content_type_value) - 1,
          NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)te, (uint8_t *)trailers, sizeof(te) - 1,
          sizeof(trailers) - 1, NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)user_agent, (uint8_t *)user_agent_value,
          sizeof(user_agent) - 1, sizeof(user_agent_value) - 1,
          NGHTTP2_NV_FLAG_NONE }
    };

	request_source request = {
	    .data = request_data,
	    .len = request_len,
	    .offset = 0
	};
    nghttp2_data_provider2 provider;
    int rv;
    unsigned char input[16384];

    client_reset_response(client);

    memset(&provider, 0, sizeof(provider));
    provider.source.ptr = &request;
    provider.read_callback = request_data_callback;

    client->stream_id = nghttp2_submit_request2(
        client->session, NULL,
        headers, sizeof(headers) / sizeof(headers[0]),
        &provider, NULL);

    if (client->stream_id < 0) {
        snprintf(client->error, sizeof(client->error),
                 "submit %s: %s",
                 method_name, nghttp2_strerror(client->stream_id));
        return -1;
    }

    rv = nghttp2_session_send(client->session);
    if (rv != 0) {
        snprintf(client->error, sizeof(client->error),
                 "send %s: %s",
        		method_name, nghttp2_strerror(rv));
        return -1;
    }

    while (!client->stream_closed) {
        ssize_t received;
        ssize_t consumed;
        size_t offset = 0;

        if (wait_readable(client) != 0)
            return -1;

        do {
            received = recv(client->fd, input, sizeof(input), 0);
        } while (received < 0 && errno == EINTR);

        if (received == 0) {
            set_error(client, "Xray API closed the HTTP/2 connection");
            return -1;
        }
        if (received < 0) {
            snprintf(client->error, sizeof(client->error),
                     "recv: %s", strerror(errno));
            return -1;
        }

        while (offset < (size_t)received) {
            consumed = nghttp2_session_mem_recv(
                client->session, input + offset, (size_t)received - offset);

            if (consumed < 0) {
                snprintf(client->error, sizeof(client->error),
                         "receive HTTP/2: %s", nghttp2_strerror((int)consumed));
                return -1;
            }
            if (consumed == 0) {
                set_error(client, "HTTP/2 parser made no progress");
                return -1;
            }

            offset += (size_t)consumed;
        }

        rv = nghttp2_session_send(client->session);
        if (rv != 0) {
            snprintf(client->error, sizeof(client->error),
                     "send HTTP/2 control frame: %s", nghttp2_strerror(rv));
            return -1;
        }
    }

    if (client->stream_error != NGHTTP2_NO_ERROR) {
        snprintf(client->error, sizeof(client->error),
                 "HTTP/2 stream closed with error %u", client->stream_error);
        return -1;
    }

    if (client->http_status != 200) {
        snprintf(client->error, sizeof(client->error),
                 "HTTP status %d", client->http_status);
        return -1;
    }

    if (!client->grpc_content_type) {
        set_error(client, "server did not return application/grpc content-type");
        return -1;
    }

    if (!client->grpc_status_seen) {
        set_error(client, "gRPC response has no grpc-status trailer");
        return -1;
    }

    if (client->grpc_status != 0) {
		snprintf(client->error, sizeof(client->error),
		         "gRPC %s failed with status %d",
		         method_name, client->grpc_status);
        return -1;
    }

    return 0;
}

static int read_varint(const uint8_t *data, size_t len,
                       size_t *offset, uint64_t *value)
{
    uint64_t result = 0;
    unsigned int shift = 0;

    while (*offset < len && shift < 70) {
        uint8_t byte = data[(*offset)++];

        if (shift == 63 && (byte & 0x7e) != 0)
            return -1;

        result |= (uint64_t)(byte & 0x7f) << shift;

        if ((byte & 0x80) == 0) {
            *value = result;
            return 0;
        }

        shift += 7;
    }

    return -1;
}

static int skip_field(const uint8_t *data, size_t len,
                      size_t *offset, unsigned int wire_type)
{
    uint64_t field_len;

    switch (wire_type) {
    case 0:
        return read_varint(data, len, offset, &field_len);
    case 1:
        if (len - *offset < 8)
            return -1;
        *offset += 8;
        return 0;
    case 2:
        if (read_varint(data, len, offset, &field_len) != 0)
            return -1;
        if (field_len > len - *offset)
            return -1;
        *offset += (size_t)field_len;
        return 0;
    case 5:
        if (len - *offset < 4)
            return -1;
        *offset += 4;
        return 0;
    default:
        return -1;
    }
}

static int json_append_string(byte_buffer *out,
                              const uint8_t *value, size_t len)
{
    static const char hex[] = "0123456789abcdef";
    size_t i;
    char escaped[6];

    if (buffer_append(out, "\"", 1) != 0)
        return -1;

    for (i = 0; i < len; i++) {
        unsigned char ch = value[i];

        switch (ch) {
        case '"':
            if (buffer_append(out, "\\\"", 2) != 0) return -1;
            break;
        case '\\':
            if (buffer_append(out, "\\\\", 2) != 0) return -1;
            break;
        case '\b':
            if (buffer_append(out, "\\b", 2) != 0) return -1;
            break;
        case '\f':
            if (buffer_append(out, "\\f", 2) != 0) return -1;
            break;
        case '\n':
            if (buffer_append(out, "\\n", 2) != 0) return -1;
            break;
        case '\r':
            if (buffer_append(out, "\\r", 2) != 0) return -1;
            break;
        case '\t':
            if (buffer_append(out, "\\t", 2) != 0) return -1;
            break;
        default:
            if (ch < 0x20) {
                escaped[0] = '\\';
                escaped[1] = 'u';
                escaped[2] = '0';
                escaped[3] = '0';
                escaped[4] = hex[ch >> 4];
                escaped[5] = hex[ch & 0x0f];
                if (buffer_append(out, escaped, sizeof(escaped)) != 0)
                    return -1;
            } else if (buffer_append(out, &ch, 1) != 0) {
                return -1;
            }
            break;
        }
    }

    return buffer_append(out, "\"", 1);
}

static int parse_outbound_tag(const uint8_t *data, size_t len,
                              uint8_t **tag, size_t *tag_len)
{
    size_t offset = 0;

    *tag = NULL;
    *tag_len = 0;

    while (offset < len) {
        uint64_t key;
        unsigned int field_number;
        unsigned int wire_type;

        if (read_varint(data, len, &offset, &key) != 0)
            goto malformed;

        field_number = (unsigned int)(key >> 3);
        wire_type = (unsigned int)(key & 7);
        if (field_number == 0)
            goto malformed;

        if (field_number == 1 && wire_type == 2) {
            uint64_t string_len;
            uint8_t *copy;

            if (read_varint(data, len, &offset, &string_len) != 0)
                goto malformed;
            if (string_len > len - offset || string_len > 4096)
                goto malformed;

            copy = (uint8_t *)malloc((size_t)string_len + 1);
            if (copy == NULL)
                goto no_memory;

            if (string_len != 0)
                memcpy(copy, data + offset, (size_t)string_len);
            copy[string_len] = '\0';

            free(*tag);
            *tag = copy;
            *tag_len = (size_t)string_len;
            offset += (size_t)string_len;
        } else if (skip_field(data, len, &offset, wire_type) != 0) {
            goto malformed;
        }
    }

    return 0;

malformed:
    free(*tag);
    *tag = NULL;
    *tag_len = 0;
    return -1;

no_memory:
    free(*tag);
    *tag = NULL;
    *tag_len = 0;
    return -2;
}

static int parse_list_outbounds(const uint8_t *data, size_t len,
                                char **json, size_t *json_len,
                                char *error, size_t error_len)
{
    byte_buffer out = { .limit = XRAY_GRPC_MAX_JSON };
    size_t offset = 0;
    size_t count = 0;

    if (len < 5) {
        snprintf(error, error_len, "short gRPC message");
        return -1;
    }

    if (data[0] != 0) {
        snprintf(error, error_len, "compressed gRPC response is unsupported");
        return -1;
    }

    {
        uint32_t message_len = ((uint32_t)data[1] << 24) |
                               ((uint32_t)data[2] << 16) |
                               ((uint32_t)data[3] << 8) |
                               (uint32_t)data[4];
        if ((size_t)message_len != len - 5) {
            snprintf(error, error_len, "invalid gRPC message length");
            return -1;
        }
    }

    data += 5;
    len -= 5;

    if (buffer_append(&out, "{\"outbounds\":[", 14) != 0)
        goto no_memory;

    while (offset < len) {
        uint64_t key;
        unsigned int field_number;
        unsigned int wire_type;

        if (read_varint(data, len, &offset, &key) != 0)
            goto malformed;

        field_number = (unsigned int)(key >> 3);
        wire_type = (unsigned int)(key & 7);
        if (field_number == 0)
            goto malformed;

        if (field_number == 1 && wire_type == 2) {
            uint64_t outbound_len;
            uint8_t *tag = NULL;
            size_t tag_len = 0;
            int parse_result;

            if (read_varint(data, len, &offset, &outbound_len) != 0)
                goto malformed;
            if (outbound_len > len - offset)
                goto malformed;

            parse_result = parse_outbound_tag(
                data + offset, (size_t)outbound_len, &tag, &tag_len);
            if (parse_result == -2)
                goto no_memory;
            if (parse_result != 0)
                goto malformed;

            if (count != 0 && buffer_append(&out, ",", 1) != 0) {
                free(tag);
                goto no_memory;
            }
            if (buffer_append(&out, "{\"tag\":", 7) != 0) {
                free(tag);
                goto no_memory;
            }
            if (tag == NULL) {
                if (buffer_append(&out, "\"\"", 2) != 0) {
                    free(tag);
                    goto no_memory;
                }
            } else if (json_append_string(&out, tag, tag_len) != 0) {
                free(tag);
                goto no_memory;
            }
            if (buffer_append(&out, "}", 1) != 0) {
                free(tag);
                goto no_memory;
            }

            free(tag);
            count++;
            offset += (size_t)outbound_len;
        } else if (skip_field(data, len, &offset, wire_type) != 0) {
            goto malformed;
        }
    }

    if (buffer_append(&out, "]}", 2) != 0)
        goto no_memory;
    if (buffer_append(&out, "\0", 1) != 0)
        goto no_memory;

    *json = (char *)out.data;
    *json_len = out.len - 1;
    return 0;

malformed:
    snprintf(error, error_len, "malformed ListOutbounds protobuf response");
    free(out.data);
    return -1;

no_memory:
    snprintf(error, error_len, "not enough memory to build outbound list");
    free(out.data);
    return -1;
}

static int get_outbounds_json(char **json, size_t *json_len,
                              char *error, size_t error_len)
{
    int attempt;

    *json = NULL;
    *json_len = 0;
    error[0] = '\0';

    for (attempt = 0; attempt < 2; attempt++) {
        if (client_connect(&g_client) != 0) {
            snprintf(error, error_len, "%s",
                     g_client.error[0] ? g_client.error : "cannot connect to Xray API");
            client_disconnect(&g_client);
            continue;
        }

		static const uint8_t empty_request[5] = { 0, 0, 0, 0, 0 };

        if (perform_grpc_request(
		        &g_client,
		        LIST_OUTBOUNDS_PATH,
		        empty_request,
		        sizeof(empty_request),
		        "ListOutbounds") != 0) {
            snprintf(error, error_len, "%s",
                     g_client.error[0] ? g_client.error : "ListOutbounds request failed");
            client_disconnect(&g_client);
            continue;
        }

        if (parse_list_outbounds(g_client.body.data, g_client.body.len,
                                 json, json_len, error, error_len) != 0) {
            buffer_clear(&g_client.body);
            return -1;
        }

        buffer_clear(&g_client.body);
        return 0;
    }

    return -1;
}

static size_t encode_varint(uint64_t value, uint8_t *output)
{
    size_t len = 0;

    while (value >= 0x80) {
        output[len++] = (uint8_t)(value | 0x80);
        value >>= 7;
    }

    output[len++] = (uint8_t)value;

    return len;
}


/* =========================================================
 * Native protobuf builder
 * =========================================================
 */

#define XRAY_GRPC_MAX_PROTOBUF (1024u * 1024u)

#define PB_MAX_FIELD_NUMBER 0x1FFFFFFFU


void xray_pb_buffer_init(xray_pb_buffer *buffer)
{
    if (buffer == NULL)
        return;

    memset(buffer, 0, sizeof(*buffer));
    buffer->limit = XRAY_GRPC_MAX_PROTOBUF;
}


void xray_pb_buffer_clear(xray_pb_buffer *buffer)
{
    buffer_clear(buffer);
}


/*
 * Append raw protobuf varint.
 * No field key is added.
 */

int xray_pb_append_varint(
    xray_pb_buffer *buffer,
    uint64_t value)
{
    uint8_t encoded[10];
    size_t len;

    if (buffer == NULL)
        return -1;

    len = encode_varint(value, encoded);

    return buffer_append(buffer, encoded, len);
}


/*
 * Append protobuf uint/enum/bool field.
 *
 * Wire type: 0
 */

int xray_pb_append_uint(
    xray_pb_buffer *buffer,
    uint32_t field,
    uint64_t value)
{
    uint8_t encoded[20];
    size_t len;

    if (buffer == NULL ||
        field == 0 ||
        field > PB_MAX_FIELD_NUMBER)
        return -1;

    len = encode_varint(
        ((uint64_t)field << 3),
        encoded
    );

    len += encode_varint(
        value,
        encoded + len
    );

    return buffer_append(buffer, encoded, len);
}


/*
 * Append protobuf bytes field.
 *
 * Wire type: 2
 */

int xray_pb_append_bytes(
    xray_pb_buffer *buffer,
    uint32_t field,
    const void *data,
    size_t data_len)
{
    uint8_t prefix[20];
    size_t prefix_len;

    if (buffer == NULL ||
        field == 0 ||
        field > PB_MAX_FIELD_NUMBER ||
        (data_len != 0 && data == NULL))
        return -1;

    prefix_len = encode_varint(
        ((uint64_t)field << 3) | 2,
        prefix
    );

    prefix_len += encode_varint(
        (uint64_t)data_len,
        prefix + prefix_len
    );

    if (data_len > SIZE_MAX - prefix_len)
        return -1;

    if (buffer_reserve(
            buffer,
            prefix_len + data_len) != 0)
        return -1;

    memcpy(
        buffer->data + buffer->len,
        prefix,
        prefix_len
    );

    if (data_len != 0) {
        memcpy(
            buffer->data + buffer->len + prefix_len,
            data,
            data_len
        );
    }

    buffer->len += prefix_len + data_len;

    return 0;
}


/*
 * Append protobuf string field.
 */

int xray_pb_append_string(
    xray_pb_buffer *buffer,
    uint32_t field,
    const char *value)
{
    if (value == NULL)
        return -1;

    return xray_pb_append_bytes(
        buffer,
        field,
        value,
        strlen(value)
    );
}


/*
 * Append nested protobuf message.
 */

int xray_pb_append_message(
    xray_pb_buffer *buffer,
    uint32_t field,
    const xray_pb_buffer *message)
{
    if (message == NULL)
        return -1;

    return xray_pb_append_bytes(
        buffer,
        field,
        message->data,
        message->len
    );
}


/*
 * Construct google.protobuf.Any / Xray TypedMessage.
 *
 * field 1 = type string
 * field 2 = serialized message bytes
 *
 * Result buffer must be initialized by caller.
 */

int xray_pb_make_typed_message(
    const char *type_name,
    const xray_pb_buffer *payload,
    xray_pb_buffer *result)
{
    if (type_name == NULL ||
        type_name[0] == '\0' ||
        payload == NULL ||
        result == NULL)
        return -1;

    if (xray_pb_append_string(
            result,
            1,
            type_name) != 0)
        goto error;

    if (xray_pb_append_bytes(
            result,
            2,
            payload->data,
            payload->len) != 0)
        goto error;

    return 0;

error:
    xray_pb_buffer_clear(result);
    return -1;
}


/* =========================================================
 * GetBalancerInfo protobuf decoder
 * =========================================================
 */

/*
 * OverrideInfo:
 *   field 2 = target (string)
 */
static int parse_override_info(const uint8_t *data, size_t len,
                               byte_buffer *target)
{
    size_t offset = 0;

    buffer_reset(target);

    while (offset < len) {
        uint64_t key;
        uint64_t field_len;
        unsigned int field;
        unsigned int wire;

        if (read_varint(data, len, &offset, &key) != 0)
            return -1;

        field = (unsigned int)(key >> 3);
        wire = (unsigned int)(key & 7);

        if (field == 0)
            return -1;

        if (field == 2 && wire == 2) {
            if (read_varint(data, len, &offset, &field_len) != 0)
                return -1;

            if (field_len > len - offset)
                return -1;

            if (buffer_append(target, data + offset,
                              (size_t)field_len) != 0)
                return -1;

            offset += (size_t)field_len;
        } else {
            if (skip_field(data, len, &offset, wire) != 0)
                return -1;
        }
    }

    return 0;
}

/*
 * PrincipleTargetInfo:
 *   field 1 = tag (repeated string)
 */
static int parse_principle_target_info(
    const uint8_t *data,
    size_t len,
    byte_buffer *tags,
    size_t *tag_count)
{
    size_t offset = 0;

    while (offset < len) {
        uint64_t key;
        uint64_t field_len;
        unsigned int field;
        unsigned int wire;

        if (read_varint(data, len, &offset, &key) != 0)
            return -1;

        field = (unsigned int)(key >> 3);
        wire = (unsigned int)(key & 7);

        if (field == 0)
            return -1;

        if (field == 1 && wire == 2) {
            if (read_varint(data, len, &offset, &field_len) != 0)
                return -1;

            if (field_len > len - offset)
                return -1;

            if (*tag_count != 0 &&
                buffer_append(tags, ",", 1) != 0)
                return -1;

            if (json_append_string(
                    tags,
                    data + offset,
                    (size_t)field_len) != 0)
                return -1;

            (*tag_count)++;
            offset += (size_t)field_len;
        } else {
            if (skip_field(data, len, &offset, wire) != 0)
                return -1;
        }
    }

    return 0;
}

/*
 * BalancerMsg:
 *   field 5 = override
 *   field 6 = principle_target
 */
static int parse_balancer_msg(
    const uint8_t *data,
    size_t len,
    byte_buffer *target,
    byte_buffer *tags,
    size_t *tag_count)
{
    size_t offset = 0;

    while (offset < len) {
        uint64_t key;
        uint64_t field_len;
        unsigned int field;
        unsigned int wire;

        if (read_varint(data, len, &offset, &key) != 0)
            return -1;

        field = (unsigned int)(key >> 3);
        wire = (unsigned int)(key & 7);

        if (field == 0)
            return -1;

        if ((field == 5 || field == 6) && wire == 2) {
            const uint8_t *nested;
            size_t nested_len;

            if (read_varint(data, len, &offset, &field_len) != 0)
                return -1;

            if (field_len > len - offset)
                return -1;

            nested = data + offset;
            nested_len = (size_t)field_len;

            if (field == 5) {
                if (parse_override_info(
                        nested, nested_len, target) != 0)
                    return -1;
            } else {
                if (parse_principle_target_info(
                        nested, nested_len,
                        tags, tag_count) != 0)
                    return -1;
            }

            offset += nested_len;
        } else {
            if (skip_field(data, len, &offset, wire) != 0)
                return -1;
        }
    }

    return 0;
}

/*
 * GetBalancerInfoResponse:
 *   field 1 = balancer
 */
static int parse_balancer_response(
    const uint8_t *data,
    size_t len,
    byte_buffer *target,
    byte_buffer *tags,
    size_t *tag_count)
{
    size_t offset = 0;

    while (offset < len) {
        uint64_t key;
        uint64_t field_len;
        unsigned int field;
        unsigned int wire;

        if (read_varint(data, len, &offset, &key) != 0)
            return -1;

        field = (unsigned int)(key >> 3);
        wire = (unsigned int)(key & 7);

        if (field == 0)
            return -1;

        if (field == 1 && wire == 2) {
            if (read_varint(data, len, &offset, &field_len) != 0)
                return -1;

            if (field_len > len - offset)
                return -1;

            if (parse_balancer_msg(
                    data + offset,
                    (size_t)field_len,
                    target, tags, tag_count) != 0)
                return -1;

            offset += (size_t)field_len;
        } else {
            if (skip_field(data, len, &offset, wire) != 0)
                return -1;
        }
    }

    return 0;
}

/* =========================================================
 * GetBalancerInfo RPC
 * =========================================================
 */

static int get_balancer_info_json(
    const char *tag,
    size_t tag_len,
    char **json,
    size_t *json_len,
    char *error,
    size_t error_len)
{
    uint8_t request[4104];
    uint8_t varint[10];
    size_t varint_len;
    size_t protobuf_len;
    size_t offset;

    uint32_t frame_len;

    byte_buffer target = { .limit = XRAY_GRPC_MAX_JSON };
    byte_buffer tags = { .limit = XRAY_GRPC_MAX_JSON };
    byte_buffer output = { .limit = XRAY_GRPC_MAX_JSON };

    size_t tag_count = 0;

    static const char prefix[] =
        "{\"override\":{\"target\":";

    static const char middle[] =
        "},\"principle_target\":{\"tag\":[";

    static const char suffix[] = "]}}";

    int result = -1;

    *json = NULL;
    *json_len = 0;

    error[0] = '\0';

    /* GetBalancerInfoRequest: string tag = 1 */

    varint_len = encode_varint(tag_len, varint);
    protobuf_len = 1 + varint_len + tag_len;

    if (protobuf_len > sizeof(request) - 5) {
        snprintf(error, error_len,
                 "GetBalancerInfo request is too large");
        goto cleanup;
    }

    /* gRPC frame */

    request[0] = 0;
    request[1] = (uint8_t)(protobuf_len >> 24);
    request[2] = (uint8_t)(protobuf_len >> 16);
    request[3] = (uint8_t)(protobuf_len >> 8);
    request[4] = (uint8_t)protobuf_len;

    request[5] = 0x0A;

    memcpy(request + 6, varint, varint_len);
    memcpy(request + 6 + varint_len, tag, tag_len);

    if (client_connect(&g_client) != 0) {
        snprintf(error, error_len, "%s",
                 g_client.error[0] ?
                 g_client.error : "cannot connect to Xray API");

        client_disconnect(&g_client);
        goto cleanup;
    }

    if (perform_grpc_request(
            &g_client,
            GET_BALANCER_INFO_PATH,
            request,
            protobuf_len + 5,
            "GetBalancerInfo") != 0) {

        snprintf(error, error_len, "%s",
                 g_client.error[0] ?
                 g_client.error : "GetBalancerInfo failed");

        client_disconnect(&g_client);
        goto cleanup;
    }

    /* Validate the response gRPC frame. */

    if (g_client.body.len < 5) {
        snprintf(error, error_len,
                 "GetBalancerInfo: incomplete gRPC frame");
        goto cleanup;
    }

    if (g_client.body.data[0] != 0) {
        snprintf(error, error_len,
                 "GetBalancerInfo: compressed response unsupported");
        goto cleanup;
    }

    frame_len =
        ((uint32_t)g_client.body.data[1] << 24) |
        ((uint32_t)g_client.body.data[2] << 16) |
        ((uint32_t)g_client.body.data[3] << 8) |
        (uint32_t)g_client.body.data[4];

    if ((size_t)frame_len != g_client.body.len - 5) {
        snprintf(error, error_len,
                 "GetBalancerInfo: invalid gRPC frame length");
        goto cleanup;
    }

    /* Decode protobuf response. */

    if (parse_balancer_response(
            g_client.body.data + 5,
            frame_len,
            &target,
            &tags,
            &tag_count) != 0) {

        snprintf(error, error_len,
                 "GetBalancerInfo: malformed protobuf response");
        goto cleanup;
    }

    /* Build JSON. */

    if (buffer_append(&output, prefix, sizeof(prefix) - 1) != 0 ||
        json_append_string(
            &output, target.data, target.len) != 0 ||
        buffer_append(&output, middle, sizeof(middle) - 1) != 0) {
        snprintf(error, error_len,
                 "GetBalancerInfo: JSON allocation failed");
        goto cleanup;
    }

    /*
     * tags already contains comma-separated JSON strings.
     * Append them between the array brackets.
     */

    if (buffer_append(&output, tags.data, tags.len) != 0 ||
        buffer_append(&output, suffix, sizeof(suffix) - 1) != 0 ||
        buffer_append(&output, "\0", 1) != 0) {

        snprintf(error, error_len,
                 "GetBalancerInfo: JSON allocation failed");
        goto cleanup;
    }

    *json = (char *)output.data;
    *json_len = output.len - 1;

    output.data = NULL;
    result = 0;

cleanup:
    buffer_clear(&target);
    buffer_clear(&tags);
    buffer_clear(&output);

    return result;
}

static int lua_get_balancer_info(lua_State *L)
{
    const char *tag;
    size_t tag_len;

    char *json = NULL;
    size_t json_len = 0;

    char error[XRAY_GRPC_ERROR_SIZE];

    tag = luaL_checklstring(L, 1, &tag_len);

    if (tag_len == 0 || tag_len > 4096 ||
        memchr(tag, '\0', tag_len) != NULL) {

        lua_pushboolean(L, 0);
        lua_pushstring(L, "Invalid balancer tag");
        lua_pushinteger(L, 1);
        return 3;
    }

    if (get_balancer_info_json(
            tag, tag_len,
            &json, &json_len,
            error, sizeof(error)) == 0) {

        lua_pushboolean(L, 1);
        lua_pushlstring(L, json, json_len);
        lua_pushinteger(L, 0);

        free(json);
    } else {
        lua_pushboolean(L, 0);
        lua_pushstring(L, error[0] ?
                       error : "unknown gRPC error");
        lua_pushinteger(L, 1);
    }

    return 3;
}


/* =========================================================
 * Native ADO: outbound structure validation
 * =========================================================
 */

static xray_build_result check_outbound_keys(
    lua_State *L,
    int table_index,
    char *error,
    size_t error_len)
{
    static const char * const allowed[] = {
        "tag",
        "protocol",
        "settings",
        "streamSettings"
    };

    int top = lua_gettop(L);
    size_t i;

    lua_pushnil(L);

    while (lua_next(L, table_index) != 0) {
        const char *key;
        size_t key_len;
        int found = 0;

        if (lua_type(L, -2) != LUA_TSTRING) {
            lua_settop(L, top);
            snprintf(error, error_len,
                     "outbound contains a non-string key");
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
            snprintf(error, error_len,
                     "unsupported outbound field: %.*s",
                     (int)key_len, key);

            lua_settop(L, top);
            return XRAY_BUILD_UNSUPPORTED;
        }

        lua_pop(L, 1);
    }

    lua_settop(L, top);
    return XRAY_BUILD_OK;
}


/* =========================================================
 * Native ADO
 * =========================================================
 */

static int lua_add_outbound(lua_State *L)
{
    xray_pb_buffer proxy_settings = {0};
    xray_pb_buffer sender_settings = {0};
    xray_pb_buffer outbound_config = {0};
    xray_pb_buffer ado_request = {0};
    xray_pb_buffer grpc_frame = {0};

    const char *tag = NULL;
    size_t tag_len = 0;

    uint8_t grpc_header[5] = {0};

    char error[XRAY_GRPC_ERROR_SIZE] = {0};

    xray_build_result status;
    uint32_t grpc_len;

    int top = lua_gettop(L);
    int result_code = 1;
    int success = 0;

    if (lua_type(L, 1) != LUA_TTABLE) {
        snprintf(error, sizeof(error),
                 "outbound must be a table");
        goto cleanup;
    }

    /*
     * Validate all top-level fields.
     */

    status = check_outbound_keys(
        L, 1, error, sizeof(error));

    if (status == XRAY_BUILD_UNSUPPORTED) {
        result_code = 2;
        goto cleanup;
    }

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    /*
     * Read tag.
     */

    lua_getfield(L, 1, "tag");

    if (lua_type(L, -1) != LUA_TSTRING) {
        lua_pop(L, 1);
        snprintf(error, sizeof(error),
                 "outbound tag must be a string");
        goto cleanup;
    }

    tag = lua_tolstring(L, -1, &tag_len);

    if (tag_len == 0 || tag_len > 4096 ||
        memchr(tag, '\0', tag_len) != NULL) {
        lua_pop(L, 1);
        snprintf(error, sizeof(error),
                 "invalid outbound tag");
        goto cleanup;
    }

    /*
     * The Lua outbound table retains the tag string,
     * so its pointer remains valid after lua_pop().
     */

    lua_pop(L, 1);

    /*
     * Build protocol settings.
     */

    {
        const char *protocol;
        size_t protocol_len;

        lua_getfield(L, 1, "protocol");

        if (lua_type(L, -1) != LUA_TSTRING) {
            lua_pop(L, 1);

            snprintf(error, sizeof(error),
                     "outbound protocol must be a string");

            goto cleanup;
        }

        protocol = lua_tolstring(L, -1, &protocol_len);

        if (protocol_len == 5 &&
            memcmp(protocol, "vless", 5) == 0) {

            lua_pop(L, 1);

            status = xray_build_vless_proxy_settings(
                L, 1, &proxy_settings, error, sizeof(error)
            );

        } else if (protocol_len == 8 &&
                   memcmp(protocol, "hysteria", 8) == 0) {

            lua_pop(L, 1);

            status = xray_build_hysteria_proxy_settings(
                L, 1, &proxy_settings, error, sizeof(error)
            );

        } else if (protocol_len == 11 &&
                   memcmp(protocol, "shadowsocks", 11) == 0) {

            lua_pop(L, 1);

            status = xray_build_shadowsocks_2022_proxy_settings(
                L, 1, &proxy_settings, error, sizeof(error)
            );

        } else {
            lua_pop(L, 1);

            snprintf(error, sizeof(error),
                     "unsupported native outbound protocol");

            result_code = 2;
            goto cleanup;
        }
    }

    if (status == XRAY_BUILD_UNSUPPORTED) {
        result_code = 2;
        goto cleanup;
    }

    if (status != XRAY_BUILD_OK)
        goto cleanup;
    /*
     * Build sender / transport settings.
     */

    status = xray_build_sender_settings(
        L,
        1,
        &sender_settings,
        error,
        sizeof(error)
    );

    if (status == XRAY_BUILD_UNSUPPORTED) {
        result_code = 2;
        goto cleanup;
    }

    if (status != XRAY_BUILD_OK)
        goto cleanup;

    /*
     * OutboundHandlerConfig:
     *
     * tag             = 1
     * sender_settings = 2
     * proxy_settings  = 3
     */

    xray_pb_buffer_init(&outbound_config);

    if (xray_pb_append_string(
            &outbound_config,
            1,
            tag) != 0)
        goto encode_error;

    if (xray_pb_append_message(
            &outbound_config,
            2,
            &sender_settings) != 0)
        goto encode_error;

    if (xray_pb_append_message(
            &outbound_config,
            3,
            &proxy_settings) != 0)
        goto encode_error;

    /*
     * AddOutboundRequest:
     *
     * outbound = 1
     */

    xray_pb_buffer_init(&ado_request);

    if (xray_pb_append_message(
            &ado_request,
            1,
            &outbound_config) != 0)
        goto encode_error;

    if (ado_request.len > UINT32_MAX) {
        snprintf(error, sizeof(error),
                 "AddOutbound request is too large");
        goto cleanup;
    }

    /*
     * gRPC frame:
     *
     * 1 byte compression flag
     * 4 bytes protobuf length (big endian)
     * protobuf payload
     */

    grpc_len = (uint32_t)ado_request.len;

    grpc_header[0] = 0;
    grpc_header[1] = (uint8_t)(grpc_len >> 24);
    grpc_header[2] = (uint8_t)(grpc_len >> 16);
    grpc_header[3] = (uint8_t)(grpc_len >> 8);
    grpc_header[4] = (uint8_t)grpc_len;

    xray_pb_buffer_init(&grpc_frame);

    if (buffer_append(
            &grpc_frame,
            grpc_header,
            sizeof(grpc_header)) != 0)
        goto encode_error;

    if (buffer_append(
            &grpc_frame,
            ado_request.data,
            ado_request.len) != 0)
        goto encode_error;

    /*
     * AddOutbound is non-idempotent.
     *
     * Never retry automatically if the result is uncertain.
     */

    if (client_connect(&g_client) != 0) {
        snprintf(error, sizeof(error), "%s",
                 g_client.error[0] ?
                 g_client.error : "cannot connect to Xray API");

        client_disconnect(&g_client);
        goto cleanup;
    }

    if (perform_grpc_request(
            &g_client,
            ADD_OUTBOUND_PATH,
            grpc_frame.data,
            grpc_frame.len,
            "AddOutbound") != 0) {

        snprintf(error, sizeof(error), "%s",
                 g_client.error[0] ?
                 g_client.error : "AddOutbound failed");

        client_disconnect(&g_client);
        goto cleanup;
    }

    success = 1;
    result_code = 0;
    goto cleanup;

encode_error:
    snprintf(error, sizeof(error),
             "cannot encode AddOutbound protobuf");

cleanup:
    xray_pb_buffer_clear(&proxy_settings);
    xray_pb_buffer_clear(&sender_settings);
    xray_pb_buffer_clear(&outbound_config);
    xray_pb_buffer_clear(&ado_request);
    xray_pb_buffer_clear(&grpc_frame);

    lua_settop(L, top);

    lua_pushboolean(L, success);

    lua_pushstring(
        L,
        success ? "OK" :
        (error[0] ? error : "unknown AddOutbound error")
    );

    lua_pushinteger(L, result_code);

    return 3;
}


static int lua_remove_outbound(lua_State *L)
{
    const char *tag;
    size_t tag_len;
    uint8_t request[4104];
    uint8_t varint[10];
    size_t varint_len;
    size_t protobuf_len;
    size_t grpc_len;
    char error[XRAY_GRPC_ERROR_SIZE];

    tag = luaL_checklstring(L, 1, &tag_len);

    if (tag_len == 0 || tag_len > 4096 ||
        memchr(tag, '\0', tag_len) != NULL) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Invalid outbound tag");
        lua_pushinteger(L, 1);
        return 3;
    }

    /*
     * RemoveOutboundRequest:
     * string tag = 1
     *
     * Protobuf:
     * 0A <length> <tag>
     */

    varint_len = encode_varint(tag_len, varint);

    protobuf_len = 1 + varint_len + tag_len;

    if (protobuf_len > sizeof(request) - 5) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "RemoveOutbound request is too large");
        lua_pushinteger(L, 1);
        return 3;
    }

    /*
     * gRPC frame:
     * 1 byte compression flag
     * 4 bytes message length (big endian)
     * protobuf message
     */

    grpc_len = protobuf_len;

    request[0] = 0;
    request[1] = (uint8_t)(grpc_len >> 24);
    request[2] = (uint8_t)(grpc_len >> 16);
    request[3] = (uint8_t)(grpc_len >> 8);
    request[4] = (uint8_t)grpc_len;

    request[5] = 0x0A;

    memcpy(request + 6, varint, varint_len);
    memcpy(request + 6 + varint_len, tag, tag_len);

    error[0] = '\0';

    /*
     * Do not retry destructive requests automatically:
     * the connection may fail after Xray has processed the removal.
     */

    if (client_connect(&g_client) != 0) {
        snprintf(error, sizeof(error), "%s",
                 g_client.error[0] ?
                 g_client.error : "cannot connect to Xray API");

        client_disconnect(&g_client);

        lua_pushboolean(L, 0);
        lua_pushstring(L, error);
        lua_pushinteger(L, 1);
        return 3;
    }

    if (perform_grpc_request(
            &g_client,
            REMOVE_OUTBOUND_PATH,
            request,
            grpc_len + 5,
            "RemoveOutbound") != 0) {

        snprintf(error, sizeof(error), "%s",
                 g_client.error[0] ?
                 g_client.error : "RemoveOutbound failed");

        client_disconnect(&g_client);

        lua_pushboolean(L, 0);
        lua_pushstring(L, error);
        lua_pushinteger(L, 1);
        return 3;
    }

    lua_pushboolean(L, 1);
    lua_pushstring(L, "OK");
    lua_pushinteger(L, 0);

    return 3;
}

static int lua_list_outbounds(lua_State *L)
{
    char *json = NULL;
    size_t json_len = 0;
    char error[XRAY_GRPC_ERROR_SIZE];

    if (get_outbounds_json(&json, &json_len, error, sizeof(error)) == 0) {
        lua_pushboolean(L, 1);
        lua_pushlstring(L, json, json_len);
        lua_pushinteger(L, 0);
        free(json);
    } else {
        lua_pushboolean(L, 0);
        lua_pushstring(L, error[0] ? error : "unknown gRPC error");
        lua_pushinteger(L, 1);
    }

    return 3;
}

static int l_grpc_close(lua_State *L)
{
    (void)L;
    client_disconnect(&g_client);
    return 0;
}

static const luaL_Reg module_functions[] = {
    { "list_outbounds", lua_list_outbounds },
    { "remove_outbound", lua_remove_outbound },
    { "add_outbound", lua_add_outbound },
    { "get_balancer_info", lua_get_balancer_info },
    { "close", l_grpc_close },
    { NULL, NULL }
};

int luaopen_xray_grpc(lua_State *L)
{
    luaL_register(L, "xray_grpc", module_functions);
    return 1;
}
