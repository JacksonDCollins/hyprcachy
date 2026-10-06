CXX ?= g++
BUILD_DIR ?= build
CPPFLAGS += $(shell pkg-config --cflags hyprland lua)
CXXFLAGS += -std=c++23 -O2 -Wall -Wextra -Wno-unused-parameter

.PHONY: all clean
all: $(BUILD_DIR)/window-session.so

$(BUILD_DIR):
	mkdir -p "$@"

$(BUILD_DIR)/window-session.so: plugin.cpp tree.hpp filesystem.hpp window-state.hpp | $(BUILD_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -shared -fPIC -o "$@" plugin.cpp $(LDFLAGS)

clean:
	rm -rf -- "$(BUILD_DIR)"
