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
# Sources, one variable per folder so the grouping survives in the build
# and a new file has an obvious home. release.mk takes the composed list;
# it also auto-globs JorvikKit/*.swift, which is not repeated here.

# The entry point, the shell, and the store everything hangs off.
APP_SOURCES := App/AppStore.swift \
               App/ContentView.swift \
               App/DayRollover.swift \
               App/JorvikDailyNewsApp.swift \
               App/StoreMigration.swift

# The newspaper itself: masthead, front page, section pages, cards.
PAPER_SOURCES := Paper/Edition.swift \
                 Paper/EditionBuilder.swift \
                 Paper/FrontPage.swift \
                 Paper/MasonryColumns.swift \
                 Paper/Masthead.swift \
                 Paper/OptionalImage.swift \
                 Paper/SectionPageView.swift \
                 Paper/StoryCard.swift

# Extracting a standfirst, and fitting it to the space it has.
STANDFIRST_SOURCES := Standfirsts/Standfirst.swift \
                      Standfirsts/StandfirstLayout.swift \
                      Standfirsts/StandfirstText.swift

# Reading one article: extraction, block rendering, media, links.
READER_SOURCES := Reader/ArticleExtractor.swift \
                  Reader/EmailLinkSheet.swift \
                  Reader/EmbeddedArticle.swift \
                  Reader/MailtoLink.swift \
                  Reader/NativeReaderView.swift \
                  Reader/ProseText.swift \
                  Reader/ReaderBlock.swift \
                  Reader/ReaderSheet.swift \
                  Reader/VideoLink.swift

# Subscriptions: fetching, parsing, discovery, classification.
FEEDS_SOURCES := Feeds/AddFeedSheet.swift \
                 Feeds/ArticleClassifier.swift \
                 Feeds/Feed.swift \
                 Feeds/FeedDiscovery.swift \
                 Feeds/FeedFetcher.swift \
                 Feeds/ImageEnricher.swift \
                 Feeds/ManageFeedsSheet.swift \
                 Feeds/OPMLExporter.swift \
                 Feeds/OPMLImporter.swift

# Fetching, caching, cropping and de-duplicating hero images.
PICTURES_SOURCES := Pictures/ImageCache.swift \
                    Pictures/PagePictures.swift \
                    Pictures/PictureSignature.swift \
                    Pictures/PictureSignatureStore.swift

# The four files on disk.
STORAGE_SOURCES := Storage/EditionStore.swift \
                   Storage/FeedStore.swift \
                   Storage/ReadStore.swift

# Small things with no home of their own.
SUPPORT_SOURCES := Support/BoundedFetch.swift \
                   Support/Log.swift \
                   Support/WebURL.swift

SWIFT_SOURCES := $(APP_SOURCES) \
                 $(PAPER_SOURCES) \
                 $(STANDFIRST_SOURCES) \
                 $(READER_SOURCES) \
                 $(FEEDS_SOURCES) \
                 $(PICTURES_SOURCES) \
                 $(STORAGE_SOURCES) \
                 $(SUPPORT_SOURCES)

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
TEST_SOURCES := Reader/VideoLink.swift \
                Support/WebURL.swift \
                Reader/MailtoLink.swift \
                Support/BoundedFetch.swift \
                Reader/EmbeddedArticle.swift \
                Pictures/PictureSignature.swift \
                Pictures/PictureSignatureStore.swift \
                Pictures/PagePictures.swift \
                App/DayRollover.swift \
                Reader/ReaderBlock.swift \
                Feeds/Feed.swift \
                Feeds/FeedFetcher.swift \
                Standfirsts/Standfirst.swift \
                Paper/EditionBuilder.swift \
                Paper/Edition.swift \
                Support/Log.swift \
                Pictures/ImageCache.swift

TEST_HARNESS := Tests/TestRunner.swift \
                Tests/VideoLinkTests.swift \
                Tests/FeedFetcherTests.swift \
                Tests/FeedBoundsTests.swift \
                Tests/StandfirstTests.swift \
                Tests/EditionBuilderTests.swift \
                Tests/PagePicturesTests.swift \
                Tests/DayRolloverTests.swift \
                Tests/WebURLTests.swift \
                Tests/ReaderLinkTests.swift \
                Tests/MailtoLinkTests.swift \
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
