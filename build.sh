#!/bin/bash

# ==============================================================================
#  build.sh
#  Volly
#
#  Created for Arena.ai on 2026-07-15.
#  Automates compilation of Volly and packages it into a native .dmg file with a custom logo icon.
#  Must be run on a macOS machine with Xcode or Xcode Command Line Tools installed.
# ==============================================================================

# Exit immediately if any command fails
set -e

# Change directory to the script's parent folder.
# This prevents "file not found" errors if the script is executed from outside the directory!
cd "$(dirname "$0")"

# Define ANSI escape codes for beautiful output formatting
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BLUE}${BOLD}======================================================================${NC}"
echo -e "${BLUE}${BOLD}                 🔉 Volly Builder & DMG Packager                      ${NC}"
echo -e "${BLUE}${BOLD}======================================================================${NC}"

# 1. Verification of the Operating System
if [ "$(uname)" != "Darwin" ]; then
    echo -e "${RED}${BOLD}❌ ERROR: This script must be executed on a macOS system.${NC}"
    echo -e "Compilation of AppKit/SwiftUI/CoreAudio requires Apple's swiftc compiler and SDK."
    echo -e "Please copy the project source folder to your Mac and run this script there."
    exit 1
fi

# 2. Verification of Developer Tools
if ! command -v swiftc &> /dev/null; then
    echo -e "${RED}${BOLD}❌ ERROR: Xcode Command Line Tools were not detected.${NC}"
    echo -e "Please open a Terminal on your Mac and install them by running: ${BOLD}xcode-select --install${NC}"
    exit 1
fi

# 3. Clean and prepare build directories
echo -e "\n${YELLOW}🧹 Cleaning up previous builds...${NC}"
rm -rf build Volly.dmg dmg_tmp
mkdir -p build

APP_DIR="build/Volly.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 4. Generate AppIcon.icns from AppIcon.png
if [ -f "AppIcon.png" ]; then
    echo -e "${YELLOW}🎨 Generating native macOS App Icon (.icns) from AppIcon.png...${NC}"
    mkdir -p Volly.iconset
    
    sips -z 16 16     AppIcon.png --out Volly.iconset/icon_16x16.png &>/dev/null
    sips -z 32 32     AppIcon.png --out Volly.iconset/icon_16x16@2x.png &>/dev/null
    sips -z 32 32     AppIcon.png --out Volly.iconset/icon_32x32.png &>/dev/null
    sips -z 64 64     AppIcon.png --out Volly.iconset/icon_32x32@2x.png &>/dev/null
    sips -z 128 128   AppIcon.png --out Volly.iconset/icon_128x128.png &>/dev/null
    sips -z 256 256   AppIcon.png --out Volly.iconset/icon_128x128@2x.png &>/dev/null
    sips -z 256 256   AppIcon.png --out Volly.iconset/icon_256x256.png &>/dev/null
    sips -z 512 512   AppIcon.png --out Volly.iconset/icon_256x256@2x.png &>/dev/null
    sips -z 512 512   AppIcon.png --out Volly.iconset/icon_512x512.png &>/dev/null
    sips -z 1024 1024 AppIcon.png --out Volly.iconset/icon_512x512@2x.png &>/dev/null
    
    iconutil -c icns Volly.iconset
    cp Volly.icns "$RESOURCES_DIR/Volly.icns"
    rm -rf Volly.iconset Volly.icns
    echo -e "${GREEN}✅ Custom App Icon successfully compiled and installed!${NC}"
else
    echo -e "${YELLOW}⚠️ AppIcon.png not found, skipping icon compilation...${NC}"
fi

# 5. Local Swift Compilation
echo -e "${YELLOW}🚀 Compiling Swift sources (targeting macOS Sonoma 14.2+)...${NC}"
# Determine the active macOS SDK path dynamically
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)

# Normalize host architecture to prevent uname compilation issues
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "arm64" ] || [ "$HOST_ARCH" = "aarch64" ]; then
    TARGET_ARCH="arm64"
else
    TARGET_ARCH="x86_64"
fi

echo -e "   • Architecture: $TARGET_ARCH"
echo -e "   • SDK Path:     $SDK_PATH"

swiftc -O \
    -sdk "$SDK_PATH" \
    -target "$TARGET_ARCH-apple-macos14.2" \
    -parse-as-library \
    AudioEngine.swift ContentView.swift VollyApp.swift \
    -framework CoreAudio -framework AudioToolbox -framework SwiftUI -framework AppKit -framework Combine \
    -o "$MACOS_DIR/Volly"

echo -e "${GREEN}✅ Binary compiled successfully!${NC}"

# 6. Package App Metadata
echo -e "${YELLOW}📄 Copying Plist configurations...${NC}"
if [ -f "Info.plist" ]; then
    cp Info.plist "$CONTENTS_DIR/Info.plist"
else
    echo -e "${RED}❌ Info.plist not found in the source directory!${NC}"
    exit 1
fi

# 7. Apply Code-Signing with Entitlements
# Apple Silicon Macs require all binary executables to be signed (at least ad-hoc)
# or the OS kernel will kill the process instantly on execution (Killed: 9).
# Entitlements are embedded directly in the Mach-O binary, and then the bundle is signed.
echo -e "${YELLOW}🔐 Code-signing the application bundle (ad-hoc)...${NC}"
if [ -f "Volly.entitlements" ]; then
    codesign -s - --entitlements Volly.entitlements --force "$MACOS_DIR/Volly"
    codesign -s - --force "$APP_DIR"
else
    # Fallback to signing without entitlements if file is missing
    codesign -s - --force "$MACOS_DIR/Volly"
    codesign -s - --force "$APP_DIR"
fi
echo -e "${GREEN}✅ App signed successfully!${NC}"

# 8. DMG Packaging
echo -e "${YELLOW}📦 Packaging into a downloadable .dmg archive...${NC}"
mkdir -p dmg_tmp
cp -R "$APP_DIR" dmg_tmp/

# Create a symlink to the Mac's /Applications directory inside the DMG
# so that users can install the application by dragging-and-dropping.
ln -s /Applications dmg_tmp/Applications

# Package the folder into a Compressed UDZO Read-Only DMG image
hdiutil create \
    -volname "Volly" \
    -srcfolder dmg_tmp \
    -ov \
    -format UDZO \
    Volly.dmg

echo -e "${GREEN}✅ DMG created successfully!${NC}"

# 9. Housekeeping
rm -rf dmg_tmp build
echo -e "\n${GREEN}${BOLD}🎉 SUCCESS! Volly.dmg has been built successfully.${NC}"
echo -e "You can now open ${BOLD}Volly.dmg${NC} on your Mac and drag the app to your Applications folder."
echo -e "${BLUE}${BOLD}======================================================================${NC}"
