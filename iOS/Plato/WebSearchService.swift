//
//  WebSearchService.swift
//  Plato
//
//  Web search via Brave Search API
//

import Foundation

struct SearchResult: Codable {
    let title: String
    let url: String
    let description: String
    let age: String? // "2 hours ago", etc.
}

final class WebSearchService {
    static let shared = WebSearchService()
    private let baseURL = "https://api.search.brave.com/res/v1/web/search"
    private let cfg = ConfigManager.shared
    
    private init() {}
    
    /// Search Brave and return top results
    func search(_ query: String, limit: Int = 5) async throws -> [SearchResult] {
        guard cfg.hasBraveSearch else {
            throw SearchError.missingAPIKey
        }
        
        // Build request
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw SearchError.invalidQuery
        }
        
        let urlString = "\(baseURL)?q=\(encodedQuery)&count=\(limit)&text_decorations=false"
        guard let url = URL(string: urlString) else {
            throw SearchError.invalidQuery
        }
        
        var request = URLRequest(url: url)
        request.setValue(cfg.braveSearchAPIKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // Perform search
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SearchError.apiError
        }
        
        // Parse response
        let searchResponse = try JSONDecoder().decode(BraveSearchResponse.self, from: data)
        
        return searchResponse.web?.results.prefix(limit).map { result in
            SearchResult(
                title: result.title,
                url: result.url,
                description: result.description,
                age: result.age
            )
        } ?? []
    }
    
    /// Create a context summary for the LLM
    func createSearchContext(from results: [SearchResult], query: String) -> String {
        guard !results.isEmpty else {
            return "No recent information found for '\(query)'."
        }
        
        var context = "Recent search results for '\(query)':\n\n"
        
        for (index, result) in results.enumerated() {
            context += "\(index + 1). \(result.title)\n"
            if let age = result.age {
                context += "   Published: \(age)\n"
            }
            context += "   \(result.description)\n\n"
        }
        
        return context
    }
}

// MARK: - Brave API Response Models

private struct BraveSearchResponse: Codable {
    let web: WebResults?
}

private struct WebResults: Codable {
    let results: [BraveResult]
}

private struct BraveResult: Codable {
    let title: String
    let url: String
    let description: String
    let age: String?
}

// MARK: - Errors

enum SearchError: LocalizedError {
    case missingAPIKey
    case invalidQuery
    case apiError
    case parsingError
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Brave Search API key not configured"
        case .invalidQuery:
            return "Invalid search query"
        case .apiError:
            return "Search API request failed"
        case .parsingError:
            return "Failed to parse search results"
        }
    }
}
