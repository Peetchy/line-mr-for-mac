# LINE.app macOS VoiceOver accessibility bridge

LINE_APP     ?= /Applications/LINE.app
# Qt headers and frameworks to build against: LINE's own (6.6.3), or the official Qt 6.6.3 'lib'
# directory where LINE is not installed (CI: make QT_FW=$QT_ROOT_DIR/lib). Both give the same imports.
QT_FW        ?= $(LINE_APP)/Contents/Frameworks
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

# Distribution: LINE MR.app (opens LINE with the bridge), an installer package and a disk image.
VERSION      ?= 0.1.1
APP_ID       := io.github.peetchy.line-mr
APP_NAME     := LINE MR
APP_BUNDLE   := $(BUILD)/$(APP_NAME).app
APP_STAMP    := $(BUILD)/app.stamp
PKG          := $(BUILD)/LINE-MR-$(VERSION).pkg
DMG          := $(BUILD)/LINE-MR-$(VERSION).dmg

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
                -framework AppKit -framework Foundation -framework Vision -framework CoreGraphics -framework Carbon \
                -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,$(QT_FW)

SOURCES      := src/a11y_log.mm src/a11y_diagnostics.mm src/line_introspect.mm src/accessible_widgets.mm src/accessible_list.mm src/qt_signal_utils.mm src/a11y_update_filter.mm src/text_recognition.mm src/call_launch_hook.mm \
                src/text_capture.mm src/a11y_announce.mm src/accessible_quick.mm src/full_text_view.mm src/call_keys.mm src/native_buttons.mm src/navigation_order.mm \
                src/a11y_event_filter.mm src/plugin_main.mm
HEADERS      := $(wildcard src/*.h)
OBJECTS      := $(patsubst src/%.mm,$(BUILD)/obj/%.o,$(SOURCES))

.PHONY: all install uninstall test check-load clean check-qt app pkg dmg dist

all: $(DYLIB) $(SHIM) $(AX_INSPECT)

check-qt:
	@test -f "$(QT_FW)/QtCore.framework/Headers/qglobal.h" || \
	  { echo "error: Qt headers not found in $(QT_FW) (install LINE, or pass QT_FW=<Qt 6.6.3>/lib)"; exit 1; }

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

app: $(APP_STAMP)

# The bundle's name has a space, which make targets cannot have: a stamp file stands for it.
$(APP_STAMP): packaging/LineMR.swift packaging/Info.plist.in $(DYLIB)
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	$(SWIFTC) -O -swift-version 5 -target $(ARCH)-apple-macos$(MACOS_MIN) packaging/LineMR.swift \
	  -o "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	sed -e 's/@VERSION@/$(VERSION)/g' -e 's/@APP_ID@/$(APP_ID)/g' packaging/Info.plist.in > "$(APP_BUNDLE)/Contents/Info.plist"
	cp $(DYLIB) "$(APP_BUNDLE)/Contents/Resources/"
	codesign -f -s - "$(APP_BUNDLE)/Contents/Resources/libline_a11y.dylib"
	codesign -f -s - --identifier $(APP_ID) "$(APP_BUNDLE)"
	codesign -v --strict "$(APP_BUNDLE)"
	touch $@

pkg: $(PKG)

$(PKG): $(APP_STAMP) packaging/pkg/distribution.xml packaging/pkg/components.plist $(wildcard packaging/pkg/resources/*/*)
	rm -rf $(BUILD)/pkgroot $(BUILD)/pkgparts
	mkdir -p $(BUILD)/pkgroot/Applications $(BUILD)/pkgparts
	ditto --norsrc --noextattr --noqtn "$(APP_BUNDLE)" "$(BUILD)/pkgroot/Applications/$(APP_NAME).app"
	pkgbuild --root $(BUILD)/pkgroot --component-plist packaging/pkg/components.plist --identifier $(APP_ID) \
	  --version $(VERSION) --install-location / $(BUILD)/pkgparts/line-mr.pkg
	productbuild --distribution packaging/pkg/distribution.xml --resources packaging/pkg/resources \
	  --package-path $(BUILD)/pkgparts $@

dmg: $(DMG)

$(DMG): $(APP_STAMP) $(PKG) packaging/INSTALL.txt
	rm -rf $(BUILD)/dmg $@
	mkdir -p $(BUILD)/dmg
	ditto --norsrc --noextattr --noqtn "$(APP_BUNDLE)" "$(BUILD)/dmg/$(APP_NAME).app"
	cp $(PKG) "$(BUILD)/dmg/Install $(APP_NAME).pkg"
	cp packaging/INSTALL.txt "$(BUILD)/dmg/อ่านก่อนติดตั้ง - Read Me.txt"
	ln -s /Applications $(BUILD)/dmg/Applications
	# hdiutil sometimes fails with "Resource busy" on CI machines: retry.
	for i in 1 2 3 4 5; do hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder $(BUILD)/dmg -format UDZO -ov $@ && break; sleep 5; done
	test -f $@

dist: $(DMG) $(PKG)
	@echo "Built $(DMG) and $(PKG)"

clean:
	rm -rf $(BUILD)
