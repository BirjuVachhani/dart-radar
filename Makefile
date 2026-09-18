# Makefile for the Dart Radar macOS app (Developer ID, signed + notarized).
#
# Direct distribution (.app / .dmg) uses a "Developer ID Application"
# certificate plus notarization, NOT the App Store certificate (which produces
# a .pkg for App Store Connect, a separate channel that is out of scope here).
#
# One-time setup:
#   cp config.mk.example config.mk    Fill in your signing credentials
#   make prepare                      Build keychain + certs from ./secrets
#
# Builds:
#   make app                          Signed .app -> ./artifacts/Dart Radar.app
#   make install                      Signed .app -> /Applications
#   make dmg                          Signed + notarized + stapled .dmg (and .app)
#
# Release:
#   make release                      Build the DMG and upload it to R2
#
# Options:
#   VERSION=1.2.3                     Override version (default: project.yml)
#   BUILD_NUMBER=42                   Override build number (default: project.yml)
#   SKIP_NOTARIZE=1                   Sign, but skip both notarization passes
#
# Maintenance:
#   make ensure-keychain              Re-add the build keychain to the search
#                                     list if another project clobbered it
#   make cleanup                      Remove build keychain and artifacts

.PHONY: help prepare setup-keychain ensure-keychain unlock-keychain install-cert \
        grant-access teardown-keychain store-notary generate build-app stage-app sign-app app \
        staple-app install dmg notarize appcast release release-preflight github-release \
        upload-r2 \
        upload-appcast cleanup

# -------------------------------- Local Configuration --------------------------------

# Passwords and the Apple ID live in config.mk, which is gitignored. Included
# first, and every variable below is `?=`, so config.mk (and the environment,
# which beats both) can override any of them.
#
# `-include` rather than `include`: the file is legitimately absent on a fresh
# clone, and the targets that actually need a credential say so themselves
# through `guard-%` rather than failing the whole Makefile at parse time.
-include config.mk

# -------------------------------- Apple Configuration --------------------------------

# Not a secret: the team id is embedded in every signed binary.
TEAM_ID						?= TQ37FM6DBD

# Release bundle id. macOS 26 permanently poisons a bundle id's menu-bar-item
# placement once two apps with that id run at once, and this app ships a
# MenuBarExtra, so this MUST stay unique and stable. It is also spelled out in
# project.yml (PRODUCT_BUNDLE_IDENTIFIER); build-app checks the two agree.
BUNDLE_ID					?= dev.birju.dartradar

# Codesign identity used for direct (.app/.dmg) distribution. Resolved out of
# the build keychain when that keychain holds it, and out of the keychain
# search list otherwise (see SET_SIGN_KEYCHAIN).
DEVID_APP_IDENTITY			?= Developer ID Application: Birju Vachhani ($(TEAM_ID))

# APPLE_EMAIL and APP_SPECIFIC_PASSWORD come from config.mk. Deliberately no
# default: they are a live Apple ID credential pair, and a placeholder here
# would only surface as an opaque notarytool auth error much later on.

# -------------------------------- Project Layout --------------------------------

# The user-visible bundle name, so the product is "Dart Radar.app". It has a
# space in it, so every recipe below quotes any path built from it.
APP_NAME					:= Dart Radar
# Space-free slug for everything a machine reads: the Xcode project, scheme and
# target (all named DartRadar in project.yml), and the DMG filename, which ends
# up in a download URL where a space would arrive percent-encoded.
PRODUCT_SLUG				:= DartRadar
PROJECT						:= $(PRODUCT_SLUG).xcodeproj
SCHEME						:= $(PRODUCT_SLUG)
PROJECT_SPEC				:= project.yml
BUILD_CONFIG				:= Release

# Xcode writes here; `make cleanup` and .gitignore both assume it.
DERIVED_DATA				:= build
BUILD_PRODUCTS				 = $(DERIVED_DATA)/Build/Products/$(BUILD_CONFIG)
APP_BUNDLE					 = $(BUILD_PRODUCTS)/$(APP_NAME).app

ARTIFACTS_DIR				:= artifacts
ARTIFACT_APP				 = $(ARTIFACTS_DIR)/$(APP_NAME).app
# Kept versioned locally so successive builds do not overwrite each other. The
# object uploaded to R2 is deliberately NOT versioned; see R2_KEY.
DMG							 = $(ARTIFACTS_DIR)/$(PRODUCT_SLUG)-$(VERSION).dmg
# Intermediate archive for the app's own notarization pass: notarytool takes a
# file and a .app is a directory. Deleted as soon as its ticket is stapled.
APP_ZIP						 = $(ARTIFACTS_DIR)/$(PRODUCT_SLUG)-app.zip

# -------------------------------- Signing Configuration --------------------------------

# The one certificate this pipeline signs with. Direct distribution needs only
# "Developer ID Application": the App Store certificate belongs to the .pkg
# channel that is out of scope here, and "Developer ID Installer" signs .pkg
# installers, which this project does not ship.
#
# ./secrets holds the exported private key and is gitignored. A missing .p12 is
# fine as long as the identity is reachable from the login keychain.
DEVID_CERT_PATH				?= ./secrets/Developer ID Application.p12

KEYCHAIN_NAME				?= dart-radar-build.keychain
KEYCHAIN_PATH				 = $(HOME)/Library/Keychains/$(KEYCHAIN_NAME)-db

# NOTE: no provisioning profile. macOS requires an embedded
# .provisionprofile only when a bundle claims a *restricted* entitlement
# (keychain-access-groups, App Groups, anything com.apple.developer.*). AMFI
# then kills the app at launch unless a profile authorizes both the entitlement
# and the signing certificate. Dart Radar claims no entitlements at all: it
# shells out to /bin/ps and reads its own task info, neither of which is gated.
# Hardened runtime on its own needs no profile. If an entitlement is ever added,
# issue a Developer ID profile, drop it at Contents/embedded.provisionprofile
# BEFORE signing (so the signature seals it), and pass --entitlements here.

