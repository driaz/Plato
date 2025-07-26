//
//  ConfigManager.swift
//  Plato
//
//  Cleaned version - removed streaming TTS references for now
//

import Foundation

struct ConfigKeys {
    static let openAIAPIKey              = "OpenAI_API_Key"
    static let elevenLabsAPIKey          = "ElevenLabs_API_Key"
    
    // Speech Recognition Tunables
    static let speechSilenceThreshold    = "Speech_SilenceThresholdSeconds"
    static let speechStabilityWindow     = "Speech_StabilityWindowSeconds"
    static let speechPostPlaybackGrace   = "Speech_PostPlaybackGraceSeconds"
    static let speechVADEnergyFloorDb    = "Speech_VADEnergyFloorDb"
    
    // Streaming Configuration
    static let useStreamingLLM           = "Use_Streaming_LLM"
    static let useStreamingTTS           = "Use_Streaming_TTS"
    
    // LLM Configuration
    static let llmModel                  = "LLM_Model"
    static let llmTemperature            = "LLM_Temperature"
    static let llmMaxTokens              = "LLM_MaxTokens"
    
    // ElevenLabs Configuration
    static let elevenLabsVoiceId         = "ElevenLabs_VoiceId"
    static let elevenLabsLatencyMode     = "ElevenLabs_LatencyMode"
}

struct ConfigManager {
    static let shared = ConfigManager()
    private let config: [String: Any]
    
    private init() {
        if let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            config = obj
        } else {
            print("⚠️ Config.plist not found or invalid. Using environment fallbacks.")
            config = [:]
        }
    }
    
    // MARK: - Helper Methods
    
    private func string(_ key: String) -> String? {
        if let s = config[key] as? String, !s.isEmpty { return s }
        return nil
    }
    
    private func number(_ key: String) -> Double? {
        if let d = config[key] as? Double { return d }
        if let n = config[key] as? NSNumber { return n.doubleValue }
        if let s = config[key] as? String, let d = Double(s) { return d }
        return nil
    }
    
    private func bool(_ key: String) -> Bool? {
        if let b = config[key] as? Bool { return b }
        if let n = config[key] as? NSNumber { return n.boolValue }
        if let s = config[key] as? String {
            switch s.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: break
            }
        }
        return nil
    }
    
    // MARK: - API Keys
    
    var openAIAPIKey: String {
        if let key = string(ConfigKeys.openAIAPIKey), key != "YOUR_OPENAI_API_KEY_HERE" {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        return ""
    }
    
    var elevenLabsAPIKey: String {
        if let key = string(ConfigKeys.elevenLabsAPIKey), key != "YOUR_ELEVENLABS_API_KEY_HERE" {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !env.isEmpty {
            return env
        }
        return ""
    }
    
    // MARK: - Speech Recognition Tunables
    
    var speechSilenceThreshold: TimeInterval {
        number(ConfigKeys.speechSilenceThreshold) ?? 0.6
    }
    
    var speechStabilityWindow: TimeInterval {
        number(ConfigKeys.speechStabilityWindow) ?? 0.3
    }
    
    var speechPostPlaybackGrace: TimeInterval {
        number(ConfigKeys.speechPostPlaybackGrace) ?? 0.3
    }
    
    /// Energy floor in dBFS above which we consider speech when VAD enabled.
    var vadEnergyFloorDb: Float? {
        guard let d = number(ConfigKeys.speechVADEnergyFloorDb) else { return nil }
        return Float(d)
    }
    
    // MARK: - LLM Configuration
    
    // MARK: - Streaming Configuration
    
    var useStreamingLLM: Bool {
        bool(ConfigKeys.useStreamingLLM) ?? true
    }
    
    var useStreamingTTS: Bool {
        bool(ConfigKeys.useStreamingTTS) ?? true
    }
    
    var llmModel: String {
        string(ConfigKeys.llmModel) ?? "gpt-4o-mini"
    }
    
    var llmTemperature: Double {
        number(ConfigKeys.llmTemperature) ?? 0.7
    }
    
    var llmMaxTokens: Int {
        Int(number(ConfigKeys.llmMaxTokens) ?? 150)
    }
    
    // MARK: - ElevenLabs Configuration
    
    var elevenLabsVoiceId: String {
        string(ConfigKeys.elevenLabsVoiceId) ?? "JBFqnCBsd6RMkjVDRZzb"
    }
    
    /// ElevenLabs streaming latency optimization: 0=default, 1=fastest, 2=balanced
    var elevenLabsLatencyMode: Int {
        Int(number(ConfigKeys.elevenLabsLatencyMode) ?? 2)
    }
    
    // MARK: - Status Flags
    
    var isConfigured: Bool { !openAIAPIKey.isEmpty }
    var hasElevenLabs: Bool { !elevenLabsAPIKey.isEmpty }
}
