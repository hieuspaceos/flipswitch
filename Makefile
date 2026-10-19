APP      := flipswitch
BUILD    := Build
BUNDLE   := $(BUILD)/$(APP).app
SRC      := $(wildcard Sources/*.swift)
SDK      := $(shell xcrun --show-sdk-path)
TARGET   := arm64-apple-macosx14.0

.PHONY: all clean run

all: $(BUNDLE)

$(BUNDLE): $(SRC) Info.plist
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	swiftc -O -swift-version 5 \
		-sdk "$(SDK)" -target "$(TARGET)" \
		-module-name $(APP) \
		$(SRC) \
		-o "$(BUNDLE)/Contents/MacOS/$(APP)"
	cp Info.plist "$(BUNDLE)/Contents/Info.plist"
	@mkdir -p "$(BUNDLE)/Contents/Resources" "$(BUILD)/AppIcon.iconset"
	swift tools/make_icon.swift "$(BUILD)/AppIcon.iconset" >/dev/null
	iconutil -c icns "$(BUILD)/AppIcon.iconset" -o "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	@echo "Built $(BUNDLE)"

run: $(BUNDLE)
	open "$(BUNDLE)"

clean:
	rm -rf "$(BUILD)"
