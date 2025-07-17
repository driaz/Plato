//
//  ElevenLabsService.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
// /Users/danielriaz/Projects/Plato/iOS/Plato/ElevenLabsService.swift

import Foundation
import AVFoundation

// MARK: - ElevenLabs API Models
struct ElevenLabsRequest: Codable {
    let text: String
    let modelId: String
    let voiceSettings: VoiceSettings
    
    enum CodingKeys: String, CodingKey {
        case text
        case modelId = "model_id"
        case voiceSettings = "voice_settings"
    }
}

struct VoiceSettings: Codable {
    let stability: Double
    let similarityBoost: Double
    let style: Double
    let useSpeakerBoost: Bool
    
    enum CodingKeys: String, CodingKey {
        case stability
        case similarityBoost = "similarity_boost"
        case style
        case useSpeakerBoost = "use_speaker_boost"
    }
}

// MARK: - ElevenLabs Service
@MainActor
class ElevenLabsService: NSObject, ObservableObject {
    @Published var isSpeaking: Bool = false
    @Published var isGenerating: Bool = false
    
    private let apiKey: String
    private let voiceId: String = "JBFqnCBsd6RMkjVDRZzb" // George voice - warm, wise tone
    private let baseURL = "https://api.elevenlabs.io/v1/text-to-speech"
    
    private var audioPlayer: AVAudioPlayer?
    
    override init() {
        self.apiKey = ConfigManager.shared.elevenLabsAPIKey
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set up audio session for ElevenLabs: \(error)")
        }
    }
    
    func speak(_ text: String) async {
        print("🎭 ElevenLabs speak called with: '\(text.prefix(50))...'")
        print("🔑 API Key configured: \(!apiKey.isEmpty)")
        
        guard !apiKey.isEmpty else {
            print("🔄 ElevenLabs API key not configured, falling back to system TTS")
            await fallbackToSystemTTS(text)
            return
        }
        
        // Clean text for speech before processing
        let cleanedText = cleanTextForSpeech(text)
        print("🧹 Cleaned text: '\(cleanedText.prefix(50))...'")
        
        isGenerating = true
        
        do {
            print("🎵 Starting ElevenLabs generation...")
            let audioData = try await generateSpeech(text: cleanedText)
            print("✅ ElevenLabs generation successful, data size: \(audioData.count) bytes")
            await playAudio(data: audioData)
            print("🔊 Audio playback completed")
        } catch {
            print("❌ ElevenLabs TTS error: \(error), falling back to system TTS")
            await fallbackToSystemTTS(cleanedText)
        }
        
        isGenerating = false
    }
    
    private func cleanTextForSpeech(_ text: String) -> String {
        var cleaned = text
        
        // Remove common markdown formatting
        cleaned = cleaned.replacingOccurrences(of: "**", with: "") // Bold
        cleaned = cleaned.replacingOccurrences(of: "*", with: "")  // Italics
        cleaned = cleaned.replacingOccurrences(of: "_", with: "")  // Underline
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")  // Code
        cleaned = cleaned.replacingOccurrences(of: "#", with: "")  // Headers
        cleaned = cleaned.replacingOccurrences(of: "~", with: "")  // Strikethrough
        
        // Clean up bullet points and lists
        cleaned = cleaned.replacingOccurrences(of: "• ", with: "")
        cleaned = cleaned.replacingOccurrences(of: "- ", with: "")
        cleaned = cleaned.replacingOccurrences(of: "+ ", with: "")
        
        // Replace em dashes with regular dashes for better speech
        cleaned = cleaned.replacingOccurrences(of: "—", with: " - ")
        cleaned = cleaned.replacingOccurrences(of: "–", with: " - ")
        
        // Clean up multiple spaces and line breaks
        cleaned = cleaned.replacingOccurrences(of: "\n\n", with: ". ")
        cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        
        // Remove any remaining special characters that sound bad
        cleaned = cleaned.replacingOccurrences(of: "[", with: "")
        cleaned = cleaned.replacingOccurrences(of: "]", with: "")
        cleaned = cleaned.replacingOccurrences(of: "{", with: "")
        cleaned = cleaned.replacingOccurrences(of: "}", with: "")
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func generateSpeech(text: String) async throws -> Data {
        let url = URL(string: "\(baseURL)/\(voiceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        
        let requestBody = ElevenLabsRequest(
            text: text,
            modelId: "eleven_turbo_v2_5", // Faster model for reduced latency
            voiceSettings: VoiceSettings(
                stability: 0.6,        // More stable for philosophical content
                similarityBoost: 0.8,  // Higher similarity for consistency
                style: 0.2,           // Reduced style for faster generation
                useSpeakerBoost: true  // Enhanced clarity
            )
        )
        
        request.httpBody = try JSONEncoder().encode(requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw ElevenLabsError.apiError(httpResponse.statusCode)
        }
        
        return data
    }
    
    private func playAudio(data: Data) async {
        do {
            // Pre-configure audio session for playback
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay() // Pre-buffer audio for faster start
            
            await MainActor.run {
                isSpeaking = true
                print("🔊 Starting audio playback - isSpeaking set to TRUE")
            }
            
            audioPlayer?.play()
            
            // Wait for playback to complete more efficiently
            while audioPlayer?.isPlaying == true {
                try await Task.sleep(nanoseconds: 50_000_000) // Check every 0.05 seconds
            }
            
            await MainActor.run {
                isSpeaking = false
                print("🔊 Audio playback finished - isSpeaking set to FALSE")
            }
            
        } catch {
            print("Failed to play ElevenLabs audio: \(error)")
            await MainActor.run {
                isSpeaking = false
                print("🔊 Audio playback failed - isSpeaking set to FALSE")
            }
        }
    }
    
    private func fallbackToSystemTTS(_ text: String) async {
        print("🔄 Using system TTS fallback")
        // Clean text for system TTS too
        let cleanedText = cleanTextForSpeech(text)
        
        // Configure audio session for playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session for system TTS: \(error)")
        }
        
        // Fallback to Apple's system TTS if ElevenLabs fails
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: cleanedText)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85 // Slightly slower
        
        await MainActor.run {
            isSpeaking = true
            print("🔊 System TTS starting - isSpeaking set to TRUE")
        }
        
        synthesizer.speak(utterance)
        
        // Simple wait for system TTS (approximate)
        let estimatedDuration = Double(cleanedText.count) * 0.08 // Rough estimate
        try? await Task.sleep(nanoseconds: UInt64(estimatedDuration * 1_000_000_000))
        
        await MainActor.run {
            isSpeaking = false
            print("🔊 System TTS completed - isSpeaking set to FALSE")
        }
        
        print("🔊 System TTS completed")
    }
    
    func stopSpeaking() {
        audioPlayer?.stop()
        isSpeaking = false
    }
    
    var isConfigured: Bool {
        return !apiKey.isEmpty
    }
}

// MARK: - AVAudioPlayerDelegate
extension ElevenLabsService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            if let error = error {
                print("Audio player decode error: \(error)")
            }
        }
    }
}

// MARK: - Error Types
enum ElevenLabsError: LocalizedError {
    case invalidResponse
    case apiError(Int)
    case noAPIKey
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from ElevenLabs"
        case .apiError(let code):
            return "ElevenLabs API Error: \(code)"
        case .noAPIKey:
            return "ElevenLabs API key not configured"
        }
    }
}
