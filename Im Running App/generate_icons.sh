#!/bin/bash

# Generate iOS app icons from SVG
# This script requires ImageMagick to be installed

echo "🎨 Generating iOS app icons..."

# Create output directory
mkdir -p "Im Running App/Assets.xcassets/AppIcon.appiconset"

# Generate all required sizes
sizes=(
    "40:20x20@2x"    # iPhone 20pt @2x
    "60:20x20@3x"    # iPhone 20pt @3x
    "58:29x29@2x"    # iPhone 29pt @2x
    "87:29x29@3x"    # iPhone 29pt @3x
    "80:40x40@2x"    # iPhone 40pt @2x
    "120:40x40@3x"   # iPhone 40pt @3x
    "120:60x60@2x"   # iPhone 60pt @2x
    "180:60x60@3x"   # iPhone 60pt @3x
    "40:20x20@1x"    # iPad 20pt @1x
    "80:20x20@2x"    # iPad 20pt @2x
    "58:29x29@1x"    # iPad 29pt @1x
    "116:29x29@2x"   # iPad 29pt @2x
    "80:40x40@1x"    # iPad 40pt @1x
    "160:40x40@2x"   # iPad 40pt @2x
    "152:76x76@2x"   # iPad 76pt @2x
    "167:83.5x83.5@2x" # iPad 83.5pt @2x
    "1024:1024x1024@1x" # App Store
)

for size in "${sizes[@]}"; do
    IFS=':' read -r pixels dimensions <<< "$size"
    filename="Im Running App/Assets.xcassets/AppIcon.appiconset/icon_${dimensions}.png"
    
    echo "Generating $filename (${pixels}x${pixels})"
    
    # Use ImageMagick to convert SVG to PNG
    if command -v convert &> /dev/null; then
        convert -background transparent -size "${pixels}x${pixels}" "Im Running App/Assets.xcassets/AppIcon.appiconset/icon.svg" "$filename"
    else
        echo "❌ ImageMagick not found. Please install it first:"
        echo "   brew install imagemagick"
        exit 1
    fi
done

echo "✅ All icons generated successfully!"
echo "📱 Don't forget to add the icon files to your Xcode project"
