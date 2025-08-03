//
//  PhilosophyService.swift
//  Plato
//
//  Phase 1: Streaming Chat Completions + Unified ChatMessage model
//  Phase 2: Chunked TTS - Added sentence detection
//

import Foundation

// MARK: - OpenAI Wire Models (request)
private struct OpenAIChatMessage: Codable {
    let role: String
    let content: String
}

private struct OpenAIChatRequest: Codable {
    let model: String
    let messages: [OpenAIChatMessage]
    let max_tokens: Int?
    let temperature: Double?
    let stream: Bool?
}

// MARK: - OpenAI Wire Models (streaming response)
private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
        let finish_reason: String?
    }
    let choices: [Choice]
}

enum PhilosophyError: LocalizedError {
    case missingAPIKey
    case encodingError
    case invalidResponse
    case apiError(Int)
    case noResponse
    case decodingError
    case streamAborted
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "OpenAI API key is missing."
        case .encodingError: return "Failed to encode the request."
        case .invalidResponse: return "Invalid response from server."
        case .apiError(let code): return "API Error: \(code)."
        case .noResponse: return "No response received from AI."
        case .decodingError: return "Failed to decode the response."
        case .streamAborted: return "Response stream was aborted."
        }
    }
}

/// Streams Stoic responses from OpenAI in near-real-time.
final class PhilosophyService: ObservableObject {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let cfg = ConfigManager.shared
    
    // Stoic system prompt (unchanged; trimmed whitespace)
    private let systemPrompt = """
    You are Plato, a warm and wise scholar with deep knowledge across the humanities. While grounded in Stoic philosophy (Marcus Aurelius, Epictetus, Seneca), your wisdom spans:

    • Philosophy: From the ancients (Aristotle, Plato) through Renaissance (Machiavelli, Montaigne), Enlightenment (Kant, Hume, Rousseau), to moderns (Rawls, Camus, Sartre, de Beauvoir, Girard)
    • Literature: The great storytellers - Shakespeare, Dickens, Dostoevsky, Tolstoy, Melville, Hemingway, Steinbeck, Faulkner, McCarthy, Bradbury, Woolf, Morrison, García Márquez
    • History: Rise and fall of civilizations, revolutions, wars, and the leaders who shaped them
    • Economics & Society: From Adam Smith to Keynes to behavioral economics; how money, power, and human nature intersect
    • Human Nature: Psychology, mythology, art - what drives us, inspires us, breaks us, and heals us

    Your gift: Making profound ideas practical. Whether discussing Raskolnikov's guilt or market bubbles, you connect it to how we should live today.

    IMPORTANT: Be concise and conversational—aim for 2-3 sentences max. Focus on ONE key insight. Reference great works and thinkers naturally, like a friend who's read everything but never lectures.

    Brevity is wisdom. One vivid truth beats five abstract thoughts.
    """
    
    init() {
        self.apiKey = ConfigManager.shared.openAIAPIKey
    }
    
    // MARK: - Public API
    
    /// Streaming variant with sentence detection.
    /// Calls `onDelta` with text fragments and `onSentence` when complete sentences are detected.
    /// Returns the final full response string when stream completes.
    func streamResponse(
        question: String,
        history: [ChatMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onSentence: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw PhilosophyError.missingAPIKey }
        
        // Build payload
        let payload = try makeChatPayload(
            question: question,
            history: history,
            stream: true
        )
        
        let req = try makeURLRequest(with: payload)
        
        // Network bytes stream
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        try validate(response: response)
        
        var full = ""
        var sentenceBuffer = ""
        var lastSentenceEnd = 0
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let raw = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == "[DONE]" { break }
            guard let data = raw.data(using: .utf8) else { continue }
            do {
                let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                    full += delta
                    sentenceBuffer += delta
                    await onDelta(delta)
                    
                    // Check for complete sentences
                    if let completeSentence = detectCompleteSentence(in: sentenceBuffer) {
                        await onSentence(completeSentence)
                        // Remove the detected sentence from buffer more safely
                        sentenceBuffer = String(sentenceBuffer.dropFirst(completeSentence.count))
                        sentenceBuffer = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                // ignore malformed partials; continue
            }
        }
        
        // Handle any remaining text as final sentence
        let remaining = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty && remaining.split(separator: " ").count >= 2 {
            await onSentence(remaining)
        }
        
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Backward compatibility - calls new method without sentence callback
    func streamResponse(
        question: String,
        history: [ChatMessage],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        try await streamResponse(
            question: question,
            history: history,
            onDelta: onDelta,
            onSentence: { _ in }
        )
    }
    
    /// Legacy blocking call (kept for fallback / debugging)
    func getPhilosophicalResponse(
        for question: String,
        conversationHistory: [ChatMessage] = []
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw PhilosophyError.missingAPIKey
        }
        let payload = try makeChatPayload(
            question: question,
            history: conversationHistory,
            stream: false
        )
        let req = try makeURLRequest(with: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response)
        return try decodeBlockingContent(data: data)
    }
    