# Shell prelude for every recipe that runs codesign. Sets the positional
# parameters to `--keychain <build keychain>` when that keychain holds
# $(DEVID_APP_IDENTITY), or to nothing when it does not, and unlocks the
# keychain if a password is available. Recipes then splice "$$@" into each
# codesign call.
#
# Why the lookup has to be scoped: codesign resolves an identity by display
# name across the ENTIRE per-user keychain search list, and that list is global
# state any other project on this Mac can rewrite. Every keychain holding a
# same-named copy of this certificate is a candidate (../moxie keeps one),
# so a locked keychain belonging to an unrelated project makes macOS prompt for
# a password this project does not have, and the build stalls on a dialog.
# Duplicate copies of one certificate share its SHA-1, so signing by hash does
# NOT disambiguate; --keychain is the documented way to break this tie. The
# certificate chain is still assembled from the full search list, which reads
# public certificates only and therefore cannot prompt.
#
# The empty fallback keeps `make app` and `make install` working on a fresh
# clone with no config.mk and no ./secrets: with no build keychain to scope to,
# signing comes from the login keychain as before.
SET_SIGN_KEYCHAIN			 = \
    if security find-identity -v -p codesigning "$(KEYCHAIN_PATH)" 2>/dev/null \
       | grep -qF "$(DEVID_APP_IDENTITY)"; then \
        set -- --keychain "$(KEYCHAIN_PATH)"; \
        SIGN_SOURCE="$(KEYCHAIN_NAME)"; \
        test -z "$(KEYCHAIN_PASSWORD)" || \
            security unlock-keychain -p "$(KEYCHAIN_PASSWORD)" "$(KEYCHAIN_PATH)"; \
    else \
        set --; \
        SIGN_SOURCE="the keychain search list"; \
    fi

# -------------------------------- Sparkle (auto-update) --------------------------------

# Sparkle.framework arrives through the SPM package declared in project.yml and
# is embedded by the Xcode build. It ships ADHOC signed, and so do the four
# pieces of code nested inside it. Notarization rejects any of those, so
# sign-app re-signs all five with the Developer ID identity. See
# SIGN_SPARKLE_HELPERS below.
SPARKLE_FRAMEWORK			 = $(ARTIFACT_APP)/Contents/Frameworks/Sparkle.framework

# Sparkle's own tools, from the resolved SPM binary artifact. They live under
# the derived data directory, so they exist once any build has run and are
# removed by `make cleanup`; appcast says so rather than failing on a bare
# "no such file".
SPARKLE_BIN					:= $(DERIVED_DATA)/SourcePackages/artifacts/sparkle/Sparkle/bin
SPARKLE_SIGN_UPDATE			 = $(SPARKLE_BIN)/sign_update

# The Ed25519 private key every release is signed with. Its public half is
# SUPublicEDKey in DartRadar/Info.plist, and Sparkle refuses an update whose
# signature does not verify against that key, so this file is the only thing
# that can produce an update any installed copy will accept. It is not a
# certificate and has no password; keep the file safe (./secrets is gitignored)
# and keep a backup, because losing it strands every install.
#
# This is the same key ../moxie signs with, which is deliberate: Sparkle's own
# generate_keys states one signing key covers however many apps you embed it in.
SPARKLE_PRIVATE_KEY			?= ./secrets/sparkle_ed25519_private_key

# Where the published feed and the DMG it points at are served from. The app has
# the feed URL compiled in (SUFeedURL in DartRadar/Info.plist) and every
# already-installed copy is pinned to exactly this address, so it cannot be
# reconfigured per build without stranding them. Keep it in step with that key,
# and with R2_FOLDER, which decides where `make release` actually writes.
APPCAST_URL					:= https://artifacts.birju.dev/dartradar/appcast.xml
APPCAST						 = $(ARTIFACTS_DIR)/appcast.xml

# Feed item's sparkle:minimumSystemVersion, used only when `make appcast` runs
# with no build product to read LSMinimumSystemVersion off. Keep in step with
# the macOS deploymentTarget in project.yml.
MIN_MACOS					?= 14.0

# Re-sign the code nested inside Sparkle.framework, innermost first, in the
# order Sparkle's own documentation prescribes; the framework wrapper itself is
# then picked up by the generic Frameworks sweep in sign-app, which runs after
# this and therefore seals the new signatures in.
#
# Downloader.xpc is the one exception that carries entitlements of its own (it
# is the sandboxed half of Sparkle's downloader), so its signature is renewed
# with --preserve-metadata=entitlements. The rest get a plain hardened-runtime
# signature. Deliberately NOT `codesign --deep`: Sparkle warns that it applies
# one binary's entitlements to all of them, a common source of sandbox failures.
#
# Every path is required. A future Sparkle that moved or dropped one would
# otherwise leave an adhoc-signed binary in the bundle, which passes codesign
# --verify locally and is then rejected by the notary service ten minutes into a
# release. A missing path fails the build here instead.
#
# Expects the caller to have run SET_SIGN_KEYCHAIN, whose positional parameters
# ("$$@") carry the --keychain scoping.
SIGN_SPARKLE_HELPERS		 = \
    if [ -d "$(SPARKLE_FRAMEWORK)" ]; then \
        HELPERS="$$(cd "$(SPARKLE_FRAMEWORK)/Versions/Current" && pwd -P)"; \
        echo "Re-signing Sparkle's nested helpers in $$HELPERS ..."; \
        for helper in XPCServices/Downloader.xpc XPCServices/Installer.xpc \
                      Updater.app Autoupdate; do \
            test -e "$$HELPERS/$$helper" || { \
                echo "ERROR: Sparkle has no $$helper."; \
                echo "       Sparkle ships its nested code adhoc-signed, so every piece has to"; \
                echo "       be re-signed with the Developer ID identity or the notary service"; \
                echo "       rejects the DMG. This list has gone stale against the Sparkle"; \
                echo "       version resolved by SPM. Update SIGN_SPARKLE_HELPERS to match."; \
                exit 1; }; \
            if [ "$$helper" = "XPCServices/Downloader.xpc" ]; then \
                codesign --force --options runtime --timestamp "$$@" \
                    --preserve-metadata=entitlements \
                    --sign "$(DEVID_APP_IDENTITY)" "$$HELPERS/$$helper"; \
            else \
                codesign --force --options runtime --timestamp "$$@" \
                    --sign "$(DEVID_APP_IDENTITY)" "$$HELPERS/$$helper"; \
            fi; \
        done; \
    fi

