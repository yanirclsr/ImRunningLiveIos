#!/bin/bash

# build-production.sh - Build iOS app for production deployment
set -e

echo "🚀 Building I'm Running Live iOS app for production..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_PATH="./Im Running App/Im Running App.xcodeproj"
SCHEME="Im Running App"
CONFIGURATION="Release"
ARCHIVE_PATH="./build/Im_Running_App.xcarchive"
EXPORT_PATH="./build/Im_Running_App.ipa"
EXPORT_OPTIONS_PLIST="./exportOptions.plist"

# Create build directory
mkdir -p build

echo -e "${BLUE}📱 Building for production deployment...${NC}"

# Clean previous builds
echo -e "${YELLOW}🧹 Cleaning previous builds...${NC}"
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" clean

# Archive the app
echo -e "${YELLOW}📦 Archiving app...${NC}"
xcodebuild -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  archive \
  -archivePath "$ARCHIVE_PATH"

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✅ Archive created successfully!${NC}"
else
  echo -e "${RED}❌ Archive failed!${NC}"
  exit 1
fi

# Create export options plist
echo -e "${YELLOW}📋 Creating export options...${NC}"
cat > "$EXPORT_OPTIONS_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>ad-hoc</string>
    <key>teamID</key>
    <string>49USC54C28</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <false/>
    <key>compileBitcode</key>
    <false/>
    <key>thinning</key>
    <string>&lt;none&gt;</string>
</dict>
</plist>
EOF

# Export IPA
echo -e "${YELLOW}📤 Exporting IPA...${NC}"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

if [ $? -eq 0 ]; then
  echo -e "${GREEN}✅ IPA exported successfully!${NC}"
  echo -e "${BLUE}📁 IPA location: $EXPORT_PATH${NC}"
else
  echo -e "${RED}❌ IPA export failed!${NC}"
  exit 1
fi

# Clean up
rm -f "$EXPORT_OPTIONS_PLIST"

echo -e "${GREEN}🎉 Production build completed successfully!${NC}"
echo ""
echo -e "${BLUE}📋 Next steps:${NC}"
echo "1. Install the IPA on your device using one of these methods:"
echo "   - Drag & drop to Xcode Devices window"
echo "   - Use TestFlight (upload to App Store Connect first)"
echo "   - Use Ad Hoc distribution"
echo ""
echo "2. The app will automatically use your production server:"
echo "   - Production URL: https://imrunning.live"
echo "   - WebSocket: wss://imrunning.live"
echo ""
echo "3. Test the app functionality with your production server"
echo ""
echo -e "${YELLOW}⚠️  Note: Make sure your production server is running and accessible${NC}"
