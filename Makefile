SWIFTC    := xcrun swiftc
FLAGS     := -target $(shell uname -m)-apple-macos14.0 -module-cache-path build/module-cache
TOOLCHAIN := $(shell dirname $$(xcrun -f swiftc 2>/dev/null))/..
DEVELOPER := $(shell xcode-select -p)
TESTING   := $(firstword $(wildcard $(DEVELOPER)/Library/Developer/Frameworks $(DEVELOPER)/Platforms/MacOSX.platform/Developer/Library/Frameworks))

CORE  := $(wildcard Sources/Core/*.swift)
APP   := $(wildcard Sources/App/*.swift)
TESTS := $(wildcard Tests/*.swift)

BUNDLE := build/Blink.app

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
DMG     := build/Blink-$(VERSION).dmg

.PHONY: app dmg test bench install clean

app: $(BUNDLE)

$(BUNDLE): $(CORE) $(APP) Info.plist assets/Blink.icns
	mkdir -p $@/Contents/MacOS $@/Contents/Resources
	cp Info.plist $@/Contents/
	cp assets/Blink.icns $@/Contents/Resources/
	$(SWIFTC) $(FLAGS) -O -module-name Blink $(CORE) $(APP) -o $@/Contents/MacOS/Blink
	codesign --force --sign - $@

dmg: $(DMG)

# For releases: one app for both Apple silicon and Intel Macs, next to a link
# to /Applications to drag it to.
$(DMG): $(CORE) $(APP) Info.plist assets/Blink.icns
	rm -rf build/dmg
	mkdir -p build/dmg/Blink.app/Contents/MacOS build/dmg/Blink.app/Contents/Resources
	cp Info.plist build/dmg/Blink.app/Contents/
	cp assets/Blink.icns build/dmg/Blink.app/Contents/Resources/
	for arch in arm64 x86_64; do \
		$(SWIFTC) -target $$arch-apple-macos14.0 -module-cache-path build/module-cache -O \
			-module-name Blink $(CORE) $(APP) -o build/dmg/Blink-$$arch || exit 1; \
	done
	lipo -create build/dmg/Blink-arm64 build/dmg/Blink-x86_64 -output build/dmg/Blink.app/Contents/MacOS/Blink
	rm build/dmg/Blink-arm64 build/dmg/Blink-x86_64
	codesign --force --sign - build/dmg/Blink.app
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Blink -srcfolder build/dmg -ov -format UDZO $@

test: build/tests
	build/tests

build/tests: $(CORE) $(TESTS)
	mkdir -p build
	$(SWIFTC) $(FLAGS) -parse-as-library -module-name BlinkTests \
		-F $(TESTING) -plugin-path $(TOOLCHAIN)/lib/swift/host/plugins/testing \
		-Xlinker -rpath -Xlinker $(TESTING) -Xlinker -rpath -Xlinker $(TESTING)/../usr/lib -Xlinker -rpath -Xlinker $(TESTING)/../../usr/lib \
		$(CORE) $(TESTS) -o $@

bench: build/bench
	build/bench

build/bench: $(CORE) Sources/App/AppIndex.swift Bench/main.swift
	mkdir -p build
	$(SWIFTC) $(FLAGS) -O -module-name BlinkBench $^ -o $@

install: app
	pkill -x Blink || true
	rm -rf /Applications/Blink.app
	cp -R $(BUNDLE) /Applications/
	open /Applications/Blink.app

clean:
	rm -rf build