# -------------------------------- Notarization --------------------------------

# notarytool credential profile stored inside the same build keychain as the
# signing cert (see store-notary). notarize submits against this profile
# instead of passing the app-specific password on every run.
NOTARY_PROFILE				:= dart-radar-notary

# -------------------------------- Version --------------------------------

# project.yml is the single source of truth, so a release bump is one edit
# there. Read with sed rather than a YAML parser to keep this dependency-free.
VERSION						?= $(shell sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$$/\1/p' $(PROJECT_SPEC) | head -1)
BUILD_NUMBER				?= $(shell sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$$/\1/p' $(PROJECT_SPEC) | head -1)

# ================================ Help ================================

help:
	@echo "Dart Radar build targets:"
	@echo "  make prepare              Create build keychain + import cert from ./secrets"
	@echo "  make app                  Signed .app -> $(ARTIFACTS_DIR)"
	@echo "  make install              Signed .app -> /Applications"
	@echo "  make dmg                  Notarized + stapled .app and .dmg -> $(ARTIFACTS_DIR)"
	@echo "  make release              DMG + appcast -> R2, then a GitHub release"
	@echo "  make release FORCE=1      Re-cut a version already released (updates it in place)"
	@echo "  make appcast              Sign the built .dmg and write $(APPCAST)"
	@echo "  make ensure-keychain      Re-add the build keychain to the search list"
	@echo "  make cleanup              Remove build keychain and artifacts"
	@echo ""
	@echo "Current version: $(VERSION) ($(BUILD_NUMBER))"

# ================================ Config Guard ================================

# Prerequisite that fails with a specific, actionable message when a credential
# only config.mk can supply is missing, instead of letting `security`,
# notarytool or the R2 upload fail several steps later with an empty password.
#
# Used as `some-target: guard-CERT_PASSWORD`; the stem names the variable and
# `$($*)` reads it.
guard-%:
	@test -n "$($*)" || { \
		echo "ERROR: $* is not set."; \
		echo ""; \
		echo "  Credentials are kept out of this repository. Create config.mk:"; \
		echo ""; \
		echo "      cp config.mk.example config.mk"; \
		echo ""; \
		echo "  then fill in $*. config.mk is gitignored: do not commit it."; \
		exit 1; }

# ================================ Keychain & Signing Setup ================================

setup-keychain: guard-KEYCHAIN_PASSWORD
	@echo "Setting up keychain..."
	security delete-keychain "$(KEYCHAIN_NAME)" 2>/dev/null || true
	security create-keychain -p "$(KEYCHAIN_PASSWORD)" "$(KEYCHAIN_NAME)"
	security unlock-keychain -p "$(KEYCHAIN_PASSWORD)" "$(KEYCHAIN_NAME)"
	security set-keychain-settings -lut 21600 "$(KEYCHAIN_PATH)"
	$(MAKE) ensure-keychain

# Put the build keychain on the per-user search list, idempotently, leaving
# every other entry untouched. Also the repair target to run by hand if the
# list has been clobbered: it never deletes or recreates the keychain, so the
# certificate and the notarytool profile inside it survive.
#
# `security list-keychains -s` REPLACES the whole list, and that list is global
# per-user state shared with every other project on this Mac (../moxie has its
# own build keychain on it). Read the list and append rather than setting it to
# exactly [build, login], which would silently evict the others.
ensure-keychain:
	@test -f "$(KEYCHAIN_PATH)" || { \
		echo "ERROR: no build keychain at $(KEYCHAIN_PATH)."; \
		echo "       Run 'make prepare' to create it."; \
		exit 1; }
	@if security list-keychains -d user | grep -qF '"$(KEYCHAIN_PATH)"'; then \
		echo "$(KEYCHAIN_NAME) is already on the keychain search list."; \
	else \
		echo "Adding $(KEYCHAIN_NAME) to the keychain search list..."; \
		{ security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$$//'; \
		  echo "$(KEYCHAIN_PATH)"; } \
		| tr '\n' '\0' | xargs -0 security list-keychains -d user -s; \
	fi

# Unlock the build keychain (it can auto-lock between sessions). Safe no-op if
# the keychain does not exist yet.
unlock-keychain: guard-KEYCHAIN_PASSWORD
	@security unlock-keychain -p "$(KEYCHAIN_PASSWORD)" "$(KEYCHAIN_PATH)" 2>/dev/null || true

install-cert: guard-CERT_PASSWORD setup-keychain
	@echo "Importing the signing certificate from ./secrets ..."
	@if [ -f "$(DEVID_CERT_PATH)" ]; then \
		echo "  Developer ID cert: $(DEVID_CERT_PATH)"; \
		security import "$(DEVID_CERT_PATH)" -k "$(KEYCHAIN_PATH)" -P "$(CERT_PASSWORD)" -T /usr/bin/codesign -T /usr/bin/security -A; \
	else \
		echo "  (Developer ID cert not found at $(DEVID_CERT_PATH), relying on the login keychain for '$(DEVID_APP_IDENTITY)')"; \
	fi
	$(MAKE) grant-access
	@echo "Developer ID signing identities in $(KEYCHAIN_NAME):"
	@security find-identity -v -p codesigning "$(KEYCHAIN_PATH)" | grep "Developer ID Application" || { \
		echo "  none in the build keychain, so signing falls back to the search list."; \
		echo "  That works only while '$(DEVID_APP_IDENTITY)' is in your login keychain,"; \
		echo "  and it leaves the build exposed to same-named copies in other projects'"; \
		echo "  keychains. Put $(DEVID_CERT_PATH) in place and re-run to scope it."; }

grant-access: guard-KEYCHAIN_PASSWORD
	security set-key-partition-list \
		-S apple-tool:,codesign:,apple: \
		-k "$(KEYCHAIN_PASSWORD)" \
		"$(KEYCHAIN_PATH)"

# Delete the build keychain and drop only its own entry from the search list.
# delete-keychain already prunes the entry; the explicit pass also cleans up a
# stale entry left behind when the file is already gone.
teardown-keychain:
	@echo "Removing keychain $(KEYCHAIN_NAME)..."
	security delete-keychain "$(KEYCHAIN_NAME)" 2>/dev/null || true
	@REMAINING=$$(security list-keychains -d user \
		| sed -e 's/^[[:space:]]*"//' -e 's/"$$//' \
		| grep -vxF "$(KEYCHAIN_PATH)" || true); \
	if [ -n "$$REMAINING" ]; then \
		printf '%s\n' "$$REMAINING" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s; \
	fi

# ================================ One-time Setup ================================

prepare:
	$(MAKE) install-cert
	$(MAKE) store-notary
	@echo ""
	@echo "Certificate + notarization profile ready in $(KEYCHAIN_NAME)."
	@echo "Done."

# Store notarization credentials as a profile inside the build keychain (the
# same one that holds the signing cert). Idempotent, safe to re-run.
store-notary: guard-APPLE_EMAIL guard-APP_SPECIFIC_PASSWORD unlock-keychain
	@echo "Storing notarization profile '$(NOTARY_PROFILE)' in $(KEYCHAIN_NAME)..."
	xcrun notarytool store-credentials "$(NOTARY_PROFILE)" \
		--apple-id "$(APPLE_EMAIL)" \
		--team-id "$(TEAM_ID)" \
		--password "$(APP_SPECIFIC_PASSWORD)" \
		--keychain "$(KEYCHAIN_PATH)"

# ================================ Build ================================

# Regenerate the .xcodeproj from project.yml. The project file is derived, so
# any edit made in Xcode's UI is lost here. Change project.yml instead.
generate:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "ERROR: xcodegen is not installed."; \
		echo "           brew install xcodegen"; \
		exit 1; }
	xcodegen generate --spec "$(PROJECT_SPEC)"

# Builds the release .app. project.yml signs ad-hoc (CODE_SIGN_IDENTITY "-"),
# and sign-app re-signs with the Developer ID identity afterwards, so this
# intermediate bundle is not the one that ships.
build-app: generate
	@echo "Building $(APP_NAME).app $(VERSION) ($(BUILD_NUMBER)) ($(BUILD_CONFIG))..."
	mkdir -p "$(ARTIFACTS_DIR)"
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-configuration "$(BUILD_CONFIG)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		MARKETING_VERSION="$(VERSION)" \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" \
		build
	@test -d "$(APP_BUNDLE)" || { echo "ERROR: build output not found at $(APP_BUNDLE)"; exit 1; }
	@BID=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$(APP_BUNDLE)/Contents/Info.plist"); \
	if [ "$$BID" != "$(BUNDLE_ID)" ]; then \
		echo "ERROR: built bundle id '$$BID' != expected '$(BUNDLE_ID)'."; \
		echo "       PRODUCT_BUNDLE_IDENTIFIER in $(PROJECT_SPEC) has drifted from BUNDLE_ID"; \
		echo "       here. Shipping a mismatched id would clash on users' Macs."; \
		exit 1; \
	fi; \
	echo "Verified bundle id: $$BID"
	@# The icon is an Icon Composer document compiled by actool. A .icon that
	@# failed to compile, or was dropped from the Resources build phase, leaves
	@# a bundle that builds and signs cleanly and simply shows the generic app
	@# icon in Finder. Caught here rather than after notarization.
	@test -f "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns" || { \
		echo "ERROR: no compiled app icon in the bundle."; \
		echo "       AppIcon.icon should be in the Resources build phase and named by"; \
		echo "       ASSETCATALOG_COMPILER_APPICON_NAME. Check both in $(PROJECT_SPEC)."; \
		exit 1; }

# Copy the build product into $(ARTIFACTS_DIR), and sign THAT rather than
# signing the build product where Xcode left it.
#
# Launching a bundle makes macOS attach com.apple.provenance and com.apple.macl
# to it. Both are SIP-protected: they survive `xattr -cr`, and they make a later
# `codesign --force` on that same bundle fail with a bare "Operation not
# permitted". Xcode's Run button launches exactly $(APP_BUNDLE), so signing in
# place means the next `make app` breaks for anyone who has run the app from
# Xcode, with an error that names no cause. ditto's --noextattr / --norsrc /
# --noqtn drop those attributes on the way across, and the rm -rf keeps the
# staged copy from accumulating them itself.
stage-app: build-app
	@test -d "$(APP_BUNDLE)" || { echo "ERROR: no build product at $(APP_BUNDLE)."; exit 1; }
	mkdir -p "$(ARTIFACTS_DIR)"
	rm -rf "$(ARTIFACT_APP)"
	ditto --noextattr --norsrc --noqtn "$(APP_BUNDLE)" "$(ARTIFACT_APP)"

# Re-sign the staged .app with the Developer ID identity + hardened runtime +
# secure timestamp, inside-out (nested frameworks/dylibs first, then the bundle).
#
# No --entitlements: the app claims none, and passing an empty plist would only
# add a signature blob with nothing in it. No embedded provisioning profile
# either. See the NOTE above DEVID_CERT_PATH for when that changes.
#
# Deliberately NOT `codesign --deep`, which applies one binary's entitlements to
# every nested binary and is a common source of signing failures. The bundle
# currently has no nested code at all; the Frameworks sweep is there so adding a
# dependency later does not silently ship an adhoc-signed framework that
# notarization rejects ten minutes into a release.
sign-app: stage-app
	@set -e; $(SET_SIGN_KEYCHAIN); \
	echo "Signing with '$(DEVID_APP_IDENTITY)' from $$SIGN_SOURCE (hardened runtime)..."; \
	$(SIGN_SPARKLE_HELPERS); \
	if [ -d "$(ARTIFACT_APP)/Contents/Frameworks" ]; then \
		find "$(ARTIFACT_APP)/Contents/Frameworks" -depth \( -name "*.framework" -o -name "*.dylib" \) -print0 \
		| xargs -0 -I{} codesign --force --options runtime --timestamp "$$@" --sign "$(DEVID_APP_IDENTITY)" "{}"; \
	fi; \
	codesign --force --options runtime --timestamp "$$@" \
		--sign "$(DEVID_APP_IDENTITY)" "$(ARTIFACT_APP)"
	codesign --verify --deep --strict --verbose=2 "$(ARTIFACT_APP)"
	@# codesign --verify --deep is happy with a VALID signature that is not
	@# ours, which is exactly what Sparkle's adhoc-signed helpers are. Only the
	@# notary service objects, ten minutes and one upload later, so assert team
	@# ownership of every nested binary here instead.
	@scripts/verify-nested-signatures.sh "$(ARTIFACT_APP)" "$(TEAM_ID)"
	@# Gatekeeper's own verdict. Before notarization it reports "rejected ...
	@# not notarized", which is expected; anything else (a bad signature, a
	@# broken hardened-runtime flag) is a real failure worth seeing now.
	@spctl --assess --type execute --verbose=4 "$(ARTIFACT_APP)" 2>&1 | sed 's/^/  /' || true
	@echo "Signed and verified."

# Signed .app in $(ARTIFACTS_DIR). Deliberately NOT stapled: that costs a round
# trip to Apple, and a local build wants to be fast. `make dmg` staples.
app: sign-app
	@echo "Signed app: $(ARTIFACT_APP)"

# Notarize the signed .app in its own right and staple the ticket into the
# bundle, before the DMG is built around it.
#
# Why this exists as a separate pass. A notarization ticket is bound to the
# cdhash it was issued for, and stapling the DMG attaches a ticket for the DMG.
# An app dragged out of that DMG therefore carries none of its own: Gatekeeper
# has to ask Apple instead, and a first launch with no network has nothing to
# fall back on. Verified on the 1.0.0 release, where `stapler validate` on the
# installed copy reported no ticket. Stapling the app closes that, at the cost
# of one extra submission per release.
#
# Zipped with ditto rather than zip(1): --keepParent preserves the .app as the
# archive's top-level directory (notarytool rejects a bare Contents/), and
# --sequesterRsrc keeps the symlink farm inside Sparkle.framework
# (Versions/Current and friends) intact. zip(1) flattens those symlinks into
# copies, which breaks the framework and the signature with it.
#
# The ticket lands as the file Contents/CodeResources, not an extended
# attribute, so it survives the `ditto --noextattr` staging in dmg below and the
# DMG round trip itself. Both were checked before this target was written.
staple-app: sign-app
ifndef SKIP_NOTARIZE
	@echo "Archiving the .app for its own notarization pass..."
	@rm -f "$(APP_ZIP)"
	ditto -c -k --sequesterRsrc --keepParent "$(ARTIFACT_APP)" "$(APP_ZIP)"
	$(MAKE) notarize NOTARIZE_TARGET="$(APP_ZIP)"
	@rm -f "$(APP_ZIP)"
	xcrun stapler staple "$(ARTIFACT_APP)"
	@# The ticket is added to the bundle after it was signed, so prove the
	@# signature still seals. A stapled app that no longer verifies would be
	@# strictly worse than one carrying no ticket at all.
	codesign --verify --deep --strict --verbose=2 "$(ARTIFACT_APP)"
	@echo "Notarized + stapled app: $(ARTIFACT_APP)"
else
	@echo "SKIP_NOTARIZE set, so the .app is signed but NOT notarized or stapled."
endif

# Install the signed .app into /Applications, replacing any existing copy.
install: sign-app
	@echo "Installing to /Applications/$(APP_NAME).app ..."
	rm -rf "/Applications/$(APP_NAME).app"
	ditto --noextattr --norsrc --noqtn "$(ARTIFACT_APP)" "/Applications/$(APP_NAME).app"
	xattr -dr com.apple.quarantine "/Applications/$(APP_NAME).app" 2>/dev/null || true
	@echo "Installed."

# ================================ DMG + Notarization ================================

# Build + sign the app, package a DMG (with an /Applications drag target), sign
# the DMG, then notarize and staple it (unless SKIP_NOTARIZE=1).
#
# Stapling matters: without it every launch needs a round trip to Apple to
# confirm the notarization, so a user who first opens the app offline is told it
# cannot be verified.
#
# Both the app and the DMG are stapled, which is why a release makes two trips
# to the notary service: staple-app submits the .app and staples it, then the
# DMG is built around that stapled copy and submitted in turn. The app's ticket
# is what covers a user who drags it out of the DMG and first opens it offline;
# the DMG's covers the download itself.
dmg: staple-app
	@echo "Packaging DMG..."
	mkdir -p "$(ARTIFACTS_DIR)"
	rm -f "$(DMG)"
	@STAGE=$$(mktemp -d); \
	ditto --noextattr --norsrc --noqtn "$(ARTIFACT_APP)" "$$STAGE/$(APP_NAME).app"; \
	ln -s /Applications "$$STAGE/Applications"; \
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$$STAGE" -fs HFS+ -format UDZO -ov "$(DMG)"; \
	rm -rf "$$STAGE"
	@echo "Signing DMG..."
	@set -e; $(SET_SIGN_KEYCHAIN); \
	codesign --force --timestamp "$$@" --sign "$(DEVID_APP_IDENTITY)" "$(DMG)"
ifndef SKIP_NOTARIZE
	$(MAKE) notarize NOTARIZE_TARGET="$(DMG)"
	xcrun stapler staple "$(DMG)"
	@echo "Notarized + stapled DMG: $(DMG)"
else
	@echo "SKIP_NOTARIZE set, so the DMG is signed but NOT notarized: $(DMG)"
endif

# Submit an artifact for notarization and wait for the result. NOTARIZE_TARGET
# must be set by the caller. Uses the notarytool profile stored in the build
# keychain by store-notary / prepare.
#
# On rejection, notarytool prints a submission id; `xcrun notarytool log <id>
# --keychain-profile $(NOTARY_PROFILE) --keychain $(KEYCHAIN_PATH)` gives the
# per-binary reasons, which is the only place they appear.
notarize: unlock-keychain
	@test -n "$(NOTARIZE_TARGET)" || { echo "ERROR: NOTARIZE_TARGET not set"; exit 1; }
	@echo "Submitting $(NOTARIZE_TARGET) for notarization (profile: $(NOTARY_PROFILE))..."
	xcrun notarytool submit "$(NOTARIZE_TARGET)" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--keychain "$(KEYCHAIN_PATH)" \
		--wait

# ================================ Sparkle appcast ================================

# Sign the built DMG with the Sparkle key and write the update feed.
#
# Kept out of `make dmg` on purpose: a throwaway or SKIP_NOTARIZE build has no
# business producing a feed, and `make dmg` should stay usable without the
# signing key. `make release` runs this between the build and the upload.
#
# The feed is a merge, not a rewrite: scripts/make-appcast.py fetches whatever
# is published at APPCAST_URL and folds the new item into it, so earlier
# releases keep their notes and re-running a release replaces its own item
# rather than appending a duplicate. That is only sound because R2_KEY is
# versioned: each historical item names an object that still holds the exact
# bytes its edSignature was computed over.
appcast:
	@test -f "$(DMG)" || { \
		echo "ERROR: no DMG at $(DMG)."; \
		echo "       Build it first: make dmg"; \
		exit 1; }
	@test -x "$(SPARKLE_SIGN_UPDATE)" || { \
		echo "ERROR: Sparkle's sign_update is not at $(SPARKLE_SIGN_UPDATE)."; \
		echo "       It ships in the SPM binary artifact under $(DERIVED_DATA), which"; \
		echo "       'make cleanup' removes. Any build restores it:"; \
		echo "           make build-app"; \
		exit 1; }
	@MIN_OS="$(MIN_MACOS)"; \
	if [ -f "$(ARTIFACT_APP)/Contents/Info.plist" ]; then \
		MIN_OS=$$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" \
			"$(ARTIFACT_APP)/Contents/Info.plist" 2>/dev/null || echo "$(MIN_MACOS)"); \
	else \
		echo "No build product to read LSMinimumSystemVersion from; using $(MIN_MACOS)."; \
	fi; \
	scripts/make-appcast.py \
		--dmg "$(DMG)" \
		--version "$(VERSION)" \
		--build "$(BUILD_NUMBER)" \
		--app-name "$(APP_NAME)" \
		--key "$(SPARKLE_PRIVATE_KEY)" \
		--sign-update "$(SPARKLE_SIGN_UPDATE)" \
		--download-url "$(DMG_URL)" \
		--feed-url "$(APPCAST_URL)" \
		--minimum-system-version "$$MIN_OS" \
		--output "$(APPCAST)"

# ================================ Release ================================

# The version and tag come from project.yml (see VERSION above), so the bump is
# committed before releasing rather than passed in here. Options:
#
#   RELEASE_TAG=1.2.0-rc1        Tag something other than $(VERSION)
#   ALLOW_DIRTY=1                Release with uncommitted changes in the tree
#   FORCE=1                      Re-cut a version that is already released:
#                                rebuilds and re-uploads everything, and
#                                updates the existing GitHub release in place
#                                instead of refusing because it exists
RELEASE_TAG					?= $(VERSION)
RELEASE_TITLE				?= $(APP_NAME) $(VERSION)

# R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and R2_BUCKET come from
# config.mk. No defaults: they are live credentials for the download bucket.
R2_FOLDER					?= dartradar
# One immutable object per release. Versioned rather than a single fixed key so
# that every appcast item keeps pointing at the exact bytes it was signed for:
# with one shared key each release overwrote the object the previous item named,
# which left historical entries advertising a length and edSignature that no
# longer described what was there. It also means the bucket keeps every build,
# so a bad release can be rolled back by republishing the previous feed.
#
# The cost is that the download URL changes every release, so website/index.html
# has to be updated in step. release-preflight enforces that rather than leaving
# it to be remembered.
R2_KEY						 = $(R2_FOLDER)/$(PRODUCT_SLUG)-$(VERSION).dmg
# The Sparkle feed, at the fixed key every installed copy polls. This has to
# resolve to APPCAST_URL through the bucket's public hostname, so changing
# R2_FOLDER also means republishing the app with a new SUFeedURL.
R2_APPCAST_KEY				 = $(R2_FOLDER)/appcast.xml
PUBLIC_BASE_URL				?= https://artifacts.birju.dev
DMG_URL						 = $(PUBLIC_BASE_URL)/$(R2_KEY)

# `make release` cuts a full release: preflight checks, the same signed +
# notarized DMG as `make dmg`, then the upload to R2.
# R2 goes first and GitHub last, deliberately. A failed upload then leaves
# nothing published and the whole target is safe to re-run; the reverse order
# would announce a release whose download does not exist yet.
#
# Within the R2 half the DMG goes up before the appcast, for the same reason at
# a smaller scale: the appcast is what makes every installed copy start
# downloading, so it must not name a URL that is still uploading. That makes the
# failure modes benign in one direction only, which is the useful one. A DMG
# with no appcast is simply not offered yet; an appcast with no DMG is a failed
# update on every Mac running the app.
release: release-preflight
	$(MAKE) dmg
	$(MAKE) appcast
	$(MAKE) upload-r2
	$(MAKE) upload-appcast
	$(MAKE) github-release
	@echo ""
	@echo "Released $(APP_NAME) $(VERSION)."
	@echo "  GitHub:   $$(gh release view '$(RELEASE_TAG)' --json url -q .url)"
	@echo "  R2:       s3://$(R2_BUCKET)/$(R2_KEY)"
	@echo "  Download: $(DMG_URL)"
	@echo "  Feed:     $(APPCAST_URL)"
	@echo ""
	@echo "Every copy running an older build is offered $(VERSION) within the hour,"
	@echo "or immediately from the app's Check for Updates."

# Everything knowable before the build is checked here, because the build plus
# notarization is a round trip to Apple that a release failing at the upload
# step has already spent.
release-preflight: guard-R2_ACCOUNT_ID guard-R2_ACCESS_KEY_ID guard-R2_SECRET_ACCESS_KEY guard-R2_BUCKET
ifdef SKIP_NOTARIZE
	@echo "ERROR: SKIP_NOTARIZE is set."
	@echo "       An un-notarized DMG is refused by Gatekeeper on every Mac but this one."
	@echo "       Drop SKIP_NOTARIZE, or use 'make dmg' for a throwaway build."
	@exit 1
endif
	@test -n "$(VERSION)" || { \
		echo "ERROR: could not read MARKETING_VERSION from $(PROJECT_SPEC)."; \
		echo "       The DMG filename is built from it, so an empty value would"; \
		echo "       silently package and upload '$(PRODUCT_SLUG)-.dmg'."; \
		exit 1; }
	@command -v aws >/dev/null 2>&1 || command -v rclone >/dev/null 2>&1 || { \
		echo "ERROR: no S3 client for the R2 upload."; \
		echo "           brew install awscli   # or: brew install rclone"; \
		exit 1; }
	@command -v gh >/dev/null 2>&1 || { \
		echo "ERROR: the GitHub CLI (gh) is not installed."; \
		echo "           brew install gh"; \
		exit 1; }
	@gh auth status >/dev/null 2>&1 || { \
		echo "ERROR: gh is not authenticated."; \
		echo "           gh auth login"; \
		exit 1; }
	@# The Sparkle key, checked here rather than at signing time: without it the
	@# feed cannot be written, and finding that out after the build and
	@# notarization have run costs ten minutes and a round trip to Apple.
	@test -f "$(SPARKLE_PRIVATE_KEY)" || { \
		echo "ERROR: no Sparkle signing key at $(SPARKLE_PRIVATE_KEY)."; \
		echo ""; \
		echo "       Updates are signed with the Ed25519 key whose public half is"; \
		echo "       SUPublicEDKey in DartRadar/Info.plist. Without that exact key no"; \
		echo "       installed copy will accept this release."; \
		exit 1; }
	@# A build number that does not climb is the one release mistake nothing
	@# else catches: the DMG installs fine by hand, and Sparkle silently never
	@# offers it because it compares CFBundleVersion, not the marketing version.
	@case "$(BUILD_NUMBER)" in \
		''|*[!0-9]*) \
			echo "ERROR: build number '$(BUILD_NUMBER)' is not a plain integer."; \
			echo "       Sparkle compares CFBundleVersion numerically. Fix CURRENT_PROJECT_VERSION"; \
			echo "       in $(PROJECT_SPEC)."; \
			exit 1 ;; \
	esac
	@git rev-parse --git-dir >/dev/null 2>&1 || { \
		echo "ERROR: this is not a git repository, so there is nothing to tag or release."; \
		echo "       gh creates the tag on the remote from the commit being released."; \
		exit 1; }
	@if [ -n "$$(git status --porcelain)" ]; then \
		if [ -n "$(ALLOW_DIRTY)" ]; then \
			echo "WARNING: releasing with uncommitted changes (ALLOW_DIRTY set)."; \
		else \
			echo "ERROR: the working tree has uncommitted changes."; \
			echo ""; \
			git status --short; \
			echo ""; \
			echo "       The tag records this commit, so anything uncommitted is not in"; \
			echo "       the release even though it is in the build. Commit it, or pass"; \
			echo "       ALLOW_DIRTY=1 to release anyway."; \
			exit 1; \
		fi; \
	fi
	@# gh creates a missing tag on the remote, so the commit being released has
	@# to be there already. Without this the release quietly names a tag whose
	@# contents are whatever was last pushed.
	@UPSTREAM=$$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true); \
	if [ -z "$$UPSTREAM" ]; then \
		echo "WARNING: this branch has no upstream; cannot tell whether HEAD is pushed."; \
	elif ! git merge-base --is-ancestor HEAD "$$UPSTREAM"; then \
		echo "ERROR: HEAD is not pushed to $$UPSTREAM."; \
		echo "       Push first: the release tag is created on the remote from this commit."; \
		exit 1; \
	fi
