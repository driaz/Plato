//
//  ElevenLabsService.swift
//  Plato
//
//  CLEANED VERSION - Removed legacy streaming players
//

import Foundation
import AVFoundation

final class ElevenLabsService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var isSpeaking: Bool = false
    @Published var isGenerating: Bool = false
    
    private let cfg = ConfigManager.shared
    private let base = "https://api.elevenlabs.io/v1/text-to-speech"

    // Playback modes
    private var fallbackSynth: AVSpeechSynthesizer?
    private var mp3Player: AVAudioPlayer?
    
    // PCM Streamer - the ONLY streaming implementation we need
    private var pcmStreamer: PCMStreamingService?
    
    override init() {
        super.init()
        print("🛑 ElevenLabsService init DISABLED for Realtime testing")
        
        // Original init code would go here (commented out to prevent audio setup)
    }
    
    // MARK: - Public API
    
    /// Speak text using PCM streaming when enabled, MP3 fallback otherwise
    // In ElevenLabsService.swift, update the speak method to use stopForTTS:

    func speak(_ raw: String) async {
        print("🛑 ElevenLabsService.speak() DISABLED for Realtime testing")
        return  // Stop here
        
        
        // Start flow tracking for the entire TTS operation
        let flowId = Logger.shared.startFlow("TTS: \(raw.prefix(30))...")
        
        // Log the state transition
        Logger.shared.log("TTS requested - textLength: \(raw.count), streaming: \(cfg.useStreamingTTS), hasAPI: \(cfg.hasElevenLabs)",
                          category: .tts)
        
        stopSpeaking()
        let text = Self.cleanText(raw)
        
        // CRITICAL: Set isSpeaking IMMEDIATELY to prevent race conditions
        await MainActor.run {
            self.isSpeaking = true

            // State tracking for debugging race conditions
            Logger.shared.log("🔊 TTS Starting - isSpeaking = true", category: .tts)
            
            // Force stop speech recognition and prevent auto-restarts
            ContentView.sharedSpeechRecognizer?.stopForTTS()
            Logger.shared.log("Speech recognizer stopped for TTS", category: .speech, level: .debug)
        }
        
        // Check if we should use PCM streaming
        if cfg.useStreamingTTS && cfg.hasElevenLabs {
            Logger.shared.log("Using PCM streaming mode", category: .tts)

            // Initialize PCM streamer on MainActor if needed
            if pcmStreamer == nil {
                await MainActor.run {
                    self.pcmStreamer = PCMStreamingService()
                    Logger.shared.log("Initialized PCMStreamingService", category: .tts, level: .debug)
                }
            }
            
            // Performance tracking for PCM streaming
            Logger.shared.startTimer("PCM_Stream_\(flowId)")

            // Use PCM streaming for low latency
            await pcmStreamer?.streamSpeech(text)
            Logger.shared.endTimer("PCM_Stream_\(flowId)")

            // IMPORTANT: Wait for streaming to actually complete
            // The streamSpeech method should complete only when audio finishes
            await MainActor.run {
                self.isSpeaking = false
                
                // State tracking for completion
                Logger.shared.log("🔊 TTS Complete (PCM) - isSpeaking = false", category: .tts)

                // Notify speech recognizer that TTS is done
                ContentView.sharedSpeechRecognizer?.notifyTTSComplete()
                Logger.shared.log("Notified speech recognizer of TTS completion", category: .speech, level: .debug)
            }
        } else {
            // Fall back to MP3 mode
            
            // Log fallback mode selection
            Logger.shared.log("Using MP3/fallback mode (streaming=\(cfg.useStreamingTTS), hasAPI=\(cfg.hasElevenLabs))",
                category: .tts, level: .info)
            
            // Performance tracking for MP3 mode
            Logger.shared.startTimer("MP3_Mode_\(flowId)")

            do {
                try await speakBlockingGeorge(text)
                Logger.shared.log("MP3 playback completed successfully", category: .tts)
            } catch {
                // Log the error with context
                Logger.shared.log("George MP3 failed, falling back to system TTS: \(error)", category: .tts)
                await fallbackSystemTTS(text)
                Logger.shared.log("System TTS fallback completed", category: .tts, level: .warning)
            }
            
            Logger.shared.endTimer("MP3_Mode_\(flowId)")

            
            // MP3/System TTS completion
            await MainActor.run {
                self.isSpeaking = false
                
                // State tracking for completion
                Logger.shared.log("🔊 TTS Complete (MP3/System) - isSpeaking = false", category: .tts)

                // Notify speech recognizer that TTS is done
                ContentView.sharedSpeechRecognizer?.notifyTTSComplete()
                Logger.shared.log("Notified speech recognizer of TTS completion", category: .speech, level: .debug)
            }
        }
        // End the flow tracking
        Logger.shared.endFlow(flowId, name: "TTS")
    }
    
    func stopSpeaking() {
        // Stop PCM streaming
        Task { @MainActor in
            pcmStreamer?.stopSpeaking()
        }
        
        // Stop MP3
        Task { @MainActor in
            mp3Player?.stop()
            mp3Player = nil
            isSpeaking = false
            isGenerating = false
        }
        
        // Stop system TTS
        fallbackSynth?.stopSpeaking(at: .immediate)
    }
    
    var isConfigured: Bool { cfg.hasElevenLabs }
    
    // MARK: - MP3 Mode (existing code)
    
    private func speakBlockingGeorge(_ text: String) async throws {
        let url = URL(string: "\(base)/\(cfg.elevenLabsVoiceId)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.6,
                "similarity_boost": 0.8,
                "style": 0.2,
                "use_speaker_boost": true
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        await MainActor.run { isGenerating = true }
        
        let (data, response) = try await URLSession.shared.data(for: req)
        
        await MainActor.run { isGenerating = false }
        
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ElevenLabsError.invalidResponse
        }

        await playMP3(data)
    }
    
    @MainActor
    private func playMP3(_ data: Data) async {
        // Start performance tracking for entire playback operation
        Logger.shared.startTimer("MP3_Playback")
        
        // Log the incoming data size for debugging
        Logger.shared.log("Starting MP3 playback - data size: \(data.count) bytes", category: .tts, level: .debug)
        
        // Stop any existing playback
        stopSpeaking()
        
        // Wait a bit for audio session to settle after STT stops
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        Logger.shared.log("Audio session settling delay complete (200ms)", category: .audio, level: .debug)
        
        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
            Logger.shared.log("🔊 Audio session configured for MP3 playback - routing to speaker", category: .audio)
        } catch {
            Logger.shared.log("❌ Audio session configuration failed: \(error)", category: .audio, level: .error)
            Logger.shared.endTimer("MP3_Playback")
            return
        }
        
        // Create a simple AVAudioPlayer for MP3 playback
        do {
            // Track player creation time
            Logger.shared.startTimer("MP3_Player_Init")
            
            mp3Player = try AVAudioPlayer(data: data)
            mp3Player?.delegate = self
            mp3Player?.prepareToPlay()
            
            Logger.shared.endTimer("MP3_Player_Init")
            Logger.shared.log("MP3 player initialized and prepared", category: .tts, level: .debug)
            
            isSpeaking = true
            Logger.shared.log("isSpeaking set to true - starting MP3 playback", category: .tts, level: .debug)
            
            // Play and wait for completion
            mp3Player?.play()
            Logger.shared.log("MP3 playback started", category: .tts)
            
            // Wait for playback to complete
            while mp3Player?.isPlaying == true {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
            
            isSpeaking = false
            Logger.shared.log("✅ MP3 playback completed successfully - isSpeaking set to false", category: .tts)
            
        } catch {
            // Log playback failure
            Logger.shared.log("❌ Failed to initialize/play MP3: \(error)", category: .tts, level: .error)
            isSpeaking = false
        }
        // End performance tracking
        Logger.shared.endTimer("MP3_Playback")
    }
    
    // MARK: - System TTS Fallback
    
    private func fallbackSystemTTS(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        fallbackSynth = synth
        
        isSpeaking = true
        synth.speak(utterance)
    }
    
    // MARK: - Delegates
    
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.fallbackSynth = nil
            ContentView.sharedSpeechRecognizer?.notifyTTSComplete()
        }
    }
    
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.fallbackSynth = nil
        }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.mp3Player === player { self.mp3Player = nil }
            self.isSpeaking = false
            ContentView.sharedSpeechRecognizer?.notifyTTSComplete()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        
        // Log the decode error immediately (before async context)
        if let error {
            Logger.shared.log("George MP3 decode error occurred: \(error)", category: .tts, level: .error)
            
            // Log additional context about the error
            Logger.shared.log("Error domain: \((error as NSError).domain), code: \((error as NSError).code)", category: .tts, level: .debug)
        } else {
            Logger.shared.log("MP3 decode error occurred (no error details provided)", category: .tts, level: .error)
        }
        
        // Clean up player state on MainActor
        Task { @MainActor in
            // Only clear if it's our current player
            if self.mp3Player === player {
                self.mp3Player = nil
                Logger.shared.log("Cleared mp3Player reference due to decode error", category: .tts, level: .debug)
            }
            
            // Always clear speaking flag on decode error
            self.isSpeaking = false
            Logger.shared.log("isSpeaking set to false due to MP3 decode error", category: .tts, level: .debug)
        }
    }
    
    // MARK: - Utilities
    
    private static func cleanText(_ text: String) -> String {
        
        var cleaned = text
            // Remove markdown formatting
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*",  with: "")
            .replacingOccurrences(of: "_",  with: "")
            .replacingOccurrences(of: "`",  with: "")
            .replacingOccurrences(of: "#",  with: "")
            .replacingOccurrences(of: "~",  with: "")
            
            // Handle line breaks
            .replacingOccurrences(of: "\n\n", with: ". ")
            .replacingOccurrences(of: "\n", with: " ")
            
            // Fix stock market and bullet point formatting
            .replacingOccurrences(of: "—", with: ", ")  // Em dash
            .replacingOccurrences(of: "–", with: ", ")  // En dash
            
            // Clean up extra whitespace
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle bullet points and list formatting using regex
        cleaned = cleaned.replacingOccurrences(
            of: "^- ", 
            with: "", 
            options: [.regularExpression]
        )
        
        // Replace dashes used as separators with commas
        cleaned = cleaned.replacingOccurrences(of: " - ", with: ", ")
        
        // Apply normalization ONLY for TTS, not affecting display
        let beforeNormalization = cleaned
        cleaned = TextNormalizer.normalizeForTTS(cleaned)
        
        if beforeNormalization != cleaned {
            Logger.shared.log("👁️ User sees: \(beforeNormalization)", category: .tts, level: .debug)
            Logger.shared.log("🔊 TTS speaks: \(cleaned)", category: .tts, level: .debug)
        }
        
        return cleaned
    }
}

