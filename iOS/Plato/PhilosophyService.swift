//
//  PhilosophyService.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
// /Users/danielriaz/Projects/Plato/iOS/Plato/PhilosophyService.swift

import Foundation

// MARK: - API Models
struct OpenAIMessage: Codable {
    let role: String
    let content: String
}

struct OpenAIRequest: Codable {
    let model: String
    let messages: [OpenAIMessage]
    let maxTokens: Int
    let temperature: Double
    
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
    }
}

struct OpenAIChoice: Codable {
    let message: OpenAIMessage
}

struct OpenAIResponse: Codable {
    let choices: [OpenAIChoice]
}

// MARK: - Philosophy Service
@MainActor
class PhilosophyService: ObservableObject {
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    
    // Stoic system prompt optimized for concise, conversational responses
    private let systemPrompt = """
    You are a wise Stoic philosopher and mentor. Draw from the teachings of Marcus Aurelius, Epictetus, and Seneca. 

    IMPORTANT: Keep responses concise and conversational - aim for 2-3 sentences maximum. Focus on ONE key insight rather than multiple concepts. Provide practical wisdom that can be immediately applied.

    Style guidelines:
    - Be direct and profound, not lengthy
    - Give one powerful insight rather than lists
    - Use simple, clear language
    - End with a brief, actionable suggestion when appropriate
    - Avoid bullet points, numbered lists, or multiple concepts
    - Speak as if having a personal conversation, not giving a lecture

    Remember: Brevity is the soul of wisdom. One profound truth is better than five scattered thoughts.
    """
    
    init() {
        self.apiKey = ConfigManager.shared.openAIAPIKey
    }
    
    func getPhilosophicalResponse(for question: String, conversationHistory: [Message] = []) async throws -> String {
        guard !apiKey.isEmpty else {
            throw PhilosophyError.missingAPIKey
        }
        
        // Build conversation messages
        var messages: [OpenAIMessage] = [
            OpenAIMessage(role: "system", content: systemPrompt)
        ]
        
        // Add conversation history
        for message in conversationHistory {
            messages.append(OpenAIMessage(
                role: message.isUser ? "user" : "assistant",
                content: message.text
            ))
        }
        
        // Add current question
        messages.append(OpenAIMessage(role: "user", content: question))
        
        // Create request with settings optimized for concise responses
        let request = OpenAIRequest(
            model: "gpt-4o-mini",
            messages: messages,
            maxTokens: 150, // Reduced from 500 to encourage brevity
            temperature: 0.7
        )
        
        // Make API call
        let url = URL(string: baseURL)!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw PhilosophyError.encodingError
        }
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PhilosophyError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw PhilosophyError.apiError(httpResponse.statusCode)
        }
        
        do {
            let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            guard let firstChoice = openAIResponse.choices.first else {
                throw PhilosophyError.noResponse
            }
            return firstChoice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw PhilosophyError.decodingError
        }
    }
    
    // Convenience method for quick responses without history
    func getQuickResponse(for question: String) async throws -> String {
        return try await getPhilosophicalResponse(for: question, conversationHistory: [])
    }
}

// MARK: - Error Types
enum PhilosophyError: LocalizedError {
    case missingAPIKey
    case encodingError
    case invalidResponse
    case apiError(Int)
    case noResponse
    case decodingError
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is missing. Please configure your API key."
        case .encodingError:
            return "Failed to encode the request."
        case .invalidResponse:
            return "Invalid response from server."
        case .apiError(let code):
            return "API Error: \(code). Check your API key and quota."
        case .noResponse:
            return "No response received from AI."
        case .decodingError:
            return "Failed to decode the response."
        }
    }
}

// MARK: - Message Model (matches your existing structure)
struct Message: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let timestamp = Date()
}
