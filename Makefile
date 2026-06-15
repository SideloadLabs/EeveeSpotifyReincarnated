TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = Spotify
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EeveeSpotify

REPO_SLUG ?= $(shell git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$$|\1|')
REPO_SLUG_FINAL := $(if $(REPO_SLUG),$(REPO_SLUG),jaydenjcpy/EeveeSpotifyReincarnated)

BRANCH_NAME ?= $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null)
BRANCH_NAME_FINAL := $(if $(BRANCH_NAME),$(BRANCH_NAME),Master)

$(shell mkdir -p Sources/EeveeSpotify/Generated)
$(shell printf 'enum GeneratedConfig {\n    static let repoSlug = "%s"\n    static let branchName = "%s"\n}\n' "$(REPO_SLUG_FINAL)" "$(BRANCH_NAME_FINAL)" > Sources/EeveeSpotify/Generated/RepoSlug.swift)

EeveeSpotify_FILES = $(shell find Sources/EeveeSpotify -name '*.swift') $(shell find Sources/EeveeSpotifyC -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
EeveeSpotify_SWIFTFLAGS = -ISources/EeveeSpotifyC/include -Osize
EeveeSpotify_EXTRA_FRAMEWORKS = EeveeSwiftProtobuf
EeveeSpotify_CFLAGS = -fobjc-arc -ISources/EeveeSpotifyC/include -Os

# Sideload compatibility (keychain redirect, group containers, CloudKit) is
# handled out-of-process by modules/zxPluginsInject — LC-injected via ipapatch
# in build-ipa-local.sh and the GitHub workflow. No flags needed here.

include $(THEOS_MAKE_PATH)/tweak.mk

internal-stage::
	# Bundle EeveeSwiftProtobuf.framework into the package. Renamed from
	# SwiftProtobuf so the @objc class names don't collide with the
	# SwiftProtobuf statically embedded in SpotifyShared.framework.
	mkdir -p $(THEOS_STAGING_DIR)/Library/Frameworks
	cp -r $(THEOS)/lib/iphone/rootless/EeveeSwiftProtobuf.framework $(THEOS_STAGING_DIR)/Library/Frameworks/

# Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source. Run
# this once before `make package`. Re-run if SWIFTPROTOBUF_VERSION changes
# or `swift --version` jumps a major.
build-eeveeswiftprotobuf:
	Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
