import XCTest
@testable import TranscriptCore

final class BookmarksAndSlideTextTests: XCTestCase {
    @MainActor
    func testCoordinatorBookmarksAndSlideText() async throws {
        let store = FileSessionStore(rootDirectory: try makeTempDirectory())
        let engine = MockEngine()
        let clock = TestClock()
        let coordinator = RecordingCoordinator(store: store, engine: engine, autosaveInterval: .seconds(3600), now: { clock.now() })
        try await coordinator.start(language: "en-US", saveAudio: false)
        let id = try XCTUnwrap(coordinator.session?.id)

        clock.advance(30)
        coordinator.markBookmark()
        XCTAssertEqual(try store.load(id: id).bookmarks.map(\.at), [at(30)], "bookmarks are saved immediately")

        let photo = try coordinator.addPhoto(jpegData: Data([1]))
        XCTAssertTrue(coordinator.setRecognizedText("Q3 Budget\nRevenue +12%", forPhoto: photo.id))
        XCTAssertFalse(coordinator.setRecognizedText("x", forPhoto: UUID()))

        let stopped = await coordinator.stop()
        let finished = try XCTUnwrap(stopped)
        XCTAssertEqual(finished.photos.first?.recognizedText, "Q3 Budget\nRevenue +12%")
        XCTAssertFalse(coordinator.setRecognizedText("late", forPhoto: photo.id), "no recording any more")
    }

    func testBookmarkCodableAndExport() throws {
        var s = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Before.", 1, 2))
        s.insert(.bookmark(Bookmark(at: at(3))))
        s.insert(speech("After.", 4, 5))
        s.endedAt = at(10)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertEqual(try decoder.decode(TranscriptSession.self, from: encoder.encode(s)), s)

        let text = TranscriptExporter.plainText(for: s, options: ExportOptions(includeHeader: false, timeZone: utc))
        XCTAssertEqual(text, "[14:00] Before.\n\n[14:00] ★ Bookmark\n\n[14:00] After.\n")
        let md = TranscriptExporter.markdown(for: s, options: ExportOptions(includeHeader: false, timeZone: utc))
        XCTAssertTrue(md.contains("**★ Bookmark 14:00:03**"), md)
    }

    func testPromptMarksBookmarksAndSlideText() throws {
        var s = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Look at this.", 1, 2))
        s.insert(.photo(PhotoAttachment(takenAt: at(3), fileName: "a.jpg", source: .camera, recognizedText: "Q3 \"Budget\"\n  Revenue +12%")))
        s.insert(.bookmark(Bookmark(at: at(4))))
        s.insert(speech("Important part.", 5, 6))
        let prompt = try InsightsPrompt(session: s, timeZone: utc)
        XCTAssertTrue(prompt.transcriptText.contains("[Photo taken 14:00. Slide text: \"Q3 'Budget' Revenue +12%\"]"), prompt.transcriptText)
        XCTAssertTrue(prompt.transcriptText.contains("[★ Bookmarked at 14:00]"), prompt.transcriptText)
        XCTAssertTrue(prompt.userText.contains("flagged as important"))
        XCTAssertTrue(prompt.userText.contains("may contain recognition errors"))
    }

    func testSummaryLanguageInstruction() throws {
        var s = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Hello.", 1, 2))
        XCTAssertTrue(try InsightsPrompt(session: s, language: .chinese).userText.contains("Simplified Chinese (简体中文), even if"))
        XCTAssertTrue(try InsightsPrompt(session: s, language: .bilingual).userText.contains("\"English — 中文\""))
        XCTAssertTrue(try InsightsPrompt(session: s).userText.contains("main language of the transcript"))
    }
}

final class ChaptersTests: XCTestCase {
    func testChaptersParsedAndExported() throws {
        var s = TranscriptSession(title: "Talk", localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Intro words.", 1, 2))
        s.insert(speech("Budget words.", 10, 11))
        s.insert(speech("More budget.", 11.5, 12))
        s.endedAt = at(20)
        let prompt = try InsightsPrompt(session: s, timeZone: utc)
        XCTAssertEqual(prompt.paragraphStarts, [at(1), at(10)])
        let json = """
        ```json
        {"title":"T","summary":"S","key_points":[],"action_items":[],"speakers":[],"speaker_turns":[],"photo_notes":[],
         "chapters":[{"paragraph":2,"title":"Budget"},{"paragraph":1,"title":"Intro"},{"paragraph":9,"title":"Ghost"}]}
        ```
        """
        let insights = try InsightsResponseParser.parse(json, prompt: prompt, model: "gpt-6.1-sol", now: t0)
        XCTAssertEqual(insights.chapters, [Chapter(start: at(1), title: "Intro"), Chapter(start: at(10), title: "Budget")])
        XCTAssertEqual(insights.model, "gpt-6.1-sol")

        s.insights = insights
        let text = TranscriptExporter.plainText(for: s, options: ExportOptions(timeZone: utc))
        XCTAssertTrue(text.contains("■ Intro\n\n[14:00] Intro words."), text)
        XCTAssertTrue(text.contains("■ Budget\n\n[14:00] Budget words. More budget."), text)
        let md = TranscriptExporter.markdown(for: s, options: ExportOptions(timeZone: utc))
        XCTAssertTrue(md.contains("### Budget\n\n**14:00** Budget words."), md)
    }
}

final class ChatCompletionsTests: XCTestCase {
    private func prompt(photos: Bool) throws -> InsightsPrompt {
        var s = TranscriptSession(localeIdentifier: "zh-CN", startedAt: t0)
        s.insert(speech("你好。", 1, 2))
        let photo = PhotoAttachment(takenAt: at(3), fileName: "a.jpg", source: .camera)
        s.insert(.photo(photo))
        let attached = photos ? [InsightsPhoto(id: photo.id, takenAt: photo.takenAt, jpegData: Data([7]), pixelWidth: 100, pixelHeight: 100)] : []
        return try InsightsPrompt(session: s, timeZone: utc, photos: attached)
    }

    func testProviderDefaults() {
        XCTAssertEqual(AIProvider.default, .chatGPT)
        XCTAssertEqual(AIProvider.chatGPT.defaultModel, "gpt-6.1-sol")
        XCTAssertEqual(AIProvider.qwen.chatCompletionsURL?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(AIProvider.gemini.chatCompletionsURL?.host, "generativelanguage.googleapis.com")
        XCTAssertNil(AIProvider.claude.chatCompletionsURL)
        XCTAssertEqual(ModelPricing.cost(modelID: "gpt-6.1-sol", inputTokens: 1_000_000, outputTokens: 0), 2)
    }

    func testRequestBodyWithPhoto() throws {
        let request = try ChatCompletionsRequest(prompt: prompt(photos: true), provider: .chatGPT)
        XCTAssertEqual(request.model, "gpt-6.1-sol")
        XCTAssertEqual(request.endpoint.absoluteString, "https://api.openai.com/v1/chat/completions")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNotNil(json["stream_options"])
        let format = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schemaBox = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schemaBox["strict"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url", "text"])
        let image = try XCTUnwrap(parts[1]["image_url"] as? [String: Any])
        XCTAssertEqual(image["url"] as? String, "data:image/jpeg;base64," + Data([7]).base64EncodedString())
    }

    func testGeminiAndQwenSpecifics() throws {
        let gemini = try ChatCompletionsRequest(prompt: prompt(photos: false), provider: .gemini, model: "  ")
        XCTAssertEqual(gemini.model, "gemini-3.8-flash", "blank model falls back to the default")
        let geminiJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: gemini.body) as? [String: Any])
        XCTAssertNil(geminiJSON["stream_options"])
        let messages = try XCTUnwrap(geminiJSON["messages"] as? [[String: Any]])
        XCTAssertTrue(messages[1]["content"] is String, "no photos: plain text content")

        let qwen = try ChatCompletionsRequest(prompt: prompt(photos: false), provider: .qwen, model: "qwen/qwen3.8-flash")
        XCTAssertEqual(qwen.model, "qwen/qwen3.8-flash")
        XCTAssertEqual(qwen.headers["X-Title"], "Dictation")
        XCTAssertNil(qwen.estimatedCost, "unknown price shows no cost")

        XCTAssertThrowsError(try ChatCompletionsRequest(prompt: prompt(photos: false), provider: .claude))
    }

