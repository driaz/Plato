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
    private let maxTokens = ConfigManager.shared.llmMaxTokens  // referencing the plist MaxTokens Count

    
    // Stoic system prompt (unchanged; trimmed whitespace)
    
    private var systemPrompt: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        let currentDate = formatter.string(from: Date())
        
        return """
        Today is \(currentDate).
        
        You are Plato, a warm and wise scholar with deep knowledge across the humanities. While grounded in Stoic philosophy (Marcus Aurelius, Epictetus, Seneca), your wisdom spans:

        • Philosophy: From the ancients through moderns
        • Literature: The great storytellers across cultures
        • History: Rise and fall of civilizations
        • Economics & Society: How money, power, and human nature intersect
        • Human Nature: Psychology, mythology, art

        Your gift: Making profound ideas practical and connecting them to how we should live today.

        CRITICAL INSTRUCTIONS FOR CURRENT INFORMATION:
        ============================================
        When you see "CURRENT WEB SEARCH RESULTS" or "Recent search results" in a message:
        - These are REAL, CURRENT facts that have been automatically retrieved for you
        - You MUST use the specific numbers and facts from these search results
        - DO NOT make up any data - only use what's explicitly provided
        - DO NOT say "I'll check" or "Let me search" - the search is already done
        - Present the facts from the search results first, then add philosophical insight
        
        If NO search results are provided but someone asks about current events:
        - Be honest that you don't have current information
        - Offer philosophical perspective on the topic without specific numbers
        
        RESPONSE CONSTRAINTS:
        - Maximum \(maxTokens) tokens (enough for complete thoughts with facts and philosophy)
        - When presenting search results: state facts clearly first, then add philosophical insight
        - Prioritize accuracy over philosophy if running low on space
        - Be conversational and natural
        
        Remember: When search results appear in the message, they are real and current. Use them.
        Brevity is wisdom. Accuracy is virtue.
        """
    }

    // Also increase token limit for search responses in Config.plist:
    // <key>LLM_MaxTokens</key>
    // <integer>300</integer>  <!-- Increase from 150 -->
    
    init() {
        self.apiKey = ConfigManager.shared.openAIAPIKey
        Logger.shared.log("PhilosophyService initialized", category: .llm, level: .info)
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
        guard !apiKey.isEmpty else {
            Logger.shared.log("Missing OpenAI API key", category: .llm, level: .error)
            throw PhilosophyError.missingAPIKey
        }
        
        // Start LLM flow
        let flowId = Logger.shared.startFlow("llm_response")
        Logger.shared.startTimer("llm_streaming")
        
        Logger.shared.log("Starting stream for: '\(question.prefix(50))...'", category: .llm, level: .info)
        Logger.shared.log("History: \(history.count) messages", category: .llm, level: .debug)
        
        // Build payload
        let payload = try makeChatPayload(
            question: question,
            history: history,
            stream: true
        )
        
        let req = try makeURLRequest(with: payload)
        
        // Network bytes stream
        Logger.shared.startTimer("llm_first_token")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        try validate(response: response)
        
        var full = ""
        var sentenceBuffer = ""
        var lastSentenceEnd = 0
        var tokenCount = 0
        var sentenceCount = 0
        var firstTokenReceived = false
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let raw = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == "[DONE]" {
                Logger.shared.log("Stream complete: \(tokenCount) tokens, \(sentenceCount) sentences", category: .llm, level: .info)
                break
            }
            
            guard let data = raw.data(using: .utf8) else { continue }
            do {
                let chunk = try JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                    
                    // Track first token
                    if !firstTokenReceived {
                        firstTokenReceived = true
                        Logger.shared.endTimer("llm_first_token")
                        Logger.shared.log("First token received", category: .llm, level: .debug)
                    }
                    
                    tokenCount += 1
                    full += delta
                    sentenceBuffer += delta
                    await onDelta(delta)
                    
                    // Check for complete sentences
                    if let completeSentence = detectCompleteSentence(in: sentenceBuffer) {
                        sentenceCount += 1
                        Logger.shared.log("Sentence \(sentenceCount) detected: '\(completeSentence.prefix(30))...'", category: .llm, level: .debug)
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
            sentenceCount += 1
            Logger.shared.log("Final sentence (\(sentenceCount)): '\(remaining.prefix(30))...'", category: .llm, level: .debug)
            await onSentence(remaining)
        }
        
        // Complete flow
        Logger.shared.endTimer("llm_streaming")
        Logger.shared.endFlow(flowId, name: "llm_response")
        
        let finalResponse = full.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.shared.log("Response complete: \(finalResponse.count) chars, \(sentenceCount) sentences", category: .llm, level: .info)
        
//        return full.trimmingCharacters(in: .whitespacesAndNewlines)
        return finalResponse

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
            Logger.shared.log("Missing OpenAI API key", category: .llm, level: .error)
            throw PhilosophyError.missingAPIKey
        }
        
        Logger.shared.log("Blocking LLM request for: '\(question.prefix(50))...'", category: .llm, level: .info)
        Logger.shared.startTimer("llm_blocking")
        
        let payload = try makeChatPayload(
            question: question,
            history: conversationHistory,
            stream: false
        )
        let req = try makeURLRequest(with: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response)
        let result = try decodeBlockingContent(data: data)

        Logger.shared.endTimer("llm_blocking")
        Logger.shared.log("Blocking response: \(result.count) chars", category: .llm, level: .info)
        
        return result
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
            Logger.shared.log("Invalid response type", category: .llm, level: .error)
            throw PhilosophyError.invalidResponse
        }
        guard http.statusCode == 200 else {
            Logger.shared.log("API error: HTTP \(http.statusCode)", category: .llm, level: .error)
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
                Logger.shared.log("No choices in response", category: .llm, level: .error)
                throw PhilosophyError.noResponse
            }
            return first.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Logger.shared.log("Failed to decode response: \(error)", category: .llm, level: .error)
            throw PhilosophyError.decodingError
        }
    }
}

