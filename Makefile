TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CraneBadgeFix

CraneBadgeFix_FILES = Tweak.xm
CraneBadgeFix_CFLAGS = -fobjc-arc
CraneBadgeFix_LIBRARIES = substrate
CraneBadgeFix_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"