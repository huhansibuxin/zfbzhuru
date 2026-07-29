ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = com.alipay.iphoneclient

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BlockAlipayApp
BlockAlipayApp_FILES = Tweak.xm
BlockAlipayApp_CFLAGS = -fobjc-arc
BlockAlipayApp_LIBRARIES = substrate
BlockAlipayApp_FRAMEWORKS = UIKit CoreLocation UserNotifications BackgroundTasks NetworkExtension

include $(THEOS_MAKE_PATH)/tweak.mk
