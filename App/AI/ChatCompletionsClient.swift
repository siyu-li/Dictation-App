import Foundation
import TranscriptCore

/// Sends a `ChatCompletionsRequest` (ChatGPT, Gemini, Qwen via OpenRouter)
/// and reads the streamed answer. Retries rate limits, overload and network
/// failures only before the answer starts (a retry after that is billed again).
struct ChatCompletionsClient: Sendable {
    var maxRetries = 2

    func send(
        _ request: ChatCompletionsRequest,
        apiKey: String,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> ChatCompletionStreamAccumulator {
        var attempt = 0
        while true {
            do {
                return try await sendOnce(request, apiKey: apiKey, progress: progress)
            } catch let error as AIServiceError where error.isRetryable && attempt < maxRetries {
                attempt += 1
                try await Task.sleep(for: .seconds(5 * attempt))
            }
        }
    }

    private func sendOnce(
        _ request: ChatCompletionsRequest,
        apiKey: String,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> ChatCompletionStreamAccumulator {
        var urlRequest = URLRequest(url: request.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = request.body

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch {
            throw AIServiceError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64_000 { break }
            }
            throw AIServiceError.fromResponse(status: http.statusCode, body: body)
        }

        var accumulator = ChatCompletionStreamAccumulator()
        do {
            for try await line in bytes.lines {
                accumulator.consume(line: line)
                progress(accumulator.text.count)
            }
        } catch {
            throw AIServiceError.streamInterrupted(error.localizedDescription)
        }
        if let streamError = accumulator.streamError {
            throw AIServiceError.streamInterrupted(streamError.errorDescription ?? "server error")
        }
        return accumulator
    }
}
