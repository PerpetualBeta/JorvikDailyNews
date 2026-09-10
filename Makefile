# Jorvik Daily News — daily-paper-shaped RSS reader.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. swiftc project, embedded Sparkle,
# dual-ship (.zip + .pkg). Build name is JorvikDailyNews.app;
# install name is "Jorvik Daily News.app" (the friendly form users
# see in /Applications and the Dock).

BUNDLE_NAME      := JorvikDailyNews
BUNDLE_TYPE      := app
PRODUCT_NAME     := JorvikDailyNews.app
INSTALL_NAME     := Jorvik Daily News.app
BUNDLE_ID        := cc.jorviksoftware.JorvikDailyNews
BUILD_SYSTEM     := swiftc

SWIFT_FRAMEWORKS := Cocoa SwiftUI WebKit JavaScriptCore PDFKit AVKit AVFoundation Vision
SWIFT_SOURCES    := JorvikDailyNewsApp.swift \
                    ContentView.swift \
                    Masthead.swift \
                    FrontPage.swift \
                    SectionPageView.swift \
                    MasonryColumns.swift \
                    StoryCard.swift \
                    OptionalImage.swift \
                    ImageCache.swift \
                    PictureSignature.swift \
                    PictureSignatureStore.swift \
                    PagePictures.swift \
                    DayRollover.swift \
                    AddFeedSheet.swift \
                    ManageFeedsSheet.swift \
                    ReaderSheet.swift \
                    ArticleExtractor.swift \
                    EmbeddedArticle.swift \
                    ArticleClassifier.swift \
                    AppStore.swift \
                    Feed.swift \
                    VideoLink.swift \
                    ReaderBlock.swift \
                    NativeReaderView.swift \
                    ProseText.swift \
                    Edition.swift \
                    FeedStore.swift \
                    EditionStore.swift \
                    ReadStore.swift \
                    FeedFetcher.swift \
                    Log.swift \
                    Standfirst.swift \
                    StandfirstLayout.swift \
                    StandfirstText.swift \
                    FeedDiscovery.swift \
                    EditionBuilder.swift \
                    ImageEnricher.swift \
                    OPMLImporter.swift \
                    OPMLExporter.swift

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := JorvikDailyNews.entitlements

include ../jorvik-release/release.mk

# ---------------------------------------------------------------------------
# Tests
#
# Not XCTest and not `swift test`: this app is a single `swiftc` binary with
# no Xcode project and no Package.swift, and QuitProtect's `swift test` only
# works because release.mk hands it framework flags. `Tests/` is an ordinary
# executable that asserts and exits non-zero, which is all a human or a CI
# runner needs from it.
#
# TEST_SOURCES is the model layer, deliberately a subset of SWIFT_SOURCES: the
# views are excluded because nothing in them is testable without a screen, and
# pulling them in would drag `@main` into a second binary. Everything listed
# here is Foundation-only apart from ImageCache, which EditionBuilder consults
# to ask whether a picture is known to have failed.
TEST_SOURCES := VideoLink.swift \
                EmbeddedArticle.swift \
                PictureSignature.swift \
                PictureSignatureStore.swift \
                PagePictures.swift \
                DayRollover.swift \
                ReaderBlock.swift \
                Feed.swift \
                FeedFetcher.swift \
                Standfirst.swift \
                EditionBuilder.swift \
                Edition.swift \
                Log.swift \
                ImageCache.swift

TEST_HARNESS := Tests/TestRunner.swift \
                Tests/VideoLinkTests.swift \
                Tests/FeedFetcherTests.swift \
                Tests/StandfirstTests.swift \
                Tests/EditionBuilderTests.swift \
                Tests/PagePicturesTests.swift \
                Tests/DayRolloverTests.swift \
                Tests/ReaderLinkTests.swift \
                Tests/EmbeddedArticleTests.swift \
                Tests/WalkerTests.swift \
                Tests/main.swift

TEST_BIN := .build/tests

.PHONY: test
test: $(TEST_BIN)
	@$(TEST_BIN)

$(TEST_BIN): $(TEST_SOURCES) $(TEST_HARNESS) | .build
	@echo "→ build $(TEST_BIN) (swiftc)"
	@xcrun swiftc -o $(TEST_BIN) $(TEST_SOURCES) $(TEST_HARNESS)

.build:
	@mkdir -p .build
