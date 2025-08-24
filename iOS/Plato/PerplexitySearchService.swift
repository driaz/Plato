// PerplexityService.swift
// Fixed version with proper error handling and access levels

import Foundation

final class PerplexityService {
    static let shared = PerplexityService()
    private let baseURL = "https://api.perplexity.ai/chat/completions"
    private let cfg = ConfigManager.shared
    
    private init() {}
    
    /// Get a web-grounded answer from Perplexity
    func getAnswer(for question: String) async throws -> PerplexityAnswer {
        guard cfg.hasPerplexityAPI else {
            throw SearchError.missingAPIKey
        }
        
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(cfg.perplexityAPIKey)", forHTTPHeaderField: "Authorization")
        
        // Use correct model name from current Perplexity docs
        let body: [String: Any] = [
            "model": "sonar",  // The basic web-search model 
            "messages": [
                [
                    "role": "user",
                    "content": question
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        Logger.shared.log("🔍 Perplexity query: '\(question)'", category: .network, level: .info)
        Logger.shared.log("📤 Request body: \(String(data: request.httpBody!, encoding: .utf8) ?? "nil")", category: .network, level: .debug)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Log the response for debugging
        if let httpResponse = response as? HTTPURLResponse {
            Logger.shared.log("📥 Response status: \(httpResponse.statusCode)", category: .network, level: .info)
            
            if httpResponse.statusCode != 200 {
                // Log the error response body
                if let errorString = String(data: data, encoding: .utf8) {
                    Logger.shared.log("❌ Error response: \(errorString)", category: .network, level: .error)
                }
                throw SearchError.apiError
            }
        }
        
        let result = try JSONDecoder().decode(PerplexityResponse.self, from: data)
        
        // Extract answer and citations
        let answer = PerplexityAnswer(
            text: result.choices.first?.message.content ?? "",
            citations: result.citations ?? []
        )
        
        Logger.shared.log("✅ Perplexity answered with \(answer.citations.count) citations", category: .network, level: .info)
        
        return answer
    }
    
    /// Create context for Plato from Perplexity's answer
    func createContext(from answer: PerplexityAnswer) -> String {
        var context = "CURRENT INFORMATION (from web search):\n\n"
        
        // The answer itself
        context += answer.text + "\n\n"
        
        // Add citations for credibility
        if !answer.citations.isEmpty {
            context += "Sources:\n"
            for citation in answer.citations.prefix(3) {
                context += "- \(citation)\n"
            }
        }
        
        return context
    }
}

// MARK: - Models

struct PerplexityAnswer {
    let text: String
    let citations: [String]
}

struct PerplexityResponse: Codable {
    let choices: [Choice]
    let citations: [String]?
    
    struct Choice: Codable {
        let message: Message
    }
    
    struct Message: Codable {
        let content: String
    }
}
