import Foundation
import Speech
import TranscriptCore

enum TranscriberKind: String, Sendable {
    /// Long-form, on-device model built for conversations (preferred).
    case speech = "SpeechTranscriber"
    /// Dictation model; used only if SpeechTranscriber isn't available.
    case dictation = "DictationTranscriber"
}

/// Which transcriber to use and for which supported locale.
struct ResolvedModel: Sendable {
    let kind: TranscriberKind
    let locale: Locale
}

/// A transcriber module. A module belongs to one analyzer, so every capture run
/// creates a fresh one.
enum TranscriberModule {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var speechModule: any SpeechModule {
        switch self {
        case .speech(let transcriber): return transcriber
        case .dictation(let transcriber): return transcriber
        }
    }
}

enum SpeechModelSetup {
    /// Finds a transcriber that supports the language and makes sure its model
    /// is installed (downloading it the first time, which can take a minute).
    static func resolve(
        localeIdentifier: String,
        allowSpeechTranscriber: Bool,
        log: DiagnosticsLog,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> ResolvedModel {
        let requested = Locale(identifier: localeIdentifier)
        var lastError: Error?

        if allowSpeechTranscriber {
            let locales = await SpeechTranscriber.supportedLocales
            log.log("SpeechTranscriber supports \(locales.count) locales", category: "engine")
            if let locale = bestMatch(for: requested, in: locales) {
                let model = ResolvedModel(kind: .speech, locale: locale)
                do {
                    try await installAssets(for: model, log: log, status: status)
                    return model
                } catch {
                    // A cancelled start must not fall through to downloading
                    // the other model.
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    lastError = error
                    log.log("SpeechTranscriber model for \(locale.identifier) unavailable: \(EngineDescribe.error(error))", category: "engine")
                }
            } else {
                log.log("SpeechTranscriber doesn't support \(localeIdentifier)", category: "engine")
            }
        }

        let dictationLocales = await DictationTranscriber.supportedLocales
        log.log("DictationTranscriber supports \(dictationLocales.count) locales", category: "engine")
        if let locale = bestMatch(for: requested, in: dictationLocales) {
            let model = ResolvedModel(kind: .dictation, locale: locale)
            do {
                try await installAssets(for: model, log: log, status: status)
                return model
            } catch {
                lastError = error
                log.log("DictationTranscriber model for \(locale.identifier) unavailable: \(EngineDescribe.error(error))", category: "engine")
            }
        }

        if let lastError {
            throw SpeechEngineError.modelDownloadFailed(EngineDescribe.error(lastError))
        }
        throw SpeechEngineError.languageNotSupported(TranscriptLanguage.displayName(for: localeIdentifier))
    }

    /// - Parameter fastCaptions: also ask for `.fastResults`, which makes the
    ///   recognizer use a smaller context window: live (volatile) text arrives
    ///   sooner, but can be slightly less accurate. Apple's
    ///   `progressiveTranscription` preset uses the same reporting options.
    static func makeModule(_ model: ResolvedModel, fastCaptions: Bool = false) -> TranscriberModule {
        switch model.kind {
        case .speech:
            .speech(SpeechTranscriber(
                locale: model.locale,
                transcriptionOptions: [],
                reportingOptions: fastCaptions ? [.volatileResults, .fastResults] : [.volatileResults],
                attributeOptions: [.audioTimeRange]
            ))
        case .dictation:
            .dictation(makeDictationTranscriber(locale: model.locale))
        }
    }

    /// Fallback transcriber, kept in one place because it is the least certain
    /// API in this engine. Punctuation is on; volatile results and audio time
    /// ranges match what the SpeechTranscriber path asks for.
    static func makeDictationTranscriber(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Exact BCP-47 match first, then same language and region, then same language.
    static func bestMatch(for requested: Locale, in available: [Locale]) -> Locale? {
        let identifier = requested.identifier(.bcp47)
        if let exact = available.first(where: { $0.identifier(.bcp47) == identifier }) {
            return exact
        }
        let language = requested.language.languageCode?.identifier
        let region = requested.language.region?.identifier
        if let sameRegion = available.first(where: {
            $0.language.languageCode?.identifier == language && $0.language.region?.identifier == region
        }) {
            return sameRegion
        }
        return available.first(where: { $0.language.languageCode?.identifier == language })
    }

    private static func installAssets(
        for model: ResolvedModel,
        log: DiagnosticsLog,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let module = makeModule(model).speechModule
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            log.log("\(model.kind.rawValue) model for \(model.locale.identifier) is installed", category: "engine")
            return
        }
        log.log("Downloading \(model.kind.rawValue) model for \(model.locale.identifier)", category: "engine")
        status("Downloading the speech model (first time only)…")
        let progress = request.progress
        let reporter = Task {
            var lastPercent = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let percent = Int(progress.fractionCompleted * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    status("Downloading the speech model: \(percent)%")
                }
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
        log.log("\(model.kind.rawValue) model for \(model.locale.identifier) installed", category: "engine")
        status("Speech model ready")
    }
}
