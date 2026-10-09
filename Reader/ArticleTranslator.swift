import Foundation
import NaturalLanguage
import Observation
#if canImport(Translation)
import Translation
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Translates an article in the reader, on this Mac, into the reader's own
/// language.
///
/// **Two engines, chosen per article.** Apple's Translation framework is the
/// first choice: purpose-built, fast, and offline once a language pair has
/// been downloaded, which macOS asks about once. It covers about 25 languages
/// (47 variants on macOS 27.0.1, measured 2026-10-05) and **not Romanian**,
/// which is the article that prompted this. For a language it does not cover,
/// the Apple Intelligence model is the fallback: on the Romanian article it
/// produced a natural English paragraph in 3.9 s, although it reports no
/// official support for Romanian, so its translations are labelled
/// approximate. Neither leaves the Mac. A Mac with neither sees no button.
///
/// **A block at a time, not a run at a time.** Translating each formatting
/// run alone would cut a sentence wherever it is bold or linked and translate
/// the halves apart. So a block's whole text is translated and drawn as plain
/// text; its links and emphasis come back with Show Original.
@MainActor @Observable
final class ArticleTranslation {
    enum Engine: Equatable {
        /// Apple's Translation framework.
        case system
        /// The Apple Intelligence model, for a language the framework lacks.
        case model
    }

    enum Phase: Equatable {
        /// Already in the reader's language, too short to tell, or no engine.
        case unavailable
        case offered
        case translating(done: Int, total: Int)
        case translated
        case failed(String)
    }

    private(set) var phase: Phase = .unavailable
    private(set) var engine: Engine?
    private(set) var source: Locale.Language?
    /// Whether the translation is on screen. Off returns the original.
    var showing = false

    private(set) var translations: [TranslationKey: String] = [:]
    private var pieces: [(key: TranslationKey, text: String)] = []
    private var titleKey: TranslationKey { TranslationKey(block: -1, part: .runs) }

    /// What the system engine's `.translationTask` watches. Setting it starts a
    /// run; nil does nothing. Stored untyped because the type only exists on
    /// macOS 15 and later; `systemConfiguration` reads it back.
    private var systemRequest: Any?

    #if canImport(Translation)
    @available(macOS 15, *)
    var systemConfiguration: TranslationSession.Configuration? {
        systemRequest as? TranslationSession.Configuration
    }
    #endif

    /// The reader's own language: the first one in their system preferences.
    static var target: Locale.Language { Locale.current.language }

    /// "Romanian", in the reader's language.
    var sourceName: String {
        guard let code = source?.languageCode?.identifier else { return "" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: - Deciding

    /// Detects the language and decides whether, and how, to offer a
    /// translation. Call once per article.
    func prepare(title: String?, blocks: [ReaderBlock]) async {
        reset()
        pieces = TranslatableText.pieces(title: title, blocks: blocks, titleKey: titleKey)
        let sample = pieces.prefix(Self.detectionPieces).map(\.text)
        guard sample.joined(separator: "\n").count >= Self.detectionMinimumCharacters else { return }
        guard let detected = TranslatableText.language(of: sample), detected != .undetermined else { return }
        let language = Locale.Language(identifier: detected.rawValue)
        guard language.languageCode != Self.target.languageCode else { return }
        source = language
        engine = await Self.engine(from: language, to: Self.target)
        guard let engine else {
            jdnLog("translate: article is in \(detected.rawValue); no engine on this Mac can translate it")
            return
        }
        jdnLog("translate: article is in \(detected.rawValue); \(engine == .system ? "Translation framework" : "Apple Intelligence model") can translate it")
        phase = .offered
    }

    /// The best engine for a pair, or nil if neither can do it.
    private static func engine(from source: Locale.Language, to target: Locale.Language) async -> Engine? {
        #if canImport(Translation)
        if #available(macOS 15, *) {
            let status = await LanguageAvailability().status(from: source, to: target)
            if status != .unsupported { return .system }
        }
        #endif
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            if model.isAvailable, model.supportsLocale(Locale(identifier: target.minimalIdentifier)) {
                return .model
            }
        }
        #endif
        return nil
    }

