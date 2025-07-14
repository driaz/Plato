//
//  PhilosophyService.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//

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
    
    // Stoic system prompt matching your Python app
    private let systemPrompt = """
    You are a wise Stoic philosopher and mentor named Plato. Draw from the teachings of Marcus Aurelius, Epictetus, and Seneca. 
    Provide practical wisdom and guidance rooted in Stoic principles. Keep responses concise but profound, 
    helping users apply ancient wisdom to modern challenges.
    """
    
    init() {
        // TODO: Replace with your actual API key
        // For production, store this securely (Keychain, etc.)
        self.apiKey = "YOUR_OPENAI_API_KEY_HERE"
    }
    
    func getPhilosophicalResponse(for question: String, conversationHistory: [Message] = []) async throws -> String {
        guard !apiKey.isEmpty && apiKey != "YOUR_OPENAI_API_KEY_HERE" else {
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
        
        // Create request
        let request = OpenAIRequest(
            model: "gpt-4o-mini",
            messages: messages,
            maxTokens: 500,
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
