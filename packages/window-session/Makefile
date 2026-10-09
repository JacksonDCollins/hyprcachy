CXX ?= g++
BUILD_DIR ?= build
CPPFLAGS += $(shell pkg-config --cflags hyprland lua wayland-server) -I$(BUILD_DIR)
CXXFLAGS += -std=c++23 -pthread -O2 -Wall -Wextra -Wno-unused-parameter

.PHONY: all clean
all: $(BUILD_DIR)/window-session.so

$(BUILD_DIR):
	mkdir -p "$@"

$(BUILD_DIR)/xx-session-management-v1-server.h: xx-session-management-v1.xml | $(BUILD_DIR)
	wayland-scanner server-header "$<" "$@"

$(BUILD_DIR)/session-protocol.c: xx-session-management-v1.xml | $(BUILD_DIR)
	wayland-scanner private-code "$<" "$@"

$(BUILD_DIR)/session-protocol.o: $(BUILD_DIR)/session-protocol.c
	$(CC) $(shell pkg-config --cflags wayland-server) $(CFLAGS) -fPIC -c -o "$@" "$<"

$(BUILD_DIR)/window-session.so: plugin.cpp tree.hpp filesystem.hpp file-worker.hpp window-state.hpp session-store.hpp session-protocol.hpp $(BUILD_DIR)/xx-session-management-v1-server.h $(BUILD_DIR)/session-protocol.o | $(BUILD_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -shared -fPIC -o "$@" plugin.cpp $(BUILD_DIR)/session-protocol.o $(LDFLAGS) $(shell pkg-config --libs lua wayland-server)

clean:
	rm -rf -- "$(BUILD_DIR)"