ifdef FORCE
	@# FORCE only makes sense against a release that exists. Requiring one
	@# catches the case it would otherwise hide: a typo in RELEASE_TAG silently
	@# creating a second, differently named release instead of replacing the one
	@# that was meant.
	@gh release view "$(RELEASE_TAG)" >/dev/null 2>&1 || { \
		echo "ERROR: FORCE is set, but no GitHub release for $(RELEASE_TAG) exists."; \
		echo "       FORCE replaces an existing release. Drop it to create one."; \
		exit 1; }
	@echo "FORCE set: the existing $(RELEASE_TAG) release will be updated in place."
	@# The tag was created when the release first went out and is NOT moved
	@# here: that needs a force push, which is the user's call, not this
	@# target's. Said out loud because the artifacts about to be uploaded are
	@# built from HEAD, so a tag left behind makes the release name a commit
	@# that is not what shipped.
	@if git rev-parse -q --verify "refs/tags/$(RELEASE_TAG)" >/dev/null 2>&1; then \
		TAGGED=$$(git rev-list -n1 "refs/tags/$(RELEASE_TAG)"); \
		if [ "$$TAGGED" != "$$(git rev-parse HEAD)" ]; then \
			echo ""; \
			echo "WARNING: tag $(RELEASE_TAG) is at $$(git rev-parse --short "$$TAGGED"), but this"; \
			echo "         build is from HEAD ($$(git rev-parse --short HEAD)). The release will"; \
			echo "         carry artifacts built from a commit its tag does not name."; \
			echo "         To move it:  git tag -f $(RELEASE_TAG) && git push --force origin $(RELEASE_TAG)"; \
			echo ""; \
		fi; \
	fi
