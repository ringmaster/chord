APP := Chord
DERIVED := .build
PRODUCT := $(DERIVED)/Build/Products/Debug/$(APP).app

.PHONY: generate build run test logs clean icon

# Regenerate the Xcode project from project.yml. Run after any change to it.
generate:
	xcodegen generate

build: generate
	xcodebuild -scheme $(APP) -configuration Debug -derivedDataPath $(DERIVED) build

run: build
	open $(PRODUCT)

# Tests cover chord_logic. The application shell has no headless tests.
test:
	swift test --package-path Packages/chord_logic

logs:
	log stream --level info --predicate 'subsystem == "net.asymptomatic.Chord"'

# Draw the application icon. The result is committed, so this only needs
# running when the drawing in tools/make-icon changes.
icon:
	mkdir -p $(DERIVED)
	swiftc -O -o $(DERIVED)/make-icon tools/make-icon/main.swift
	rm -rf $(DERIVED)/AppIcon.iconset
	$(DERIVED)/make-icon $(DERIVED)/AppIcon.iconset
	iconutil -c icns -o App/Resources/AppIcon.icns $(DERIVED)/AppIcon.iconset

clean:
	rm -rf $(DERIVED) Packages/chord_logic/.build $(APP).xcodeproj
