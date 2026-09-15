#!/bin/bash
# Builds the vendored PockKit framework-dylib and both Pock widgets.
set -euo pipefail
cd "$(dirname "$0")"

DIST="dist"
ARCHS=("arm64" "x86_64")
MIN_MACOS="15.0"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_DIR="$DIST/PockKit.swiftmodule"
POCKKIT_INSTALL_NAME="@rpath/PockKit.framework/PockKit"

# Single source of truth for every Media Bar artifact.
source version.env

rm -rf "$DIST"
mkdir -p "$DIST/archs" "$MODULE_DIR" "$DIST/lib"

echo "==> Building PockKit ($POCKKIT_INSTALL_NAME)"
for arch in "${ARCHS[@]}"; do
    swiftc -target "${arch}-apple-macos${MIN_MACOS}" -sdk "$SDKROOT" \
        -emit-library -emit-module -module-name PockKit -O \
        -emit-module-path "$MODULE_DIR/${arch}.swiftmodule" \
        -Xlinker -install_name -Xlinker "$POCKKIT_INSTALL_NAME" \
        -o "$DIST/archs/PockKit-${arch}" \
        Vendor/PockKit/*.swift
done
lipo -create "$DIST"/archs/PockKit-* -output "$DIST/lib/libPockKit.dylib"

# Shim so test executables can resolve @rpath/PockKit.framework/PockKit.
mkdir -p "$DIST/lib/PockKit.framework"
ln -sf ../libPockKit.dylib "$DIST/lib/PockKit.framework/PockKit"

echo "==> Building Now Playing helper"
# The helper is a plain dylib rather than a tool because MediaRemote only
# answers Apple-signed interpreter processes; see the README. It is loaded
# into /usr/bin/perl at runtime.
clang -dynamiclib -fobjc-arc -framework Foundation \
    -o ../helper/libnowplaying.dylib ../helper/nowplaying.m

echo "==> Building MediaBar widget"
# The widget resolves PockKit symbols at load time from Pock's own embedded
# framework (plugin-style, -undefined dynamic_lookup). This makes the bundle
# load in ANY Pock version regardless of how its PockKit was built.
for arch in "${ARCHS[@]}"; do
    swiftc -target "${arch}-apple-macos${MIN_MACOS}" -sdk "$SDKROOT" \
        -emit-library -module-name MediaBar -O \
        -I "$DIST" \
        -Xlinker -undefined -Xlinker dynamic_lookup \
        Sources/*.swift \
        -o "$DIST/archs/MediaBar-${arch}"
done

BUNDLE="$DIST/MediaBar.pock"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
lipo -create "$DIST"/archs/MediaBar-* -output "$BUNDLE/Contents/MacOS/MediaBar"
cp Info.plist "$BUNDLE/Contents/Info.plist"
# The helper the widget shells out to for MediaRemote reads.
cp ../helper/libnowplaying.dylib "$BUNDLE/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MEDIA_BAR_VERSION" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MEDIA_BAR_BUILD" "$BUNDLE/Contents/Info.plist"

echo "==> Bundle: $BUNDLE"
otool -L "$BUNDLE/Contents/MacOS/MediaBar" | head -6
echo "==> Media Bar version: $MEDIA_BAR_VERSION ($MEDIA_BAR_BUILD)"

# Always emit installable archives so the .pock and .pkarchive can never
# drift to different versions. Pock expects the .pock folder at archive root.
(
    cd "$DIST"
    rm -f MediaBar.pkarchive "MediaBar-$MEDIA_BAR_VERSION.pkarchive"
    zip -r -q MediaBar.pkarchive MediaBar.pock
    cp MediaBar.pkarchive "MediaBar-$MEDIA_BAR_VERSION.pkarchive"
)
echo "==> Archive: $DIST/MediaBar.pkarchive"
echo "==> Archive: $DIST/MediaBar-$MEDIA_BAR_VERSION.pkarchive"

if [[ "${1:-}" == "--install" ]]; then
    WIDGETS_DIR="$HOME/Library/Application Support/Pock/Widgets"
    mkdir -p "$WIDGETS_DIR"
    rm -rf "$WIDGETS_DIR/MediaBar.pock"
    cp -R "$BUNDLE" "$WIDGETS_DIR/MediaBar.pock"
    echo "==> Installed to $WIDGETS_DIR/MediaBar.pock"
    echo "==> Restart Pock (menu bar icon → Relaunch) to load the widget."
fi