    private func feed(_ sse: String) -> ChatCompletionStreamAccumulator {
        var acc = ChatCompletionStreamAccumulator()
        for line in sse.split(separator: "\n", omittingEmptySubsequences: false) { acc.consume(line: String(line)) }
        return acc
    }

    func testStreamAccumulation() throws {
        let acc = feed("""
        data: {"id":"c1","model":"gpt-6.1-sol","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

        data: {"id":"c1","model":"gpt-6.1-sol","choices":[{"index":0,"delta":{"content":"{\\"a\\":"}}]}

        data: {"id":"c1","model":"gpt-6.1-sol","choices":[{"index":0,"delta":{"content":"1}"},"finish_reason":"stop"}]}

        data: {"id":"c1","choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":340}}

        data: [DONE]
        """)
        XCTAssertEqual(try acc.finalText(), #"{"a":1}"#)
        XCTAssertEqual(acc.model, "gpt-6.1-sol")
        XCTAssertEqual(acc.inputTokens, 1200)
        XCTAssertEqual(acc.outputTokens, 340)
    }

    func testStreamFailures() {
        XCTAssertThrowsError(try feed(#"data: {"choices":[{"delta":{"content":"{"},"finish_reason":"length"}]}"#).finalText()) {
            XCTAssertEqual($0 as? AIServiceError, .truncated)
        }
        XCTAssertThrowsError(try feed(#"data: {"choices":[{"delta":{"content":"{"}}]}"#).finalText(), "cut off without finish")
        XCTAssertThrowsError(try feed(#"data: {"error":{"message":"Rate limit","type":"rate_limit_error","code":429}}"#).finalText()) {
            XCTAssertEqual(($0 as? AIServiceError)?.isRetryable, true)
        }
    }

    func testGeminiStyleErrorBody() {
        let body = Data(#"[{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT"}}]"#.utf8)
        XCTAssertEqual(AIServiceError.fromResponse(status: 400, body: body),
                       .http(status: 400, type: "INVALID_ARGUMENT", message: "API key not valid"))
    }
}

final class ReviewFixesTests: XCTestCase {
    func testNoCreditIsNotRetriedAndExplained() {
        let body = Data(#"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8)
        let error = AIServiceError.fromResponse(status: 429, body: body)
        XCTAssertFalse(error.isRetryable)
        XCTAssertTrue(error.errorDescription?.contains("no credit left") == true, error.errorDescription ?? "")
        XCTAssertTrue(error.errorDescription?.contains("check your plan") == true)
        XCTAssertTrue(AIServiceError.fromResponse(status: 429, body: Data()).isRetryable, "a plain rate limit is still retried")
        XCTAssertFalse(AIServiceError.http(status: 402, type: nil, message: nil).errorDescription?.contains("Anthropic") == true)
    }

    func testPricingForDatedSnapshots() {
        XCTAssertEqual(ModelPricing.cost(modelID: "gpt-6.1-sol-2026-09-01", inputTokens: 1_000_000, outputTokens: 0), 2)
        XCTAssertEqual(ModelPricing.cost(modelID: "claude-opus-5-5", inputTokens: 1_000_000, outputTokens: 0), 4)
        XCTAssertNil(ModelPricing.cost(modelID: "gpt-6.1-solar", inputTokens: 1, outputTokens: 1))
    }

    func testOpenAIRefusalIsReported() {
        var acc = ChatCompletionStreamAccumulator()
        acc.consume(line: #"data: {"choices":[{"delta":{"refusal":"I can't help with that."}}]}"#)
        acc.consume(line: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        acc.consume(line: "data: [DONE]")
        XCTAssertThrowsError(try acc.finalText()) { XCTAssertEqual($0 as? AIServiceError, .refusal(category: nil)) }
    }
}
