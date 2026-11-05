APP := Chord
DERIVED := .build
PRODUCT := $(DERIVED)/Build/Products/Debug/$(APP).app

.PHONY: generate build run test logs clean

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

clean:
	rm -rf $(DERIVED) Packages/chord_logic/.build $(APP).xcodeproj
