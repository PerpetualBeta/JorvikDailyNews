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

SWIFT_FRAMEWORKS := Cocoa SwiftUI WebKit
SWIFT_SOURCES    := JorvikDailyNewsApp.swift \
                    ContentView.swift \
                    Masthead.swift \
                    FrontPage.swift \
                    SectionPageView.swift \
                    MasonryColumns.swift \
                    StoryCard.swift \
                    OptionalImage.swift \
                    AddFeedSheet.swift \
                    ManageFeedsSheet.swift \
                    ReaderSheet.swift \
                    ArticleExtractor.swift \
                    ArticleClassifier.swift \
                    AppStore.swift \
                    Feed.swift \
                    Edition.swift \
                    FeedStore.swift \
                    EditionStore.swift \
                    ReadStore.swift \
                    FeedFetcher.swift \
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
