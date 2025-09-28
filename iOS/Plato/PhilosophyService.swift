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
    let content: String?
    let tool_calls: [ToolCall]?
    let tool_call_id: String?
    
    init(role: String, content: String) {
        self.role = role
        self.content = content
        self.tool_calls = nil
        self.tool_call_id = nil
    }
    
    init(role: String, content: String?, tool_calls: [ToolCall]?, tool_call_id: String?) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }
    
    init(toolCallId: String, content: String) {
        self.role = "tool"
        self.content = content
        self.tool_calls = nil
        self.tool_call_id = toolCallId
    }
}

private struct ToolCall: Codable {
    let id: String
    let type: String
    let function: FunctionCall
}

private struct FunctionCall: Codable {
    let name: String
    let arguments: String
}

private struct Tool: Codable {
    let type: String
    let function: ToolFunction
}

private struct ToolFunction: Codable {
    let name: String
    let description: String
    let parameters: JSONValue
    
    init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parameters = JSONValue(parameters)
    }
}

// JSON encoding helper
private struct JSONValue: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { JSONValue($0) })
        } else if let array = value as? [Any] {
            try container.encode(array.map { JSONValue($0) })
        } else if let string = value as? String {
            try container.encode(string)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if value is NSNull {
            try container.encodeNil()
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: JSONValue].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([JSONValue].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }
}

private struct OpenAIChatRequest: Codable {
    let model: String
    let messages: [OpenAIChatMessage]
    let max_tokens: Int?
    let temperature: Double?
    let stream: Bool?
    let tools: [Tool]?
    let tool_choice: String?
}

// MARK: - OpenAI Wire Models (streaming response)
private struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { 
            let content: String?
            let tool_calls: [DeltaToolCall]?
        }
        let delta: Delta?
        let finish_reason: String?
    }
    let choices: [Choice]
}

private struct DeltaToolCall: Decodable {
    let index: Int?
    let id: String?
    let type: String?
    let function: DeltaFunctionCall?
}

private struct DeltaFunctionCall: Decodable {
    let name: String?
    let arguments: String?
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
        
        You are Alan, a warm and wise scholar with deep knowledge across the humanities. While grounded in Stoic philosophy (Marcus Aurelius, Epictetus, Seneca), your wisdom spans:

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
    
    // MARK: - Tool Definitions
    
