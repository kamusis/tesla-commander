.PHONY: all build release run app clean

APP_NAME = TeslaCommander
BUNDLE_DIR = $(APP_NAME).app
CONTENTS_DIR = $(BUNDLE_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources
VERSION = 2.0
BUILD_DATE = $(shell date +%Y%m%d)

all: build

build:
	swift build

release:
	swift build -c release

run:
	swift run

app: release
	@echo "Creating $(BUNDLE_DIR)..."
	@rm -rf $(BUNDLE_DIR)
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp .build/release/$(APP_NAME) $(MACOS_DIR)/$(APP_NAME)
	@cp Sources/Resources/tesla_dashboard.html $(RESOURCES_DIR)/tesla_dashboard.html
	@cp Sources/Resources/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	@echo '<?xml version="1.0" encoding="UTF-8"?>\
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\
<plist version="1.0">\
<dict>\
    <key>CFBundleExecutable</key>\
    <string>$(APP_NAME)</string>\
    <key>CFBundleIconFile</key>\
    <string>AppIcon</string>\
    <key>CFBundleIdentifier</key>\
    <string>com.enmotech.tesla-commander</string>\
    <key>CFBundleName</key>\
    <string>Tesla Commander</string>\
    <key>CFBundlePackageType</key>\
    <string>APPL</string>\
    <key>CFBundleShortVersionString</key>\
    <string>$(VERSION)</string>\
    <key>CFBundleVersion</key>\
    <string>$(BUILD_DATE)</string>\
    <key>LSMinimumSystemVersion</key>\
    <string>13.0</string>\
    <key>NSHighResolutionCapable</key>\
    <true/>\
</dict>\
</plist>' > $(CONTENTS_DIR)/Info.plist
	@codesign --force --deep --sign - $(BUNDLE_DIR)
	@echo "Application bundle created and signed at $(BUNDLE_DIR)"

clean:
	swift package clean
	rm -rf $(BUNDLE_DIR)
