# Builds the GStreamer webrtcbin bridge used by the experimental
# "WebRTCBIN (FFI)" stream transport (see lib/state/gst_bridge_ffi.dart).
#
#   make            -> build/libgst_bridge.so
#   make install    -> copies it next to gst_bridge.c (dev lookup path)
#   make clean
#
# Requires: gcc, pkg-config, gstreamer-1.0 + app/sdp/video/webrtc plugins.
# The webrtcbin plugin ships in gst-plugins-bad.

CC      ?= gcc
PKGS    := gstreamer-1.0 gstreamer-app-1.0 gstreamer-sdp-1.0 \
           gstreamer-video-1.0 gstreamer-webrtc-1.0
CFLAGS  += -std=c11 -O2 -fPIC -Wall -Wextra $(shell pkg-config --cflags $(PKGS))
LIBS    := $(shell pkg-config --libs $(PKGS))

OUT     := build/libgst_bridge.so

all: $(OUT)

$(OUT): gst_bridge.c gst_bridge.h
	mkdir -p build
	$(CC) $(CFLAGS) -shared -o $@ gst_bridge.c $(LIBS)
	@echo ""
	@echo "Built $(OUT)"
	@echo "Try it with:  GST_BRIDGE_LIB=$$(pwd)/$(OUT) flutter run -d linux"

install: $(OUT)
	cp $(OUT) libgst_bridge.so
	@echo "Copied to ./libgst_bridge.so (dev lookup path)"

clean:
	rm -rf build libgst_bridge.so

.PHONY: all install clean
