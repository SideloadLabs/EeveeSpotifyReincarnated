# 15.0, not 14.0: the iOS 26/27 SDK's libc++ hard-errors at a 14.0
# deployment target ("The selected platform is no longer supported by
# libc++." [-W#warnings]), which fails the build outright. 15.0 compiles
# cleanly with the unchanged upstream flags below. The package this module
# ships inside already declares `firmware (>= 16.1)`, so a 14.0 target was
# never reachable in practice.
TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := zxPluginsInject

$(TWEAK_NAME)_FILES := SideloadFix.xm ../fishhook/fishhook.c
$(TWEAK_NAME)_CFLAGS := -fobjc-arc -Os
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR := internal

include $(THEOS_MAKE_PATH)/tweak.mk
