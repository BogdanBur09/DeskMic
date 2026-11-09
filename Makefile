export THEOS ?= $(HOME)/theos
TARGET := iphone:clang:9.3:9.0
ARCHS := armv7

THEOS_STAGING_DIR = /tmp/DeskMic_staging

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = DeskMic

DeskMic_FILES = main.m AppDelegate.m RootViewController.m
DeskMic_FRAMEWORKS = UIKit AudioToolbox AVFoundation
DeskMic_CFLAGS = -fobjc-arc
DeskMic_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk
