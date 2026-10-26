SWIFTC    := xcrun swiftc
FLAGS     := -target $(shell uname -m)-apple-macos14.0 -module-cache-path build/module-cache
TOOLCHAIN := $(shell dirname $$(xcrun -f swiftc 2>/dev/null))/..
DEVELOPER := $(shell xcode-select -p)
TESTING   := $(firstword $(wildcard $(DEVELOPER)/Library/Developer/Frameworks $(DEVELOPER)/Platforms/MacOSX.platform/Developer/Library/Frameworks))

CORE  := $(wildcard Sources/Core/*.swift)
APP   := $(wildcard Sources/App/*.swift)
TESTS := $(wildcard Tests/*.swift)

BUNDLE := build/Blink.app

.PHONY: app test bench install clean

app: $(BUNDLE)

$(BUNDLE): $(CORE) $(APP) Info.plist
	mkdir -p $@/Contents/MacOS
	cp Info.plist $@/Contents/
	$(SWIFTC) $(FLAGS) -O -module-name Blink $(CORE) $(APP) -o $@/Contents/MacOS/Blink
	codesign --force --sign - $@

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