else
	@if gh release view "$(RELEASE_TAG)" >/dev/null 2>&1; then \
		echo "ERROR: a GitHub release for $(RELEASE_TAG) already exists."; \
		echo "       Bump MARKETING_VERSION in $(PROJECT_SPEC), delete that release:"; \
		echo "           gh release delete $(RELEASE_TAG)"; \
		echo "       or re-cut it in place:"; \
		echo "           make release FORCE=1"; \
		exit 1; \
	fi
endif
	@scripts/changelog-section.sh "$(VERSION)" >/dev/null 2>&1 || \
		echo "WARNING: CHANGELOG.md has no '## $(VERSION)' section; GitHub will generate the notes."
	@# The download URL carries the version, so the site has to move with each
	@# release. Checked here because the failure is silent and outlives the
	@# release: the button keeps working, serving the PREVIOUS version, and the
	@# only symptom is users quietly installing a build behind the one just
	@# announced. website/ deploys from this repo on push, so the fix belongs in
	@# the same commit as the version bump.
	@SITE=website/index.html; \
	if [ -f "$$SITE" ]; then \
		if ! grep -qF '$(DMG_URL)' "$$SITE"; then \
			echo "ERROR: $$SITE does not link this release's download URL."; \
			echo ""; \
			echo "  expected: $(DMG_URL)"; \
			echo "  found:    $$(grep -oE 'https://[^"]*\.dmg' "$$SITE" | head -1 || echo '(no .dmg link)')"; \
			echo ""; \
			echo "  Update the download link in $$SITE and commit it with the version bump."; \
			exit 1; \
		fi; \
		echo "Website download link matches $(VERSION)."; \
	fi
	@echo "Preflight OK: releasing $(APP_NAME) $(VERSION) as $(RELEASE_TAG) to $(DMG_URL)."

