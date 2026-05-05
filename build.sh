#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="JorvikDailyNews"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

# Embed Sparkle.framework into the bundle
cp -R "$SCRIPT_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# rpath @executable_path/../Frameworks lets the runtime find the embedded framework.
swiftc -O -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$SCRIPT_DIR/JorvikDailyNewsApp.swift" \
    "$SCRIPT_DIR/ContentView.swift" \
    "$SCRIPT_DIR/Masthead.swift" \
    "$SCRIPT_DIR/FrontPage.swift" \
    "$SCRIPT_DIR/SectionPageView.swift" \
    "$SCRIPT_DIR/MasonryColumns.swift" \
    "$SCRIPT_DIR/StoryCard.swift" \
    "$SCRIPT_DIR/OptionalImage.swift" \
    "$SCRIPT_DIR/AddFeedSheet.swift" \
    "$SCRIPT_DIR/ManageFeedsSheet.swift" \
    "$SCRIPT_DIR/ReaderSheet.swift" \
    "$SCRIPT_DIR/ArticleExtractor.swift" \
    "$SCRIPT_DIR/ArticleClassifier.swift" \
    "$SCRIPT_DIR/AppStore.swift" \
    "$SCRIPT_DIR/Feed.swift" \
    "$SCRIPT_DIR/Edition.swift" \
    "$SCRIPT_DIR/FeedStore.swift" \
    "$SCRIPT_DIR/EditionStore.swift" \
    "$SCRIPT_DIR/ReadStore.swift" \
    "$SCRIPT_DIR/FeedFetcher.swift" \
    "$SCRIPT_DIR/FeedDiscovery.swift" \
    "$SCRIPT_DIR/EditionBuilder.swift" \
    "$SCRIPT_DIR/ImageEnricher.swift" \
    "$SCRIPT_DIR/OPMLImporter.swift" \
    "$SCRIPT_DIR/OPMLExporter.swift" \
    "$SCRIPT_DIR"/JorvikKit/*.swift \
    -F "$SCRIPT_DIR" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework WebKit \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks'

cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
# Bundled resources (Readability.js, reader.css, etc.)
if [ -d "$SCRIPT_DIR/Resources" ]; then
    cp -R "$SCRIPT_DIR/Resources/"* "$APP_BUNDLE/Contents/Resources/"
fi

# Ad-hoc sign for local development. Release Manager performs the Developer ID
# signing (incl. nested Sparkle code) and notarisation when cutting a release.
codesign --force --sign - "$APP_BUNDLE"

echo "Built: $APP_BUNDLE"