    // MARK: - Translating

    /// Starts the translation, or shows it again if it has already run.
    func translate() {
        showing = true
        switch phase {
        case .offered, .failed:
            break
        default:
            return
        }
        phase = .translating(done: 0, total: pieces.count)
        started = Date()
        switch engine {
        case .system:
            // The view's `.translationTask` sees the new configuration, asks
            // macOS to download the pair if it must, and calls `run(session:)`.
            #if canImport(Translation)
            if #available(macOS 15, *), let source {
                systemRequest = TranslationSession.Configuration(source: source, target: Self.target)
            }
            #endif
        case .model:
            Task { await runModel() }
        case nil:
            phase = .unavailable
        }
    }

    private var started = Date()

    #if canImport(Translation)
    /// The system engine's run, handed its session by `.translationTask`.
    @available(macOS 15, *)
    func run(session: TranslationSession) async {
        let requests = pieces.enumerated().map {
            TranslationSession.Request(sourceText: $1.text, clientIdentifier: String($0))
        }
        do {
            for try await response in session.translate(batch: requests) {
                guard let id = response.clientIdentifier, let index = Int(id), pieces.indices.contains(index)
                else { continue }
                record(response.targetText, for: pieces[index].key)
            }
            finish(failures: 0)
        } catch {
            fail(error)
        }
    }
    #endif

    /// The model engine's run: one piece at a time, each in a fresh session so
    /// the context never fills with the article so far.
    private func runModel() async {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return }
        let instructions = "Translate the user's text from \(sourceName) into "
            + "\(Locale.current.localizedString(forLanguageCode: Self.target.languageCode?.identifier ?? "en") ?? "English"). "
            + "Reply with the translation only. Keep names, numbers and quotations as they are."
        var failures = 0
        for piece in pieces {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let reply = try await session.respond(to: piece.text)
                record(reply.content, for: piece.key)
            } catch {
                // A refusal (its safety filters do refuse some news) or a
                // piece too long: that piece stays in the original.
                failures += 1
                jdnLog("translate: one piece stayed in the original — \(error.localizedDescription)")
                record(nil, for: piece.key)
            }
        }
        finish(failures: failures)
        #endif
    }

    private func record(_ text: String?, for key: TranslationKey) {
        if let text, !text.isEmpty { translations[key] = text }
        if case .translating(let done, let total) = phase {
            phase = .translating(done: done + 1, total: total)
        }
    }

    private func finish(failures: Int) {
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        jdnLog("translate: \(translations.count) of \(pieces.count) piece(s) translated from \(source?.minimalIdentifier ?? "?") "
               + "by the \(engine == .model ? "model" : "Translation framework") in \(seconds)s"
               + (failures > 0 ? ", \(failures) left in the original" : ""))
        phase = .translated
    }

    private func fail(_ error: Error) {
        jdnLog("translate: failed — \(error.localizedDescription)")
        phase = .failed(error.localizedDescription)
        systemRequest = nil
    }

    // MARK: - Drawing

    /// The blocks to draw: translated where a translation exists, original
    /// everywhere else, so the article fills in as it goes.
    func blocks(_ original: [ReaderBlock]) -> [ReaderBlock] {
        guard showing, !translations.isEmpty else { return original }
        return TranslatableText.apply(translations, to: original)
    }

    /// The headline to draw, translated when showing.
    func title(_ original: String) -> String {
        guard showing, let translated = translations[titleKey] else { return original }
        return translated
    }

    private func reset() {
        phase = .unavailable
        engine = nil
        source = nil
        showing = false
        translations = [:]
        pieces = []
        systemRequest = nil
    }

    // MARK: - Measurements

    /// How much of the article is read to decide its language. The opening
    /// pieces, not the whole thing: a page's language is settled within a few
    /// paragraphs, and the rest only costs time.
    static let detectionPieces = 8
    /// Below this the recogniser is guessing: a headline of four words can
    /// read as several languages at once.
    static let detectionMinimumCharacters = 200
}