# Upload the built DMG to the R2 download bucket. Overwrites the object if the
# key already exists, which is what makes a re-run of a half-finished release
# safe.
upload-r2: guard-R2_ACCOUNT_ID guard-R2_ACCESS_KEY_ID guard-R2_SECRET_ACCESS_KEY guard-R2_BUCKET
	@test -f "$(DMG)" || { echo "ERROR: no DMG at $(DMG). Run 'make dmg' first."; exit 1; }
	@R2_ACCOUNT_ID="$(R2_ACCOUNT_ID)" \
	 R2_ACCESS_KEY_ID="$(R2_ACCESS_KEY_ID)" \
	 R2_SECRET_ACCESS_KEY="$(R2_SECRET_ACCESS_KEY)" \
	 R2_BUCKET="$(R2_BUCKET)" \
	 R2_CONTENT_TYPE=application/x-apple-diskimage \
	 scripts/upload-r2.sh "$(DMG)" "$(R2_KEY)"

# Publish the GitHub release for $(RELEASE_TAG), with the DMG attached.
#
# --target pins the tag to this exact commit. Left off, gh creates a missing tag
# from the remote default branch's tip instead, which is the same commit only by
# luck.
#
# With FORCE=1 the release already exists, so it is edited rather than created:
# the notes and title are refreshed and the DMG is re-uploaded with --clobber,
# which replaces the asset of the same name. Two calls rather than one because
# gh has no single "create or replace" verb. The tag is deliberately left where
# it is; see the warning in release-preflight.
github-release:
	@test -f "$(DMG)" || { echo "ERROR: no DMG at $(DMG). Run 'make dmg' first."; exit 1; }
	@set -e; \
	NOTES=$$(mktemp); \
	trap 'rm -f "$$NOTES"' EXIT; \
	if scripts/changelog-section.sh "$(VERSION)" > "$$NOTES" 2>/dev/null && [ -s "$$NOTES" ]; then \
		echo "Notes: the CHANGELOG.md section for $(VERSION)."; \
		set -- --notes-file "$$NOTES"; \
	else \
		echo "Notes: generated by GitHub (no CHANGELOG.md section for $(VERSION))."; \
		set -- --generate-notes; \
	fi; \
	if [ -n "$(FORCE)" ]; then \
		echo "Updating existing GitHub release $(RELEASE_TAG)..."; \
		gh release edit "$(RELEASE_TAG)" --title "$(RELEASE_TITLE)" "$$@"; \
		echo "Replacing the attached DMG..."; \
		gh release upload "$(RELEASE_TAG)" "$(DMG)" --clobber; \
	else \
		echo "Creating GitHub release $(RELEASE_TAG)..."; \
		gh release create "$(RELEASE_TAG)" \
			--title "$(RELEASE_TITLE)" \
			--target "$$(git rev-parse HEAD)" \
			"$$@" \
			"$(DMG)"; \
	fi

