# Builds the classic NVST UDP video bridge used by the "NVST (GStreamer)"
# stream transport. Receives GFN video over the classic Mjolnir UDP path
# (RTSP SETUP/PLAY → SRTP → NV_VIDEO_PACKET → Annex-B AUs → VAAPI/D3D11
# hardware decode), a port of OpenNOW's native/opennow-streamer.
#
#   make            -> build/libnvst_bridge.so
#   make test       -> build + run the pure-logic unit tests
#   make clean
#
# Requires: gcc, pkg-config, gstreamer-1.0 + app/video plugins, openssl,
# libsrtp2, glib. The hardware decoder element (vah264dec) ships in
# gst-plugins-bad >= 1.20.

CC      ?= gcc
PKGS    := gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 openssl
CFLAGS  += -std=c11 -O2 -fPIC -Wall -Wextra $(shell pkg-config --cflags $(PKGS))
LIBS    := $(shell pkg-config --libs $(PKGS)) -lsrtp2 -pthread

OUT     := build/libnvst_bridge.so
TESTS   := build/nvst_self_test

all: $(OUT)

$(OUT): nvst_bridge.c nvst_bridge.h
	mkdir -p build
	$(CC) $(CFLAGS) -shared -o $@ nvst_bridge.c $(LIBS)
	@echo ""
	@echo "Built $(OUT)"
	@echo "Try it with:  NVST_BRIDGE_LIB=$$(pwd)/$(OUT) flutter run -d linux"

# Pure-logic self test: SRTP key packing, NV_VIDEO_PACKET parse, frame
# assembly, AES-key hex parse. Compiled from the same translation unit so the
# helpers are verified as built.
test: nvst_bridge.c nvst_bridge.h
	mkdir -p build
	$(CC) $(CFLAGS) -D NVST_SELF_TEST -o $(TESTS) nvst_bridge.c $(LIBS)
	./$(TESTS)

clean:
	rm -rf build

.PHONY: all test clean