    // MARK: - Sentence Detection
    
    /// Detects complete sentences in the buffer.
    /// Returns the complete sentence if found, nil otherwise.
    private func detectCompleteSentence(in buffer: String) -> String? {
        // Don't process very short buffers
        guard buffer.count > 10 else { return nil }
        
        // Look for sentence-ending punctuation
        let sentenceEnders: [(String, Int)] = [
            (".", 1), ("!", 1), ("?", 1),
            (":", 1), ("...", 3), (".\"", 2),
            ("!\"", 2), ("?\"", 2)
        ]
        
        for (ender, enderLength) in sentenceEnders {
            if let range = buffer.range(of: ender, options: .backwards) {
                // Check what comes after the punctuation
                let afterPunct = String(buffer[range.upperBound...])
                
                // Valid sentence if followed by space, newline, or end of buffer
                let isValidEnd = afterPunct.isEmpty ||
                                afterPunct.hasPrefix(" ") ||
                                afterPunct.hasPrefix("\n") ||
                                afterPunct.allSatisfy { $0.isWhitespace }
                
                if isValidEnd {
                    var sentence = String(buffer[..<range.upperBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Clean up markdown and formatting
                    sentence = cleanForTTS(sentence)
                    
                    // Minimum viable sentence (3+ words)
                    let wordCount = sentence.split(separator: " ").count
                    if wordCount >= 3 {
                        return sentence
                    }
                }
            }
        }
        
        // Check for very long buffer without punctuation (fallback)
        let words = buffer.split(separator: " ")
        if words.count > 20 {
            // Find a natural break point around 15 words
            let breakPoint = min(15, words.count - 1)
            let partial = words[0..<breakPoint].joined(separator: " ")
            return cleanForTTS(partial)
        }
        
        return nil
    }
    
    /// Cleans text for TTS (removes markdown, excessive formatting)
    private func cleanForTTS(_ text: String) -> String {
        var cleaned = text
        // Remove markdown
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
        cleaned = cleaned.replacingOccurrences(of: "*", with: "")
        cleaned = cleaned.replacingOccurrences(of: "_", with: "")
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")
        // Clean up whitespace
        cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }
    
    // MARK: - Request Builders
    
    private func makeChatPayload(
        question: String,
        history: [ChatMessage],
        stream: Bool
    ) throws -> Data {
        var msgs: [OpenAIChatMessage] = []
        // System
        msgs.append(OpenAIChatMessage(role: "system", content: systemPrompt))
        // History (user + assistant only; skip system duplicates)
        for m in history {
            guard m.role != .system else { continue }
            msgs.append(OpenAIChatMessage(role: m.role.rawValue, content: m.text))
        }
        // Current user turn
        msgs.append(OpenAIChatMessage(role: "user", content: question))
        
        let req = OpenAIChatRequest(
            model: cfg.llmModel,
            messages: msgs,
            max_tokens: cfg.llmMaxTokens,
            temperature: cfg.llmTemperature,
            stream: stream
        )
        do {
            return try JSONEncoder().encode(req)
        } catch {
            throw PhilosophyError.encodingError
        }
    }
    
    private func makeURLRequest(with body: Data) throws -> URLRequest {
        var r = URLRequest(url: baseURL)
        r.httpMethod = "POST"
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return r
    }
    
    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PhilosophyError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw PhilosophyError.apiError(http.statusCode)
        }
    }
    
    // MARK: - Blocking Decode
    
    private struct OpenAIBlockingChoice: Decodable {
        let message: OpenAIChatMessage
    }
    private struct OpenAIBlockingResponse: Decodable {
        let choices: [OpenAIBlockingChoice]
    }
    
    private func decodeBlockingContent(data: Data) throws -> String {
        do {
            let decoded = try JSONDecoder().decode(OpenAIBlockingResponse.self, from: data)
            guard let first = decoded.choices.first else {
                throw PhilosophyError.noResponse
            }
            return first.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw PhilosophyError.decodingError
        }
    }
}