# Upload the appcast to the fixed key every installed copy polls. Runs after
# upload-r2, so the DMG the feed names is already in place.
#
# Uploaded with a short max-age: this object is overwritten on every release and
# is the only thing standing between a published DMG and the users who should be
# offered it, so a CDN holding a day-old copy would delay every update by a day.
upload-appcast: guard-R2_ACCOUNT_ID guard-R2_ACCESS_KEY_ID guard-R2_SECRET_ACCESS_KEY guard-R2_BUCKET
	@test -f "$(APPCAST)" || { echo "ERROR: no appcast at $(APPCAST). Run 'make appcast' first."; exit 1; }
	@R2_ACCOUNT_ID="$(R2_ACCOUNT_ID)" \
	 R2_ACCESS_KEY_ID="$(R2_ACCESS_KEY_ID)" \
	 R2_SECRET_ACCESS_KEY="$(R2_SECRET_ACCESS_KEY)" \
	 R2_BUCKET="$(R2_BUCKET)" \
	 R2_CONTENT_TYPE=application/xml \
	 R2_CACHE_CONTROL="public, max-age=300" \
	 scripts/upload-r2.sh "$(APPCAST)" "$(R2_APPCAST_KEY)"

# ================================ Cleanup ================================

cleanup:
	$(MAKE) teardown-keychain
	rm -rf "$(ARTIFACTS_DIR)" "$(DERIVED_DATA)"
	@echo "Cleanup complete."
