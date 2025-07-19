//
//  PhilosophyService.swift
//  Plato
//
//  Phase 1: Streaming Chat Completions + Unified ChatMessage model
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
    You are a wise Stoic philosopher and mentor named Plato. Draw from Marcus Aurelius, Epictetus, and Seneca.

    IMPORTANT: Be concise and conversational—aim for 2-3 sentences max. Focus on ONE key insight. Provide a practical, actionable takeaway when appropriate. Avoid bullet points or lists.

    Brevity is wisdom. One clear truth beats five scattered thoughts.
    """
    
    init() {
        self.apiKey = ConfigManager.shared.openAIAPIKey
    }
    
    // MARK: - Public API
    
    /// Streaming variant. Calls `onDelta` on main thread with text fragments.
    /// Returns the final full response string when stream completes.
    func streamResponse(
        question: String,
        history: [ChatMessage],
        onDelta: @escaping @MainActor (String) -> Void
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
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let raw = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == "[DONE]" { break }
            guard let data = raw.data(using: .utf8) else { continue }
            do {
                let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                    full += delta
                    await onDelta(delta)
                }
            } catch {
                // ignore malformed partials; continue
            }
        }
        
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
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

