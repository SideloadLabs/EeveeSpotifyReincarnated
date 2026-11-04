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

# RootHide's compatibility implementation of libroot resolves jailbreak paths
# through libroothide at runtime. Rootless builds continue to use libroot.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
EeveeSpotify_SWIFTFLAGS += -D ROOTHIDE
EeveeSpotify_LDFLAGS += -lroothide -Xlinker -rpath -Xlinker @loader_path/.jbroot/Library/Frameworks
else
EeveeSpotify_LDFLAGS += -lroot
endif

# Sideload compatibility (keychain redirect, group containers, CloudKit) is
# handled out-of-process by modules/zxPluginsInject — LC-injected via ipapatch
# in build-ipa-local.sh and the GitHub workflow. No flags needed here.

include $(THEOS_MAKE_PATH)/tweak.mk

# Karaoke background shader. Recursive (=) so these pick up the per-arch
# values THEOS_OBJ_DIR/THEOS_STAGING_DIR have once the recipe actually runs.
KARAOKE_SHADER_SRC = Sources/EeveeSpotify/Karaoke/KaraokeBackgroundShader.metal
KARAOKE_SHADER_AIR = $(THEOS_OBJ_DIR)/KaraokeBackgroundShader.air
KARAOKE_SHADER_LIB = $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/KaraokeBackgroundShader.metallib

internal-stage::
	# Bundle EeveeSwiftProtobuf.framework into the package. Renamed from
	# SwiftProtobuf so the @objc class names don't collide with the
	# SwiftProtobuf statically embedded in SpotifyShared.framework.
	mkdir -p $(THEOS_STAGING_DIR)/Library/Frameworks
	cp -r $(THEOS)/lib/iphone/$(or $(THEOS_PACKAGE_SCHEME),rootless)/EeveeSwiftProtobuf.framework $(THEOS_STAGING_DIR)/Library/Frameworks/
	# Compile the karaoke background Metal shader into a .metallib and
	# stage it next to the tweak binary so device.makeLibrary(filepath:)
	# can load it at runtime (Theos's tweak.mk has no built-in Metal
	# shader compilation step the way an Xcode app target's build phases
	# do, so this is done by hand here).
	#
	# Required by default, because KaraokeMetalBackgroundView silently
	# falls back to a placeholder gradient when the .metallib is missing:
	# a build that skipped this step would produce a package that differs
	# from CI's with nothing in the output to say so. Xcode 26+ ships the
	# Metal compiler as a separately downloaded component, so the failure
	# mode is a stub `metal` rather than a missing binary:
	#     xcodebuild -downloadComponent MetalToolchain
	# To build without the shader on purpose, pass SKIP_KARAOKE_SHADER=1.
	#
	# Remove stale artifacts first so a failed compile can never leave a
	# previous .metallib staged next to the dylib.
	@rm -f $(KARAOKE_SHADER_AIR) $(KARAOKE_SHADER_LIB)
ifeq ($(SKIP_KARAOKE_SHADER),1)
	@echo "warning: SKIP_KARAOKE_SHADER=1 — not building KaraokeBackgroundShader.metallib"
	@echo "warning: the karaoke background will use the placeholder gradient"
else
	@xcrun -sdk iphoneos metal -c $(KARAOKE_SHADER_SRC) -o $(KARAOKE_SHADER_AIR) || { \
		echo "error: could not compile $(KARAOKE_SHADER_SRC)"; \
		echo "error: if that mentions 'missing Metal Toolchain', install it with:"; \
		echo "error:     xcodebuild -downloadComponent MetalToolchain"; \
		echo "error: to build without the karaoke shader instead, re-run with SKIP_KARAOKE_SHADER=1"; \
		exit 1; \
	}
	@xcrun -sdk iphoneos metallib $(KARAOKE_SHADER_AIR) -o $(KARAOKE_SHADER_LIB) || { \
		echo "error: could not link $(KARAOKE_SHADER_AIR) into a .metallib"; \
		exit 1; \
	}
	@echo "staged KaraokeBackgroundShader.metallib"
endif

# Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source. Run
# this once before `make package`. Re-run if SWIFTPROTOBUF_VERSION changes
# or `swift --version` jumps a major.
build-eeveeswiftprotobuf:
	Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
