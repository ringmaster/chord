APP := Chord
DERIVED := .build
PRODUCT := $(DERIVED)/Build/Products/Debug/$(APP).app

# The release build, which is what goes to a Mac other than this one.
RELEASE_APP := $(DERIVED)/Build/Products/Release/$(APP).app
RELEASE_ZIP := $(DERIVED)/$(APP).zip
# The notarization credentials in the login keychain. They belong to the team,
# not to one app, so Chord uses the profile Tacks stored them under.
NOTARY_PROFILE := tacks-notary

.PHONY: generate build run test logs clean icon land release notarize verify-release

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

# Rebase this feature branch onto main, build and test it, then fast-forward
# main and build the main checkout. See tools/land.sh.
land:
	tools/land.sh

logs:
	log stream --level info --predicate 'subsystem == "net.asymptomatic.Chord"'

# Build the copy that goes to another Mac: Developer ID, hardened runtime, and
# a secure timestamp on the signature.
release: generate
	@# The generic destination builds for both Apple silicon and Intel. Without
	@# it xcodebuild builds only for the kind of Mac that is building.
	xcodebuild -scheme $(APP) -configuration Release -derivedDataPath $(DERIVED) \
		-destination 'generic/platform=macOS' build
	codesign --verify --strict --verbose=1 $(RELEASE_APP)
	@echo "Architectures: `lipo -archs $(RELEASE_APP)/Contents/MacOS/$(APP)`"

# Send the release build to Apple, wait for the answer, and attach the ticket to
# the application so it opens on a Mac that has never seen it and is offline.
notarize: release
	rm -f $(RELEASE_ZIP)
	ditto -c -k --keepParent $(RELEASE_APP) $(RELEASE_ZIP)
	xcrun notarytool submit $(RELEASE_ZIP) --keychain-profile $(NOTARY_PROFILE) \
		--wait --output-format json > $(DERIVED)/notarization.json
	@cat $(DERIVED)/notarization.json
	@# notarytool exits with zero whether Apple accepted or refused the build,
	@# so the status is read here before stapling.
	@status=$$(plutil -extract status raw -o - $(DERIVED)/notarization.json); \
	if [ "$$status" != "Accepted" ]; then \
		echo ""; \
		echo "Apple refused this build. What it objected to:"; \
		xcrun notarytool log \
			$$(plutil -extract id raw -o - $(DERIVED)/notarization.json) \
			--keychain-profile $(NOTARY_PROFILE); \
		exit 1; \
	fi
	xcrun stapler staple $(RELEASE_APP)
	rm -f $(RELEASE_ZIP)
	ditto -c -k --keepParent $(RELEASE_APP) $(RELEASE_ZIP)
	@echo "Ready to hand over: $(RELEASE_ZIP)"

# What another Mac's Gatekeeper will decide, asked here instead of there.
verify-release:
	codesign --verify --deep --strict --verbose=2 $(RELEASE_APP)
	spctl --assess --type execute --verbose=2 $(RELEASE_APP)
	xcrun stapler validate $(RELEASE_APP)

# Draw the application icon. The result is committed, so this only needs
# running when tools/make-icon or its artwork.png changes.
icon:
	mkdir -p $(DERIVED)
	swiftc -O -o $(DERIVED)/make-icon tools/make-icon/main.swift
	rm -rf $(DERIVED)/AppIcon.iconset
	$(DERIVED)/make-icon tools/make-icon/artwork.png $(DERIVED)/AppIcon.iconset
	iconutil -c icns -o App/Resources/AppIcon.icns $(DERIVED)/AppIcon.iconset

clean:
	rm -rf $(DERIVED) Packages/chord_logic/.build $(APP).xcodeproj