// Add this extension to PhilosophyService.swift:
extension PhilosophyService {
    /// Determines if a question needs web search
     func needsWebSearch(_ question: String) -> Bool {
        let searchTriggers = [
            // Time-based triggers
            "happening", "today", "yesterday", "this week", "this month",
            "current", "latest", "recent", "recently", "right now",
            
            // News/event triggers
            "news", "update", "election", "conflict", "crisis",
            "stock market", "markets", "economy",
            
            // Question patterns
            "what happened", "what's going on", "tell me about the",
            "what is the situation", "what's the latest"
        ]
        
        let lowercased = question.lowercased()
        let needsSearch = searchTriggers.contains { lowercased.contains($0) }

        if needsSearch {
            Logger.shared.log("Question needs web search: detected trigger words", category: .network, level: .debug)
        }
        return needsSearch
    }
    
    /// Extract search query from user question
    private func extractSearchQuery(from question: String) -> String {
        // Remove conversational prefixes
        var query = question
        let prefixes = [
            "hey plato", "hey blade", "plato", "can you tell me",
            "tell me about", "what do you know about", "search for",
            "find information about", "look up", "what happened"
        ]
        
        var lowercased = query.lowercased()
        for prefix in prefixes {
            if lowercased.hasPrefix(prefix) {
                query = String(query.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lowercased = query.lowercased()
            }
        }
        
        // Handle relative time references
        if lowercased.contains("last friday") || lowercased.contains("on friday") {
            query = query.replacingOccurrences(of: "last Friday", with: "Friday", options: .caseInsensitive)
            query = query.replacingOccurrences(of: "on Friday", with: "Friday", options: .caseInsensitive)
            // Add current context for recency
            query += " recent"
        }
        
        // Clean up question marks and extra words
        query = query.replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        Logger.shared.log("Search query extracted: '\(query)'", category: .network, level: .debug)
        
        return query
    }
    
    /// Stream response with optional web search
    // In PhilosophyService.swift, UPDATE your existing streamResponseWithSearch method:

    func streamResponseWithSearch(
        question: String,
        history: [ChatMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onSentence: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        
        // Check if we need current information
        if needsWebSearch(question) {
            
            // Informing the user of a short delay for information retrieval
            await ContentView.sharedElevenLabs?.speak("Looking that up, one moment...")
            
            // TRY PERPLEXITY FIRST (if available)
            if cfg.hasPerplexityAPI {
                Logger.shared.log("Using Perplexity for: '\(question.prefix(50))...'", category: .network, level: .info)
                
                do {
                    Logger.shared.startTimer("perplexity_search")
                    
                    // Get answer from Perplexity (it searches and synthesizes)
                    let answer = try await PerplexityService.shared.getAnswer(for: question)
                    
                    Logger.shared.endTimer("perplexity_search")
                    Logger.shared.log("Perplexity returned: \(answer.text.prefix(100))...", category: .network, level: .info)
                    
                    // Build enhanced question with Perplexity's answer
                    let enhancedQuestion = """
                    The user asked: "\(question)"
                    
                    CURRENT INFORMATION (from real-time web search):
                    \(answer.text)
                    
                    Instructions:
                    1. Use the specific facts and numbers provided above
                    2. Add a brief Stoic philosophical perspective
                    3. Keep your total response to 2-3 sentences
                    """
                    
                    // Stream response with enhanced context
                    return try await streamResponse(
                        question: enhancedQuestion,
                        history: history,
                        onDelta: onDelta,
                        onSentence: onSentence
                    )
                    
                } catch {
                    Logger.shared.log("Perplexity failed: \(error.localizedDescription), falling back to Brave", category: .network, level: .error)
                    // Fall through to Brave
                }
            }
            
            // FALLBACK TO BRAVE if Perplexity not available or failed
            if cfg.hasBraveSearch {
                Logger.shared.log("Using Brave Search for: '\(question.prefix(50))...'", category: .network, level: .info)
                
                // ... rest of your existing Brave search code ...
                do {
                    let searchQuery = extractSearchQuery(from: question)
                    Logger.shared.startTimer("web_search")
                    
                    let searchResults = try await WebSearchService.shared.search(searchQuery, limit: 4)
                    
                    Logger.shared.endTimer("web_search")
                    Logger.shared.log("Search returned \(searchResults.count) results", category: .network, level: .info)
                    
                    let searchContext = WebSearchService.shared.createSearchContext(
                        from: searchResults,
                        query: question
                    )
                    
                    // Build enhanced question with search context
                    let enhancedQuestion = """
                    The user asked: "\(question)"
                    
                    \(searchContext)
                    
                    IMPORTANT: Structure your response as:
                    1. Present the key facts from search results clearly and accurately
                    2. Add ONE brief philosophical observation (max 1 sentence)
                    3. If running out of tokens, prioritize completing the facts over philosophy
                    """
                    
                    return try await streamResponse(
                        question: enhancedQuestion,
                        history: history,
                        onDelta: onDelta,
                        onSentence: onSentence
                    )
                    
                } catch {
                    Logger.shared.log("Search failed: \(error.localizedDescription)", category: .network, level: .error)
                    
                    // Add a note about search failure in response
                    let fallbackQuestion = question +
                        "\n\n[Note: Unable to search for current information, providing response based on general knowledge]"
                    
                    return try await streamResponse(
                        question: fallbackQuestion,
                        history: history,
                        onDelta: onDelta,
                        onSentence: onSentence
                    )
                }
            }
        }
        
        // Regular philosophical response without search
        if !cfg.hasBraveSearch && !cfg.hasPerplexityAPI && needsWebSearch(question) {
            Logger.shared.log("Search needed but no API configured", category: .network, level: .warning)
        }
        
        return try await streamResponse(
            question: question,
            history: history,
            onDelta: onDelta,
            onSentence: onSentence
        )
    }
}
