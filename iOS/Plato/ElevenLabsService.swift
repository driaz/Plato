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
    }
    
    // MARK: - Public API
    
    /// Speak text using PCM streaming when enabled, MP3 fallback otherwise
    // In ElevenLabsService.swift, update the speak method to use stopForTTS:

    func speak(_ raw: String) async {
        // CRITICAL: Set isSpeaking IMMEDIATELY to prevent race conditions
        await MainActor.run {
            self.isSpeaking = true
            print("🔊 TTS Starting - isSpeaking = true")
            
            // Force stop speech recognition and prevent auto-restarts
            ContentView.sharedSpeechRecognizer?.stopForTTS()
        }
        
        stopSpeaking()
        let text = Self.cleanText(raw)
        
        // Check if we should use PCM streaming
        if cfg.useStreamingTTS && cfg.hasElevenLabs {
            // Initialize PCM streamer on MainActor if needed
            if pcmStreamer == nil {
                await MainActor.run {
                    self.pcmStreamer = PCMStreamingService()
                }
            }
            
            // Use PCM streaming for low latency
            await pcmStreamer?.streamSpeech(text)
            
            // IMPORTANT: Wait for streaming to actually complete
            // The streamSpeech method should complete only when audio finishes
            await MainActor.run {
                self.isSpeaking = false
                print("🔊 TTS Complete - isSpeaking = false (PCM streaming finished)")
                
                // Notify speech recognizer that TTS is done
                ContentView.sharedSpeechRecognizer?.notifyTTSComplete()
            }
        } else {
            // Fall back to MP3 mode
            do {
                try await speakBlockingGeorge(text)
            } catch {
                print("⚠️ George MP3 error: \(error) — fallback system TTS")
                await fallbackSystemTTS(text)
            }
            
            // MP3/System TTS completion
            await MainActor.run {
                self.isSpeaking = false
                print("🔊 TTS Complete - isSpeaking = false")
                
                // Notify speech recognizer that TTS is done
                ContentView.sharedSpeechRecognizer?.notifyTTSComplete()
            }
        }
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
        // Stop any existing playback
        stopSpeaking()
        
        // Wait a bit for audio session to settle after STT stops
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        
        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
            print("🔊 Audio session configured for playback")
        } catch {
            print("❌ Audio session error: \(error)")
            return
        }
        
        // Create a simple AVAudioPlayer for MP3 playback
        do {
            mp3Player = try AVAudioPlayer(data: data)
            mp3Player?.delegate = self
            mp3Player?.prepareToPlay()
            
            isSpeaking = true
            
            // Play and wait for completion
            mp3Player?.play()
            
            // Wait for playback to complete
            while mp3Player?.isPlaying == true {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
            
            isSpeaking = false
            print("✅ MP3 playback completed")
            
        } catch {
            print("❌ Failed to play MP3: \(error)")
            isSpeaking = false
        }
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
        Task { @MainActor in
            if self.mp3Player === player { self.mp3Player = nil }
            self.isSpeaking = false
        }
        if let error { print("George MP3 decode error: \(error)") }
    }
    
    // MARK: - Utilities
    
    private static func cleanText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*",  with: "")
            .replacingOccurrences(of: "_",  with: "")
            .replacingOccurrences(of: "`",  with: "")
            .replacingOccurrences(of: "#",  with: "")
            .replacingOccurrences(of: "~",  with: "")
            .replacingOccurrences(of: "\n\n", with: ". ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Error
enum ElevenLabsError: Error {
    case invalidResponse
}

// MARK: - Testing Methods
extension ElevenLabsService {
    /// Test all possible output formats to see what actually works
    func probeAllFormats() async {
        let formats = [
            ("mp3_44100_128", "audio/mpeg"),
            ("mp3_44100_64", "audio/mpeg"),
            ("pcm_16000", "audio/pcm"),
            ("pcm_22050", "audio/pcm"),
            ("pcm_24000", "audio/pcm"),
            ("pcm_44100", "audio/pcm"),
            ("ulaw_8000", "audio/basic")
        ]
        
        print("\n🧪 === ElevenLabs Format Probe ===")
        print("🔑 Using voice: \(cfg.elevenLabsVoiceId)")
        
        for (format, accept) in formats {
            await testFormat(format: format, acceptHeader: accept)
        }
        
        // Also test with audio/wav
        print("\n🧪 Testing pcm_24000 with audio/wav accept header:")
        await testFormat(format: "pcm_24000", acceptHeader: "audio/wav")
    }
    
    private func testFormat(format: String, acceptHeader: String) async {
        print("\n📊 Testing format: \(format)")
        
        // Test BOTH regular and streaming endpoints
        let endpoints = [
            ("Regular", "\(base)/\(cfg.elevenLabsVoiceId)"),
            ("Streaming", "\(base)/\(cfg.elevenLabsVoiceId)/stream")
        ]
        
        for (endpointName, baseUrl) in endpoints {
            print("\n  Testing \(endpointName) endpoint:")
            
            // For streaming endpoint, add output_format as query param
            let url: URL
            if endpointName == "Streaming" {
                url = URL(string: "\(baseUrl)?output_format=\(format)")!
            } else {
                url = URL(string: baseUrl)!
            }
            
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(acceptHeader, forHTTPHeaderField: "Accept")
            
            let body: [String: Any]
            if endpointName == "Regular" {
                // Regular endpoint uses output_format in body
                body = [
                    "text": "Test.",
                    "model_id": "eleven_turbo_v2_5",
                    "output_format": format
                ]
            } else {
                // Streaming endpoint doesn't need output_format in body
                body = [
                    "text": "Test.",
                    "model_id": "eleven_turbo_v2_5"
                ]
            }
            
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                
                let (data, response) = try await URLSession.shared.data(for: req)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("  ❌ Invalid response type")
                    continue
                }
                
                print("    Status: \(httpResponse.statusCode)")
                print("    Content-Type: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "none")")
                print("    Content-Length: \(data.count) bytes")
                
                if httpResponse.statusCode == 200 && data.count > 0 {
                    // Check first few bytes to identify format
                    let prefix = data.prefix(16)
                    let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("    First bytes: \(hex)")
                    
                    // Try to identify format
                    if prefix.starts(with: [0x49, 0x44, 0x33]) ||
                       (prefix.count > 1 && prefix[0] == 0xFF && (prefix[1] & 0xE0) == 0xE0) {
                        print("    ✅ Detected: MP3")
                    } else if prefix.starts(with: [0x52, 0x49, 0x46, 0x46]) {
                        print("    ✅ Detected: WAV/RIFF")
                    } else if format.contains("pcm") {
                        // For PCM, check if it looks like audio (varies around 0)
                        let samples = prefix.withUnsafeBytes { $0.bindMemory(to: Int16.self) }
                        let values = (0..<min(8, samples.count)).map { samples[$0] }
                        print("    PCM samples: \(values)")
                        print("    ✅ Likely: Raw PCM")
                    } else {
                        print("    ❓ Unknown format")
                    }
                } else if httpResponse.statusCode == 422 {
                    // Parse error message
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let detail = json["detail"] as? [String: Any] {
                        print("    ❌ Error: \(detail)")
                    }
                }
                
            } catch {
                print("    ❌ Request failed: \(error)")
            }
        }
    }
    
    /// Test streaming endpoint specifically
    func testStreamingEndpoint() async {
        print("\n🧪 === Testing Streaming Endpoint ===")
        
        let url = URL(string: "\(base)/\(cfg.elevenLabsVoiceId)/stream?output_format=pcm_24000")!
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/wav", forHTTPHeaderField: "Accept")
        
        let body: [String: Any] = [
            "text": "Testing streaming.",
            "model_id": "eleven_turbo_v2_5",
            "optimize_streaming_latency": 1
        ]
        
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response type")
                return
            }
            
            print("Status: \(httpResponse.statusCode)")
            print("Content-Type: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "none")")
            
            if httpResponse.statusCode == 200 {
                var firstChunk = Data()
                var totalBytes = 0
                
                for try await byte in bytes {
                    if firstChunk.count < 100 {
                        firstChunk.append(byte)
                    }
                    totalBytes += 1
                    
                    if totalBytes == 100 {
                        let hex = firstChunk.map { String(format: "%02X", $0) }.joined(separator: " ")
                        print("First 100 bytes: \(hex)")
                    }
                    
                    if totalBytes > 1000 {
                        break // Just test first 1KB
                    }
                }
                
                print("✅ Streaming works! Received \(totalBytes) bytes")
            } else {
                // Read error response
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                    if errorData.count > 1000 { break } // Limit error message size
                }
                if let errorStr = String(data: errorData, encoding: .utf8) {
                    print("❌ Error: \(errorStr)")
                }
            }
            
        } catch {
            print("❌ Stream test failed: \(error)")
        }
    }
    
    
    /// Test method to verify PCM is working
    func testPCMDirectly() async {
        print("\n🧪 ===== Direct PCM Test =====")
        
        let testText = "Testing PCM audio streaming directly"
        
        print("1️⃣ Config check:")
        print("   - useStreamingTTS: \(cfg.useStreamingTTS)")
        print("   - hasElevenLabs: \(cfg.hasElevenLabs)")
        
        print("2️⃣ Initializing PCM streamer...")
        await MainActor.run {
            self.pcmStreamer = PCMStreamingService()
        }
        print("   - pcmStreamer initialized: \(pcmStreamer != nil)")
        
        print("3️⃣ Calling streamSpeech directly...")
        let start = Date()
        
        await pcmStreamer?.streamSpeech(testText)
        
        let duration = Date().timeIntervalSince(start) * 1000
        print("✅ Test completed in \(Int(duration))ms")
        
        print("🧪 ===== End Direct PCM Test =====\n")
    }
    
    /// Add logging to the init method
    func debugInit() {
        print("\n🏗️ ===== ElevenLabsService.init() =====")
        print("🔧 Config at init time:")
        print("   - useStreamingTTS: \(cfg.useStreamingTTS)")
        print("   - hasElevenLabs: \(cfg.hasElevenLabs)")
        print("🏗️ ===== End init =====\n")
    }
    
}
