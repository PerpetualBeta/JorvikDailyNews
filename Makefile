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

# PDFKit is deliberately ABSENT. The app does not link it at all any more:
# the PDF helper in Contents/XPCServices links it instead. That makes "PDFKit
# never parses a feed's bytes in this process" a property of the link line
# rather than a claim in a comment, and a future edit that reintroduces an
# in-process parse fails to compile instead of quietly shipping.
SWIFT_FRAMEWORKS := Cocoa SwiftUI WebKit JavaScriptCore AVKit AVFoundation Vision
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
                  Reader/BaseHref.swift \
                  Reader/IsolatedPDFView.swift \
                  Reader/PDFContentType.swift \
                  Reader/PDFRenderClient.swift \
                  Reader/EmailLinkSheet.swift \
                  Reader/EmbeddedArticle.swift \
                  Reader/MailtoLink.swift \
                  Reader/NativeReaderView.swift \
                  Reader/ProseText.swift \
                  Reader/SVGSafety.swift \
                  Reader/VideoPreflight.swift \
                  Reader/ReaderBlock.swift \
                  Reader/ReaderLede.swift \
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
                   Support/Clamping.swift \
                   Support/RedirectGuard.swift \
                   Support/Log.swift \
                   Support/WebURL.swift

# Shared with the PDF helper, so both ends agree on one declaration.
XPC_SHARED_SOURCES := PDFService/PDFRenderProtocol.swift

SWIFT_SOURCES := $(APP_SOURCES) \
                 $(PAPER_SOURCES) \
                 $(STANDFIRST_SOURCES) \
                 $(READER_SOURCES) \
                 $(FEEDS_SOURCES) \
                 $(PICTURES_SOURCES) \
                 $(STORAGE_SOURCES) \
                 $(SUPPORT_SOURCES) \
                 $(XPC_SHARED_SOURCES)

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := JorvikDailyNews.entitlements
# The PDF helper gets its OWN, far smaller, entitlements. Signed without
# these it would have no sandbox, which is worse than not having a helper:
# today PDFKit at least parses inside the app's sandbox.
NESTED_ENTITLEMENTS := Contents/XPCServices/PDFService.xpc=PDFService/PDFService.entitlements

include ../jorvik-release/release.mk

# ---------------------------------------------------------------------------
# The PDF helper
#
# A feed controls the bytes of a linked PDF and also chooses that PDFKit is
# what parses them, because routing is extension-driven. PDFKit is a large
# C/C++ parser with a long CVE history and it used to run in this app's own
# process, one click from a headline. It now runs in a bundled XPC service
# with nothing but `app-sandbox` to its name: no network, no file access, no
# user data. A memory-safety bug in PDFKit becomes a crash of a process
# launchd will restart.
#
# Built the way release.mk builds the app — per arch, then lipo — so the helper
# is universal too. A thin helper inside a universal app would fail on
# whichever architecture it lacked, and only there.
#
# `stamp` depends on this, so the order is build → helper → stamp → sign. That
# matters: release.mk's sign pass finds nested .xpc bundles and signs them, so
# the helper has to exist before signing rather than after.
XPC_NAME       := PDFService
XPC_BUNDLE     := $(BUILT_BUNDLE)/Contents/XPCServices/$(XPC_NAME).xpc
XPC_SOURCES    := PDFService/PDFRenderProtocol.swift \
                  PDFService/PDFRenderService.swift \
                  PDFService/main.swift
XPC_FRAMEWORKS := -framework Cocoa -framework PDFKit

.PHONY: xpc-service
xpc-service: build
	@echo "→ build $(XPC_NAME).xpc (swiftc, universal)"
	@mkdir -p "$(XPC_BUNDLE)/Contents/MacOS"
	for ARCH in $(ARCH_LIST); do
		xcrun swiftc -O -target $$ARCH-apple-macos$(MACOS_TARGET) \
			-o "$(XPC_BUNDLE)/Contents/MacOS/$(XPC_NAME)_$$ARCH" \
			$(XPC_SOURCES) $(XPC_FRAMEWORKS)
	done
	lipo -create $(foreach A,$(ARCH_LIST),"$(XPC_BUNDLE)/Contents/MacOS/$(XPC_NAME)_$(A)") \
		-output "$(XPC_BUNDLE)/Contents/MacOS/$(XPC_NAME)"
	rm -f $(foreach A,$(ARCH_LIST),"$(XPC_BUNDLE)/Contents/MacOS/$(XPC_NAME)_$(A)")
	cp PDFService/Info.plist "$(XPC_BUNDLE)/Contents/Info.plist"

stamp: xpc-service

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
                Feeds/OPMLImporter.swift \
                Support/RedirectGuard.swift \
                Reader/ReaderLede.swift \
                Reader/VideoPreflight.swift \
                Reader/SVGSafety.swift \
                PDFService/PDFRenderProtocol.swift \
                Reader/PDFContentType.swift \
                Support/WebURL.swift \
                Reader/MailtoLink.swift \
                Support/BoundedFetch.swift \
                Support/Clamping.swift \
                Reader/EmbeddedArticle.swift \
                Pictures/PictureSignature.swift \
                Pictures/PictureSignatureStore.swift \
                Pictures/PagePictures.swift \
                App/DayRollover.swift \
                Reader/ReaderBlock.swift \
                Reader/BaseHref.swift \
                Storage/ReadStore.swift \
                Feeds/ArticleClassifier.swift \
                Feeds/Feed.swift \
                Feeds/FeedFetcher.swift \
                Standfirsts/Standfirst.swift \
                Paper/EditionBuilder.swift \
                Paper/Edition.swift \
                Support/Log.swift \
                Pictures/ImageCache.swift

TEST_HARNESS := Tests/TestRunner.swift \
                Tests/OPMLImportTests.swift \
                Tests/RedirectGuardTests.swift \
                Tests/ReaderLedeTests.swift \
                Tests/VideoPreflightTests.swift \
                Tests/SVGSafetyTests.swift \
                Tests/PDFPageSizesTests.swift \
                Tests/PDFContentTypeTests.swift \
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
                Tests/ReaderBlockTests.swift \
                Tests/LegacyIDTests.swift \
                Tests/BaseHrefTests.swift \
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
