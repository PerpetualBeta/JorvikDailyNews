import Foundation
import Observation

/// Per-article section classifier. Multinomial naive Bayes with Laplace
/// smoothing, trained purely from explicit user corrections — never from
/// implicit "didn't move this" signal, which is how classifiers drift.
///
/// Cold-start behaviour: `predict` returns nil until at least three
/// sections have three or more training docs each. Before that, callers
/// fall back to the feed's section, so the paper still looks sensible on
/// a fresh install. Every "Move to…" correction (a) pins the article to
/// its new section permanently via `pins` and (b) trains the model,
/// composing cleanly with any earlier correction on the same article.
@Observable
@MainActor
final class ArticleClassifier {
    private(set) var state: ClassifierState
    private let storeURL: URL

    init() {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("JorvikDailyNews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("classifier.json")
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode(ClassifierState.self, from: data) {
            self.state = decoded
        } else {
            self.state = ClassifierState()
        }
    }

    // MARK: - Public

    /// Sections the model has seen training examples for. Used by the UI
    /// so the "Move to…" menu includes sections the user has trained on
    /// even if no feed currently carries that name as a default.
    var knownSections: [String] {
        Array(state.sectionDocs.keys)
    }

    /// Whether the model has enough training to produce predictions.
    var isReady: Bool {
        state.sectionDocs.values.filter { $0 >= 3 }.count >= 3
    }

    /// Section the user has pinned for this article, if any. Pins survive
    /// across relaunches and force the article to render under that
    /// section regardless of what the classifier would otherwise predict.
    func pinnedSection(itemId: String) -> String? {
        state.pins[itemId]
    }

    /// Best-guess section for arbitrary article text. Returns nil when
    /// the classifier is cold or the top choice isn't meaningfully ahead
    /// of the runner-up (log-margin < `minimumLogMargin`). Callers must
    /// supply a fallback for nil — the classifier never guesses.
    func predict(text: String, minimumLogMargin: Double = 1.0) -> String? {
        guard isReady else { return nil }
        let freqs = Self.tokenFrequencies(Self.tokenise(text))
        guard !freqs.isEmpty else { return nil }

        let totalDocs = state.sectionDocs.values.reduce(0, +)
        let numClasses = max(1, state.sectionDocs.count)
        let vocabSize = max(1, state.vocabulary.count)
        var scored: [(section: String, logP: Double)] = []
        scored.reserveCapacity(state.sectionDocs.count)

        for (section, docCount) in state.sectionDocs {
            let priorLog = log(Double(docCount + 1)) - log(Double(totalDocs + numClasses))
            let denom = Double((state.sectionTotalTokens[section] ?? 0) + vocabSize)
            var score = priorLog
            for (token, count) in freqs {
                let num = Double((state.tokenCounts[token]?[section] ?? 0) + 1)
                score += Double(count) * (log(num) - log(denom))
            }
            scored.append((section, score))
        }

        scored.sort { $0.logP > $1.logP }
        guard let top = scored.first else { return nil }
        if scored.count > 1 {
            let margin = top.logP - scored[1].logP
            if margin < minimumLogMargin { return nil }
        }
        return top.section
    }

    /// Pin an article to `section` and train the model on its text. If the
    /// article had been pinned to a different section before, the earlier
    /// training is undone first so consecutive corrections compose instead
    /// of stacking.
    func move(itemId: String, text: String, to section: String) {
        if let prior = state.corrections[itemId] {
            unapply(prior)
        }
        let freqs = Self.tokenFrequencies(Self.tokenise(text))
        apply(tokens: freqs, section: section)
        state.corrections[itemId] = .init(tokens: freqs, section: section)
        state.pins[itemId] = section
        save()
    }

    // MARK: - Internals

    private func apply(tokens: [String: Int], section: String) {
        for (t, c) in tokens {
            state.tokenCounts[t, default: [:]][section, default: 0] += c
            state.vocabulary.insert(t)
        }
        let total = tokens.values.reduce(0, +)
        state.sectionTotalTokens[section, default: 0] += total
        state.sectionDocs[section, default: 0] += 1
    }

    private func unapply(_ c: ClassifierState.Correction) {
        for (t, freq) in c.tokens {
            guard var bySection = state.tokenCounts[t] else { continue }
            let remaining = (bySection[c.section] ?? 0) - freq
            if remaining <= 0 {
                bySection[c.section] = nil
            } else {
                bySection[c.section] = remaining
            }
            if bySection.isEmpty {
                state.tokenCounts[t] = nil
                state.vocabulary.remove(t)
            } else {
                state.tokenCounts[t] = bySection
            }
        }
        let total = c.tokens.values.reduce(0, +)
        state.sectionTotalTokens[c.section] = max(0, (state.sectionTotalTokens[c.section] ?? 0) - total)
        let docs = max(0, (state.sectionDocs[c.section] ?? 0) - 1)
        if docs == 0 {
            state.sectionDocs[c.section] = nil
            state.sectionTotalTokens[c.section] = nil
        } else {
            state.sectionDocs[c.section] = docs
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Tokenisation

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "are", "was", "were",
        "has", "have", "had", "been", "being", "its", "they", "them", "their",
        "our", "your", "you", "his", "her", "him", "she", "but", "not", "too",
        "can", "who", "what", "when", "where", "why", "how", "all", "any",
        "some", "into", "over", "about", "just", "than", "then", "also",
        "will", "would", "could", "should", "may", "might", "more", "most",
        "much", "many", "such"
    ]

    private static func tokenise(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var tokens: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if current.count >= 3, current.count <= 24, !stopwords.contains(current) {
                    tokens.append(current)
                }
                current = ""
            }
        }
        if current.count >= 3, current.count <= 24, !stopwords.contains(current) {
            tokens.append(current)
        }
        return tokens
    }

    private static func tokenFrequencies(_ tokens: [String]) -> [String: Int] {
        var freq: [String: Int] = [:]
        for t in tokens { freq[t, default: 0] += 1 }
        return freq
    }
}

struct ClassifierState: Codable {
    var tokenCounts: [String: [String: Int]] = [:]
    var sectionTotalTokens: [String: Int] = [:]
    var sectionDocs: [String: Int] = [:]
    var vocabulary: Set<String> = []
    var pins: [String: String] = [:]
    var corrections: [String: Correction] = [:]

    struct Correction: Codable {
        let tokens: [String: Int]
        let section: String
    }
}
