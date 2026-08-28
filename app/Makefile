# Wakelock メニューバーアプリ
# Xcode は不要。Command Line Tools の swiftc だけでビルドできる。

APP      := Wakelock
BUILD    := build
BUNDLE   := $(BUILD)/$(APP).app
MACOS    := $(BUNDLE)/Contents/MacOS
SOURCES  := $(wildcard Sources/*.swift)
TARGET   := arm64-apple-macos13.0

.PHONY: all run install uninstall test clean

all: $(BUNDLE)

$(BUNDLE): $(SOURCES) Info.plist
	@mkdir -p $(MACOS)
	@cp Info.plist $(BUNDLE)/Contents/Info.plist
	swiftc -O -parse-as-library -swift-version 5 -target $(TARGET) \
		$(SOURCES) -o $(MACOS)/$(APP)
	@codesign --force --sign - $(BUNDLE) >/dev/null 2>&1 || true
	@echo "ビルド完了: $(BUNDLE)"

run: $(BUNDLE)
	@pkill -x $(APP) 2>/dev/null || true
	open $(BUNDLE)

install: $(BUNDLE)
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	@echo "/Applications/$(APP).app に配置しました"

uninstall:
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(APP).app

# wakelock status --json の実際の形をデコードできるか検証する
test:
	@mkdir -p $(BUILD)
	@swiftc -parse-as-library -swift-version 5 -target $(TARGET) \
		Sources/Model.swift Tests/DecodeTest.swift -o $(BUILD)/decodetest
	@$(BUILD)/decodetest

clean:
	rm -rf $(BUILD)
