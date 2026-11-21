# Native Lua 5.1 gRPC client for Xray Extender.
# The LuCI build system passes the target compiler, CFLAGS, LDFLAGS and FPIC.

TARGET := xray_grpc.so
INSTALL ?= install
OBJECTS := xray_grpc.o protocol.o transport.o

.PHONY: all clean compile install

all: compile

compile: $(TARGET)

$(TARGET): $(OBJECTS)
	$(CC) -shared $(LDFLAGS) -o $@ $(OBJECTS) -lnghttp2 -llua

xray_grpc.o: xray_grpc.c xray_grpc_internal.h
	$(CC) $(CFLAGS) $(FPIC) -Wall -Wextra -std=gnu99 -c -o $@ $<

protocol.o: protocol.c xray_grpc_internal.h
	$(CC) $(CFLAGS) $(FPIC) -Wall -Wextra -std=gnu99 -c -o $@ $<

transport.o: transport.c xray_grpc_internal.h
	$(CC) $(CFLAGS) $(FPIC) -Wall -Wextra -std=gnu99 -c -o $@ $<

clean:
	rm -f $(TARGET) $(OBJECTS)

install: $(TARGET)
	mkdir -p $(DESTDIR)/usr/lib/lua
	$(INSTALL) -m 0755 $(TARGET) $(DESTDIR)/usr/lib/lua/$(TARGET)
