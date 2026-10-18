# LINE.app macOS VoiceOver accessibility bridge

LINE_APP     ?= /Applications/LINE.app
QT_FW        := $(LINE_APP)/Contents/Frameworks
ARCH         := arm64
MACOS_MIN    := 14.0

BUILD        := build
DYLIB        := $(BUILD)/libline_a11y.dylib
AX_INSPECT   := $(BUILD)/ax_inspect
SHIM         := $(BUILD)/libqcocoa_a11y.dylib

CACHE_DIR    := $(patsubst %/,%,$(shell getconf DARWIN_USER_CACHE_DIR))
A11Y_DIR     := $(CACHE_DIR)/jp.naver.line.mac/a11y
INSTALL_DIR  := $(A11Y_DIR)/platformthemes
INSTALLED    := $(INSTALL_DIR)/libline_a11y.dylib
# The call window runs in LineCall.app (its own sandbox container); see src/call_launch_hook.h.
CALL_A11Y_DIR := $(CACHE_DIR)/jp.naver.line.mac.LineCall/a11y
CALL_INSTALLED := $(CALL_A11Y_DIR)/platformthemes/libline_a11y.dylib

CXX          := xcrun clang++
SWIFTC       := xcrun swiftc

CXXFLAGS     := -arch $(ARCH) -mmacosx-version-min=$(MACOS_MIN) -std=c++17 -O2 -g -fPIC \
                -fobjc-arc -fvisibility=hidden -fvisibility-inlines-hidden \
                -Wall -Wextra -Wno-unused-parameter \
                -iframework $(QT_FW) -DQT_NO_DEBUG -DQT_NO_KEYWORDS \
                -isystem $(QT_FW)/QtGui.framework/Headers/6.6.3/QtGui -isystem src/compat
LDFLAGS      := -arch $(ARCH) -mmacosx-version-min=$(MACOS_MIN) -dynamiclib \
                -install_name @rpath/libline_a11y.dylib \
                -F$(QT_FW) -framework QtCore -framework QtGui -framework QtWidgets -framework QtQuick -framework QtQml \
                -framework AppKit -framework Foundation -framework Vision -framework CoreGraphics \
                -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,$(QT_FW)

SOURCES      := src/a11y_log.mm src/a11y_diagnostics.mm src/line_introspect.mm src/accessible_widgets.mm src/accessible_list.mm src/qt_signal_utils.mm src/a11y_update_filter.mm src/text_recognition.mm src/call_launch_hook.mm \
                src/a11y_event_filter.mm src/plugin_main.mm
HEADERS      := $(wildcard src/*.h)
OBJECTS      := $(patsubst src/%.mm,$(BUILD)/obj/%.o,$(SOURCES))

.PHONY: all install uninstall test check-load clean check-qt

all: $(DYLIB) $(SHIM) $(AX_INSPECT)

check-qt:
	@test -f "$(QT_FW)/QtCore.framework/Headers/qglobal.h" || \
	  { echo "error: Qt headers not found in $(QT_FW)"; exit 1; }

$(BUILD)/obj/%.o: src/%.mm $(HEADERS) | check-qt
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -x objective-c++ -c $< -o $@

$(DYLIB): $(OBJECTS)
	$(CXX) $(LDFLAGS) $(OBJECTS) -o $@
	codesign -f -s - $@

$(SHIM): src/platform_shim.mm | check-qt
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -x objective-c++ $< -o $@ -arch $(ARCH) -dynamiclib -install_name @rpath/libqcocoa_a11y.dylib \
	  -F$(QT_FW) -framework QtCore -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,$(QT_FW)
	codesign -f -s - $@

$(AX_INSPECT): tools/ax_inspect.swift
	@mkdir -p $(BUILD)
	$(SWIFTC) -O -target $(ARCH)-apple-macos$(MACOS_MIN) $< -o $@

install: $(DYLIB) $(SHIM)
	@mkdir -p "$(INSTALL_DIR)"
	rm -f "$(INSTALLED)"
	cp "$(DYLIB)" "$(INSTALLED)"
	xattr -c "$(INSTALLED)" 2>/dev/null || true
	codesign -f -s - "$(INSTALLED)"
	codesign -v "$(INSTALLED)"
	@mkdir -p "$(CALL_A11Y_DIR)/platformthemes"
	rm -f "$(CALL_INSTALLED)"
	cp "$(DYLIB)" "$(CALL_INSTALLED)"
	xattr -c "$(CALL_INSTALLED)" 2>/dev/null || true
	codesign -f -s - "$(CALL_INSTALLED)"
	@mkdir -p "$(CALL_A11Y_DIR)/platforms"
	rm -f "$(CALL_A11Y_DIR)/platforms/libqcocoa_a11y.dylib"
	cp "$(SHIM)" "$(CALL_A11Y_DIR)/platforms/libqcocoa_a11y.dylib"
	xattr -c "$(CALL_A11Y_DIR)/platforms/libqcocoa_a11y.dylib" 2>/dev/null || true
	codesign -f -s - "$(CALL_A11Y_DIR)/platforms/libqcocoa_a11y.dylib"
	@echo "Installed $(INSTALLED) and $(CALL_INSTALLED)"
	@echo "Launch with: tools/line-a11y-launcher.sh"

uninstall:
	rm -f "$(INSTALLED)" "$(CALL_INSTALLED)" "$(CALL_A11Y_DIR)/platforms/libqcocoa_a11y.dylib"

test: all
	tests/verify_ax_tree.sh

# Loads the installed plugin into a minimal Qt host built against LINE's Qt (does not touch LINE).
$(BUILD)/plugin_load_check: tests/plugin_load_check.mm | check-qt
	@mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -x objective-c++ $< -o $@ -arch $(ARCH) -F$(QT_FW) \
	  -framework QtCore -framework QtGui -framework QtWidgets -Wl,-rpath,$(QT_FW)

check-load: install $(BUILD)/plugin_load_check
	QT_PLUGIN_PATH="$(A11Y_DIR)" QT_QPA_PLATFORM_PLUGIN_PATH="$(LINE_APP)/Contents/PlugIns/platforms" \
	  $(BUILD)/plugin_load_check "$(INSTALLED)"
	@tail -n 8 "$(A11Y_DIR)/a11y.log"

clean:
	rm -rf $(BUILD)
