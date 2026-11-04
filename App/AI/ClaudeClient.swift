import Foundation
import TranscriptCore

/// Sends an `InsightsRequest` to the Claude Messages API over HTTPS and reads
/// the streamed (SSE) answer. Retries rate limits, overload and network
/// failures a couple of times.
struct ClaudeClient: Sendable {
    var maxRetries = 2

    func send(
        _ request: InsightsRequest,
        apiKey: String,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> ClaudeStreamAccumulator {
        var attempt = 0
        while true {
            do {
                return try await sendOnce(request, apiKey: apiKey, progress: progress)
            } catch let error as ClaudeAPIError where error.isRetryable && attempt < maxRetries {
                attempt += 1
                try await Task.sleep(for: .seconds(5 * attempt))
            }
        }
    }

    private func sendOnce(
        _ request: InsightsRequest,
        apiKey: String,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> ClaudeStreamAccumulator {
        var urlRequest = URLRequest(url: InsightsRequest.endpoint)
        urlRequest.httpMethod = "POST"
        // Idle timeout between received bytes; the stream sends pings while
        // the model thinks.
        urlRequest.timeoutInterval = 300
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.httpBody = request.body

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch {
            throw ClaudeAPIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64_000 { break }
            }
            throw ClaudeAPIError.fromResponse(status: http.statusCode, body: body)
        }

        // From here on Claude has accepted the request, so failures are not
        // retried automatically: a retry would be billed again. The user can
        // tap Try again.
        var accumulator = ClaudeStreamAccumulator()
        do {
            for try await line in bytes.lines {
                accumulator.consume(line: line)
                progress(accumulator.text.count)
            }
        } catch {
            throw ClaudeAPIError.streamInterrupted(error.localizedDescription)
        }
        if let streamError = accumulator.streamError {
            throw ClaudeAPIError.streamInterrupted(streamError.errorDescription ?? "server error")
        }
        return accumulator
    }
}