    private var webSearchTool: Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: "web_search",
                description: "Search the web for current information, news, events, stock prices, or any real-time data. Use this when the user asks about recent events, current affairs, or any information that requires up-to-date knowledge.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "The search query to look up current information"
                        ]
                    ],
                    "required": ["query"]
                ]
            )
        )
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
        
        return try await streamWithToolCalls(
            question: question,
            history: history,
            onDelta: onDelta,
            onSentence: onSentence,
            flowId: flowId
        )
    }
    
    private func streamWithToolCalls(
        question: String? = nil,
        messages: [OpenAIChatMessage] = [],
        history: [ChatMessage] = [],
        onDelta: @escaping @MainActor (String) -> Void,
        onSentence: @escaping @MainActor (String) -> Void = { _ in },
        flowId: UUID
    ) async throws -> String {
        
        // Build payload
        let payload = try makeChatPayload(
            question: question,
            messages: messages,
            history: history,
            stream: true,
            includeTools: cfg.hasPerplexityAPI || cfg.hasBraveSearch
        )
        
        let req = try makeURLRequest(with: payload)
        
        // Network bytes stream
        Logger.shared.startTimer("llm_first_token")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        try validate(response: response)
        
        var full = ""
        var sentenceBuffer = ""
        var tokenCount = 0
        var sentenceCount = 0
        var firstTokenReceived = false
        
        // Tool call state
        var currentToolCalls: [String: (id: String, name: String, arguments: String)] = [:]
        
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
                let choice = chunk.choices.first
                
                // Handle tool calls
                if let toolCalls = choice?.delta?.tool_calls {
                    for toolCall in toolCalls {
                        let index = toolCall.index ?? 0
                        let indexKey = "\(index)"
                        
                        if let id = toolCall.id, let type = toolCall.type {
                            currentToolCalls[indexKey] = (id: id, name: "", arguments: "")
                        }
                        
                        if let function = toolCall.function {
                            if let name = function.name {
                                currentToolCalls[indexKey]?.name = name
                            }
                            if let args = function.arguments {
                                currentToolCalls[indexKey]?.arguments += args
                            }
                        }
                    }
                }
                
                // Handle regular content
                if let delta = choice?.delta?.content, !delta.isEmpty {
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
                        sentenceBuffer = String(sentenceBuffer.dropFirst(completeSentence.count))
                        sentenceBuffer = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                
                // Check if this is the end and we have tool calls to execute
                if let finishReason = choice?.finish_reason, finishReason == "tool_calls" {
                    Logger.shared.log("🤖 [Tool] Decision: web_search", category: .llm, level: .info)
                    return try await handleToolCalls(
                        toolCalls: currentToolCalls,
                        originalQuestion: question,
                        messages: messages,
                        history: history,
                        onDelta: onDelta,
                        onSentence: onSentence,
                        flowId: flowId
                    )
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
        
        // Log when tools were available but not used
        if cfg.hasPerplexityAPI || cfg.hasBraveSearch {
            Logger.shared.log("🤖 [Tool] Decision: direct response (no tools used)", category: .llm, level: .debug)
        }
        
        // Complete flow
        Logger.shared.endTimer("llm_streaming")
        Logger.shared.endFlow(flowId, name: "llm_response")
        
        let finalResponse = full.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.shared.log("Response complete: \(finalResponse.count) chars, \(sentenceCount) sentences", category: .llm, level: .info)
        
        return finalResponse
    }
    
    private func handleToolCalls(
        toolCalls: [String: (id: String, name: String, arguments: String)],
        originalQuestion: String?,
        messages: [OpenAIChatMessage],
        history: [ChatMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onSentence: @escaping @MainActor (String) -> Void,
        flowId: UUID
    ) async throws -> String {
        
        // Notify user that we're searching
        await ContentView.sharedElevenLabs?.speak("Let me search for the latest information.")
        
        var updatedMessages = messages.isEmpty ? buildMessages(question: originalQuestion, history: history) : messages
        
        // Add assistant message with tool calls
        var assistantMessage: OpenAIChatMessage
        var toolCallsArray: [ToolCall] = []
        
        for (_, toolCall) in toolCalls {
            let functionCall = FunctionCall(name: toolCall.name, arguments: toolCall.arguments)
            let toolCallObj = ToolCall(id: toolCall.id, type: "function", function: functionCall)
            toolCallsArray.append(toolCallObj)
        }
        
        // Create assistant message with tool calls
        assistantMessage = OpenAIChatMessage(
            role: "assistant", 
            content: nil, 
            tool_calls: toolCallsArray, 
            tool_call_id: nil
        )
        updatedMessages.append(assistantMessage)
        
        // Execute tool calls and add results
        for (_, toolCall) in toolCalls {
            if toolCall.name == "web_search" {
                let searchResult = try await executeWebSearch(arguments: toolCall.arguments)
                let toolResultMessage = OpenAIChatMessage(toolCallId: toolCall.id, content: searchResult)
                updatedMessages.append(toolResultMessage)
            }
        }
        
        // Make another call to get the final response
        return try await streamWithToolCalls(
            messages: updatedMessages,
            onDelta: onDelta,
            onSentence: onSentence,
            flowId: flowId
        )
    }
    
    private func buildMessages(question: String?, history: [ChatMessage]) -> [OpenAIChatMessage] {
        var msgs: [OpenAIChatMessage] = []
        
        // System
        msgs.append(OpenAIChatMessage(role: "system", content: systemPrompt))
        
        // History
        for m in history {
            guard m.role != .system else { continue }
            msgs.append(OpenAIChatMessage(role: m.role.rawValue, content: m.text))
        }
        
        // Current user turn
        if let question = question {
            msgs.append(OpenAIChatMessage(role: "user", content: question))
        }
        
        return msgs
    }
    
    private func executeWebSearch(arguments: String) async throws -> String {
        struct SearchArgs: Decodable {
            let query: String
        }
        
        guard let data = arguments.data(using: .utf8) else {
            throw PhilosophyError.decodingError
        }
        
        let searchArgs = try JSONDecoder().decode(SearchArgs.self, from: data)
        Logger.shared.log("Executing web search for: '\(searchArgs.query)'", category: .network, level: .info)
        
        // Try Perplexity first if available
        if cfg.hasPerplexityAPI {
            do {
                Logger.shared.startTimer("perplexity_search")
                let answer = try await PerplexityService.shared.getAnswer(for: searchArgs.query)
                Logger.shared.endTimer("perplexity_search")
                Logger.shared.log("Perplexity returned: \(answer.text.prefix(100))...", category: .network, level: .info)
                return answer.text
            } catch {
                Logger.shared.log("Perplexity failed: \(error.localizedDescription), trying Brave", category: .network, level: .error)
            }
        }
        
        // Fall back to Brave search if available
        if cfg.hasBraveSearch {
            do {
                Logger.shared.startTimer("brave_search")
                let searchResults = try await WebSearchService.shared.search(searchArgs.query, limit: 4)
                Logger.shared.endTimer("brave_search")
                Logger.shared.log("Brave search returned \(searchResults.count) results", category: .network, level: .info)
                
                let searchContext = WebSearchService.shared.createSearchContext(
                    from: searchResults,
                    query: searchArgs.query
                )
                return searchContext
            } catch {
                Logger.shared.log("Brave search failed: \(error.localizedDescription)", category: .network, level: .error)
                throw error
            }
        }
        
        throw PhilosophyError.noResponse
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
        
        for (ender, _) in sentenceEnders {
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
        question: String? = nil,
        messages: [OpenAIChatMessage] = [],
        history: [ChatMessage] = [],
        stream: Bool,
        includeTools: Bool = true
    ) throws -> Data {
        
        var msgs: [OpenAIChatMessage] = []
        
        if !messages.isEmpty {
            msgs = messages
        } else {
            // System
            msgs.append(OpenAIChatMessage(role: "system", content: systemPrompt))
            
            // History (user + assistant only; skip system duplicates)
            for m in history {
                guard m.role != .system else { continue }
                msgs.append(OpenAIChatMessage(role: m.role.rawValue, content: m.text))
            }
            
            // Current user turn
            if let question = question {
                msgs.append(OpenAIChatMessage(role: "user", content: question))
            }
        }
        
        let tools = includeTools && (cfg.hasPerplexityAPI || cfg.hasBraveSearch) ? [webSearchTool] : nil
        
        let req = OpenAIChatRequest(
            model: cfg.llmModel,
            messages: msgs,
            max_tokens: cfg.llmMaxTokens,
            temperature: cfg.llmTemperature,
            stream: stream,
            tools: tools,
            tool_choice: nil
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
            return first.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            Logger.shared.log("Failed to decode response: \(error)", category: .llm, level: .error)
            throw PhilosophyError.decodingError
        }
    }
}