/// Where a piece of translated text belongs.
struct TranslationKey: Hashable {
    enum Part: Hashable {
        /// The block's own text, or the headline when the block is -1.
        case runs
        /// One line of a list.
        case item(Int)
        /// An image's caption.
        case caption
    }

    let block: Int
    let part: Part
}

/// Which text in an article is translated, and how it is put back. Pure, so it
/// can be tested without an engine.
enum TranslatableText {
    /// Every piece of prose, in reading order, the headline first.
    static func pieces(title: String?, blocks: [ReaderBlock], titleKey: TranslationKey)
        -> [(key: TranslationKey, text: String)] {
        var out: [(TranslationKey, String)] = []
        if let title, !title.isEmpty { out.append((titleKey, title)) }
        for block in blocks {
            switch block.kind {
            case .paragraph, .heading, .quote:
                add(block.runs, TranslationKey(block: block.position, part: .runs), to: &out)
            case .list:
                for (i, item) in (block.items ?? []).enumerated() {
                    add(item.runs, TranslationKey(block: block.position, part: .item(i)), to: &out)
                }
            case .image, .svg:
                add(block.caption, TranslationKey(block: block.position, part: .caption), to: &out)
            case .code, .rule, .table:
                // Code is not prose; a table's cells are too short to
                // translate well one by one and too structured to join.
                break
            }
        }
        return out.map { (key: $0.0, text: $0.1) }
    }

    /// The language of an article's opening pieces: each piece asked on its own, and the answers
    /// added up weighted by the piece's length, so a 640-character paragraph counts ten times as
    /// much as a 61-character headline.
    ///
    /// **Not one call on the pieces joined together.** `NLLanguageRecognizer` judges from roughly
    /// the opening of what it is given and barely reads the rest. Measured on 2026-10-09 on
    /// ServeTheHome's "Gigabyte W775-V10-L01 Hands-on": the first eight pieces joined were 3,100
    /// characters, 2,952 of them plain English paragraphs, and the recogniser answered Indonesian
    /// 0.453, English 0.125, with exactly the same scores from the first 100 characters as from all
    /// 3,100. Those 100 were the headline and an image caption, mostly model numbers. The same
    /// pieces in reverse order read as English 0.998, and each long paragraph alone read as
    /// English at 0.927 or more. So the opening decided it, and the opening was the least prose
    /// on the page. Asked one piece at a time, every paragraph is read, and the length weighting
    /// lets prose outvote a headline and a caption.
    static func language(of texts: [String]) -> NLLanguage? {
        var score: [NLLanguage: Double] = [:]
        for text in texts {
            let recogniser = NLLanguageRecognizer()
            recogniser.processString(text)
            let weight = Double(text.count)
            for (language, probability) in recogniser.languageHypotheses(withMaximum: 5) {
                score[language, default: 0] += probability * weight
            }
        }
        return score.max { $0.value < $1.value }?.key
    }

    private static func add(_ runs: [ReaderBlock.Run]?, _ key: TranslationKey,
                            to out: inout [(TranslationKey, String)]) {
        let text = (runs ?? []).map(\.text).joined()
        guard text.contains(where: \.isLetter) else { return }
        out.append((key, text))
    }

    /// A copy of the blocks with each translated piece in place of its text.
    static func apply(_ translations: [TranslationKey: String], to blocks: [ReaderBlock]) -> [ReaderBlock] {
        blocks.map { block in
            var copy = block
            if let text = translations[TranslationKey(block: block.position, part: .runs)] {
                copy.runs = [plain(text)]
            }
            if let text = translations[TranslationKey(block: block.position, part: .caption)] {
                copy.caption = [plain(text)]
            }
            if let items = block.items {
                copy.items = items.enumerated().map { i, item in
                    guard let text = translations[TranslationKey(block: block.position, part: .item(i))]
                    else { return item }
                    return ReaderBlock.Item(runs: [plain(text)], depth: item.depth,
                                            ordered: item.ordered, index: item.index)
                }
            }
            return copy
        }
    }

    private static func plain(_ text: String) -> ReaderBlock.Run {
        ReaderBlock.Run(text: text, bold: false, italic: false, code: false, href: nil)
    }
}