// MARK: - Error
enum ElevenLabsError: Error {
    case invalidResponse
}

// MARK: - Testing Methods
extension ElevenLabsService {
    
#if DEBUG
/// Quick test to verify ElevenLabs API is working
func testAPIConnection() async {
    Logger.shared.log("=== Testing ElevenLabs API Connection ===", category: .tts)
    
    let testText = "Test"
    Logger.shared.startTimer("API_Test")
    
    do {
        // Try a simple TTS request
        let url = URL(string: "\(base)/\(cfg.elevenLabsVoiceId)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        
        let body: [String: Any] = [
            "text": testText,
            "model_id": "eleven_turbo_v2_5"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: req)
        
        if let httpResponse = response as? HTTPURLResponse {
            Logger.shared.log("API Test Result: Status \(httpResponse.statusCode), Size: \(data.count) bytes",
                             category: .tts,
                             level: httpResponse.statusCode == 200 ? .info : .error)
        }
        
    } catch {
        Logger.shared.log("API Test Failed: \(error)", category: .tts, level: .error)
    }
    
    Logger.shared.endTimer("API_Test")
}

/// Get current configuration status
func logConfigurationStatus() {
    Logger.shared.log("=== ElevenLabs Configuration ===", category: .tts)
    Logger.shared.log("API Key Present: \(cfg.hasElevenLabs)", category: .tts)
    Logger.shared.log("Voice ID: \(cfg.elevenLabsVoiceId)", category: .tts)
    Logger.shared.log("Streaming Enabled: \(cfg.useStreamingTTS)", category: .tts)
    Logger.shared.log("Latency Mode: \(cfg.elevenLabsLatencyMode)", category: .tts)
}
#endif
    
 
}
