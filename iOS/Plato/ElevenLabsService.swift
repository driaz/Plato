//
//  ElevenLabsService.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//

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
        guard !apiKey.isEmpty else {
            print("ElevenLabs API key not configured, falling back to system TTS")
            await fallbackToSystemTTS(text)
            return
        }
        
        isGenerating = true
        
        do {
            let audioData = try await generateSpeech(text: text)
            await playAudio(data: audioData)
        } catch {
            print("ElevenLabs TTS error: \(error), falling back to system TTS")
            await fallbackToSystemTTS(text)
        }
        
        isGenerating = false
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
            modelId: "eleven_monolingual_v1",
            voiceSettings: VoiceSettings(
                stability: 0.6,        // More stable for philosophical content
                similarityBoost: 0.8,  // Higher similarity for consistency
                style: 0.3,           // Subtle style for natural speech
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
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            
            isSpeaking = true
            audioPlayer?.play()
            
            // Wait for playback to complete
            while audioPlayer?.isPlaying == true {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            
        } catch {
            print("Failed to play ElevenLabs audio: \(error)")
            isSpeaking = false
        }
    }
    
    private func fallbackToSystemTTS(_ text: String) async {
        // Fallback to Apple's system TTS if ElevenLabs fails
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85 // Slightly slower
        
        isSpeaking = true
        synthesizer.speak(utterance)
        
        // Simple wait for system TTS (approximate)
        let estimatedDuration = Double(text.count) * 0.08 // Rough estimate
        try? await Task.sleep(nanoseconds: UInt64(estimatedDuration * 1_000_000_000))
        isSpeaking = false
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
