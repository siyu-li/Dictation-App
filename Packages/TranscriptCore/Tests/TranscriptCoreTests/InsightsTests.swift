import XCTest
@testable import TranscriptCore

final class InsightsRequestTests: XCTestCase {
    private func session() -> TranscriptSession {
        var s = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Welcome everyone, I'm Dana.", 1, 3))
        s.insert(speech("Today we cover the budget.", 3.5, 5))
        s.insert(.speakerChange(SpeakerChange(at: at(10))))
        s.insert(speech("Thanks Dana, quick question.", 11, 13))
        s.insert(.photo(PhotoAttachment(takenAt: at(20), fileName: "a.jpg", source: .camera)))
        s.insert(.gap(AudioGap(start: at(30), end: at(40), reason: "Phone call")))
        s.insert(speech("We're back.", 41, 42))
        s.endedAt = at(60)
        return s
    }

    private func bodyJSON(_ request: InsightsRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    func testNumberedTranscriptAndParagraphStarts() throws {
        let request = try InsightsRequest(session: session(), timeZone: utc)
        XCTAssertEqual(request.transcriptText, """
        [P1 14:00] Welcome everyone, I'm Dana. Today we cover the budget.
        — New speaker —
        [P2 14:00] Thanks Dana, quick question.
        [Photo taken 14:00]
        [No audio 14:00–14:00]
        [P3 14:00] We're back.
        """)
        XCTAssertEqual(request.paragraphStarts, [at(1), at(11), at(41)])
    }

    func testRequestBodyForOpus() throws {
        let request = try InsightsRequest(session: session(), model: .opus, timeZone: utc)
        let json = try bodyJSON(request)
        XCTAssertEqual(json["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["fallbacks"] as? String, "default")
        XCTAssertNil(json["thinking"], "Opus 5.5 thinks adaptively by default; disabling it is a 400")
        XCTAssertNil(json["temperature"])
        let output = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "medium")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertTrue((messages[0]["content"] as? String)?.contains("[P2 14:00] Thanks Dana") == true)
        XCTAssertEqual(request.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertEqual(request.headers["anthropic-version"], "2026-10-21")
    }

    func testHaikuHasNoServerFallback() throws {
        let request = try InsightsRequest(session: session(), model: .haiku, timeZone: utc)
        XCTAssertNil(try bodyJSON(request)["fallbacks"])
        XCTAssertNil(request.headers["anthropic-beta"])
    }

    func testEmptyTranscriptThrows() {
        let empty = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        XCTAssertThrowsError(try InsightsRequest(session: empty)) { error in
            XCTAssertEqual(error as? InsightsRequest.BuildError, .emptyTranscript)
        }
    }

    func testCostEstimate() throws {
        let request = try InsightsRequest(session: session(), model: .opus, timeZone: utc)
        XCTAssertGreaterThan(request.estimatedInputTokens, 0)
        // Output dominates for a tiny transcript: 8k * $20/M = $0.16.
        XCTAssertEqual(request.estimatedCost, 0.16, accuracy: 0.02)
        XCTAssertEqual(ClaudeModel.opus.cost(inputTokens: 1_000_000, outputTokens: 0), 4.0, accuracy: 0.0001)
        XCTAssertEqual(TokenEstimate.tokens(for: "我们开会"), 4)
        XCTAssertEqual(TokenEstimate.tokens(for: "abcdefg"), 2)
        XCTAssertEqual(ClaudePricing.cost(modelID: "claude-opus-4-8", inputTokens: 1_000_000, outputTokens: 0), 5)
        XCTAssertNil(ClaudePricing.cost(modelID: "unknown", inputTokens: 1, outputTokens: 1))
        
    }
}

final class ClaudeStreamTests: XCTestCase {
    private func feed(_ sse: String) -> ClaudeStreamAccumulator {
        var acc = ClaudeStreamAccumulator()
        for line in sse.split(separator: "\n", omittingEmptySubsequences: false) {
            acc.consume(line: String(line))
        }
        return acc
    }

    func testAccumulatesTextAndUsageIgnoringThinking() throws {
        let acc = feed("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":1200,"cache_read_input_tokens":300,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"secret"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type":"ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\\"a\\":"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"1}"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":850}}

        event: message_stop
        data: {"type":"message_stop"}
        """)
        XCTAssertEqual(try acc.finalText(), #"{"a":1}"#)
        XCTAssertEqual(acc.model, "claude-opus-5-5")
        XCTAssertEqual(acc.inputTokens, 1500)
        XCTAssertEqual(acc.outputTokens, 850)
    }

    func testRefusal() {
        let acc = feed("""
        data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10}}}
        data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}}
        data: {"type":"message_stop"}
        """)
        XCTAssertThrowsError(try acc.finalText()) { error in
            XCTAssertEqual(error as? ClaudeAPIError, .refusal(category: "cyber"))
        }
    }

    func testMaxTokensIsTruncated() {
        let acc = feed("""
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"{"}}
        data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}
        """)
        XCTAssertThrowsError(try acc.finalText()) { XCTAssertEqual($0 as? ClaudeAPIError, .truncated) }
    }

    func testStreamErrorEvent() {
        let acc = feed("""
        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
        """)
        XCTAssertThrowsError(try acc.finalText()) { error in
            let apiError = error as? ClaudeAPIError
            XCTAssertEqual(apiError, .http(status: 529, type: "overloaded_error", message: "Overloaded"))
            XCTAssertEqual(apiError?.isRetryable, true)
        }
    }

    func testStreamCutOffEarly() {
        let acc = feed(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"{"}}"#)
        XCTAssertThrowsError(try acc.finalText())
    }

    func testErrorBodyParsingAndMessages() {
        let body = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        let error = ClaudeAPIError.fromResponse(status: 401, body: body)
        XCTAssertEqual(error, .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
        XCTAssertFalse(error.isRetryable)
        XCTAssertEqual(error.errorDescription, "The Claude API key was rejected. Check it in Settings.")
        XCTAssertTrue(ClaudeAPIError.fromResponse(status: 503, body: Data()).isRetryable)
    }
}

final class InsightsParserTests: XCTestCase {
    func testParsesAndAnchorsTurnsToTime() throws {
        var s = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Hi, I'm Dana.", 1, 2))
        s.insert(speech("Question from me.", 10, 11))
        s.insert(speech("Answer.", 20, 21))
        let request = try InsightsRequest(session: s, timeZone: utc)
        let json = """
        {"title":" Budget review ","summary":"Dana presented.","key_points":["One",""],"action_items":[],
         "speakers":[{"label":"Dana","description":"Presenter"},{"label":"Audience member 1","description":"Asked"}],
         "speaker_turns":[{"paragraph":3,"speaker":"Dana"},{"paragraph":1,"speaker":"Dana"},
                          {"paragraph":2,"speaker":"Audience member 1"},{"paragraph":99,"speaker":"Ghost"}]}
        """
        let insights = try InsightsResponseParser.parse(json, request: request, model: "claude-opus-5-5", inputTokens: 5, outputTokens: 7, now: t0)
        XCTAssertEqual(insights.title, "Budget review")
        XCTAssertEqual(insights.keyPoints, ["One"])
        XCTAssertEqual(insights.speakers.map(\.label), ["Dana", "Audience member 1"])
        XCTAssertEqual(insights.speakerTurns, [
            SpeakerTurn(start: at(1), speaker: "Dana"),
            SpeakerTurn(start: at(10), speaker: "Audience member 1"),
            SpeakerTurn(start: at(20), speaker: "Dana"),
        ])
        XCTAssertEqual(insights.speaker(at: at(15)), "Audience member 1")
        XCTAssertNil(insights.speaker(at: t0))
        XCTAssertEqual(insights.inputTokens, 5)

        // Survives a save/load round trip on the session.
        s.insights = insights
        let store = FileSessionStore(rootDirectory: try makeTempDirectory())
        try store.save(s)
        XCTAssertEqual(try store.load(id: s.id).insights, insights)
    }

    func testInvalidJSON() throws {
        var s = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Hi.", 1, 2))
        let request = try InsightsRequest(session: s)
        XCTAssertThrowsError(try InsightsResponseParser.parse("not json", request: request))
    }
}

final class InsightsPhotoTests: XCTestCase {
    private func sessionWithPhotos() -> (TranscriptSession, PhotoAttachment, PhotoAttachment, PhotoAttachment) {
        var s = TranscriptSession(localeIdentifier: "en-US", startedAt: t0)
        s.insert(speech("Here is the budget slide.", 1, 3))
        let p1 = PhotoAttachment(takenAt: at(5), fileName: "a.jpg", source: .camera)
        let p2 = PhotoAttachment(takenAt: at(20), fileName: "b.jpg", source: .camera)
        let unsent = PhotoAttachment(takenAt: at(30), fileName: "c.jpg", source: .photoLibrary)
        s.insert(.photo(p1))
        s.insert(.photo(p2))
        s.insert(.photo(unsent))
        s.insert(speech("Next topic.", 40, 41))
        s.endedAt = at(60)
        return (s, p1, p2, unsent)
    }

    func testPhotosAreLabelledAttachedAndNumberedInTranscript() throws {
        let (s, p1, p2, _) = sessionWithPhotos()
        let photos = [
            InsightsPhoto(id: p2.id, takenAt: p2.takenAt, jpegData: Data([2]), pixelWidth: 1568, pixelHeight: 1176),
            InsightsPhoto(id: p1.id, takenAt: p1.takenAt, jpegData: Data([1]), pixelWidth: 1000, pixelHeight: 750),
            // Not part of the session: ignored.
            InsightsPhoto(id: UUID(), takenAt: at(50), jpegData: Data([9]), pixelWidth: 10, pixelHeight: 10),
        ]
        let request = try InsightsRequest(session: s, timeZone: utc, photos: photos)
        XCTAssertEqual(request.photoIDs, [p1.id, p2.id])
        XCTAssertTrue(request.transcriptText.contains("[Photo 1 taken 14:00]"), request.transcriptText)
        XCTAssertTrue(request.transcriptText.contains("[Photo 2 taken 14:00]"), request.transcriptText)
        XCTAssertTrue(request.transcriptText.contains("[Photo taken 14:00]"), "the photo that wasn't sent keeps a plain marker")
        // 1000x750 → 36×27 patches; 1568x1176 → 56×42 patches.
        XCTAssertEqual(request.photoTokens, 972 + 2352)
        XCTAssertGreaterThan(request.estimatedInputTokens, request.photoTokens)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 5)
        XCTAssertEqual(content[0]["text"] as? String, "Photo 1 (taken 14:00):")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, Data([1]).base64EncodedString())
        XCTAssertEqual(content[2]["text"] as? String, "Photo 2 (taken 14:00):")
        XCTAssertEqual(content[4]["type"] as? String, "text")
        XCTAssertTrue((content[4]["text"] as? String)?.contains("photo(s) above") == true)
    }

    func testTooManyPhotosAreSpreadEvenly() {
        XCTAssertEqual(InsightsRequest.spread(Array(0..<10), limit: 4), [0, 3, 6, 9])
        XCTAssertEqual(InsightsRequest.spread([1, 2], limit: 4), [1, 2])
        XCTAssertEqual(InsightsRequest.spread(Array(0..<100), limit: InsightsRequest.maxPhotos).count, InsightsRequest.maxPhotos)
    }

    func testPhotoNotesAreParsedAndExported() throws {
        var (s, p1, _, _) = sessionWithPhotos()
        let photo = InsightsPhoto(id: p1.id, takenAt: p1.takenAt, jpegData: Data([1]), pixelWidth: 100, pixelHeight: 100)
        let request = try InsightsRequest(session: s, timeZone: utc, photos: [photo])
        let json = """
        {"title":"T","summary":"S","key_points":[],"action_items":[],"speakers":[],"speaker_turns":[],
         "photo_notes":[{"photo":1,"description":"Q3 budget slide"},{"photo":7,"description":"ghost"}]}
        """
        let insights = try InsightsResponseParser.parse(json, request: request, now: t0)
        XCTAssertEqual(insights.photoNotes, [PhotoNote(photoID: p1.id, text: "Q3 budget slide")])
        XCTAssertEqual(insights.note(forPhoto: p1.id), "Q3 budget slide")

        s.insights = insights
        let text = TranscriptExporter.plainText(for: s, options: ExportOptions(timeZone: utc))
        XCTAssertTrue(text.contains("[14:00] 📷 Photo — Q3 budget slide"), text)
        let md = TranscriptExporter.markdown(for: s, options: ExportOptions(timeZone: utc))
        XCTAssertTrue(md.contains("*Q3 budget slide*"), md)
    }

    func testOlderInsightsWithoutPhotoNotesStillDecode() throws {
        let json = #"{"title":"T","summary":"S","keyPoints":[],"actionItems":[],"speakers":[],"speakerTurns":[],"model":"m","generatedAt":0}"#
        let decoded = try JSONDecoder().decode(SessionInsights.self, from: Data(json.utf8))
        XCTAssertNil(decoded.photoNotes)
    }
}
