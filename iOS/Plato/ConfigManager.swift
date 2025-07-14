//
//  ConfigManager.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//

import Foundation

struct ConfigManager {
    static let shared = ConfigManager()
    
    private let config: [String: Any]
    
    private init() {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            print("⚠️ Config.plist not found or invalid. Using environment variables fallback.")
            self.config = [:]
            return
        }
        self.config = plist
    }
    
    var openAIAPIKey: String {
        // Try plist first, then environment variables, then return empty
        if let key = config["OpenAI_API_Key"] as? String, !key.isEmpty && key != "YOUR_OPENAI_API_KEY_HERE" {
            return key
        }
        
        // Fallback to environment variable (useful for CI/CD)
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }
        
        return ""
    }
    
    var elevenLabsAPIKey: String {
        // Try plist first, then environment variables, then return empty
        if let key = config["ElevenLabs_API_Key"] as? String, !key.isEmpty && key != "YOUR_ELEVENLABS_API_KEY_HERE" {
            return key
        }
        
        // Fallback to environment variable (useful for CI/CD)
        if let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !key.isEmpty {
            return key
        }
        
        return ""
    }
    
    var isConfigured: Bool {
        return !openAIAPIKey.isEmpty
    }
    
    var hasElevenLabs: Bool {
        return !elevenLabsAPIKey.isEmpty
    }
}
