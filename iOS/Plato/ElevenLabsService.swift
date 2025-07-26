//
//  ElevenLabsService.swift
//  Plato
//
//  Simplified MP3 streaming - accumulate then play approach
//

import Foundation
import AVFoundation

final class ElevenLabsService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isSpeaking: Bool = false
    @Published var isGenerating: Bool = false
    
    private let cfg = ConfigManager.shared
    private let base = "https://api.elevenlabs.io/v1/text-to-speech"
    
    // Fallback system TTS
    private var fallbackSynth: AVSpeechSynthesizer?
    
    // Audio playback engine
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    
    // Streaming state
    private var streamingTask: Task<Void, Never>?
    
    override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    /// Speak text using ElevenLabs (streaming or blocking) when available; fallback to system TTS otherwise.
    func speak(_ raw: String) async {
        stopSpeaking()
        let text = Self.cleanText(raw)
        
        print("🎭 ElevenLabs speak() called with text: \(text.prefix(50))...")
        print("🎭 Has API key: \(cfg.hasElevenLabs)")
        print("🎭 Streaming enabled: \(cfg.useStreamingTTS)")
        
        if cfg.hasElevenLabs {
            if cfg.useStreamingTTS {
                print("🎭 Using ElevenLabs streaming accumulate mode...")
                do {
                    try await speakStreamingAccumulate(text)
                    print("🎭 ElevenLabs streaming accumulate completed successfully")
                } catch {
                    print("⚠️ ElevenLabs streaming error: \(error) — fallback to blocking.")
                    do {
                        try await speakBlockingMP3(text)
                        print("🎭 ElevenLabs blocking fallback completed")
                    } catch {
                        print("⚠️ ElevenLabs blocking error: \(error) — fallback to system TTS.")
                        await fallbackSystemTTS(text)
                    }
                }
            } else {
                print("🎭 Using ElevenLabs MP3 blocking mode...")
                do {
                    try await speakBlockingMP3(text)
                    print("🎭 ElevenLabs MP3 blocking completed successfully")
                } catch {
                    print("⚠️ ElevenLabs error: \(error) — fallback to system TTS.")
                    await fallbackSystemTTS(text)
                }
            }
        } else {
            print("🎭 No ElevenLabs API key - using system TTS")
            await fallbackSystemTTS(text)
        }
    }
    
    /// Stop playback immediately.
    func stopSpeaking() {
        Task { @MainActor in
            // Cancel streaming
            streamingTask?.cancel()
            streamingTask = nil
            
            // Stop audio engine
            playerNode?.stop()
            engine?.stop()
            engine = nil
            playerNode = nil
            
            // Stop system TTS
            fallbackSynth?.stopSpeaking(at: .immediate)
            fallbackSynth = nil
            
            isSpeaking = false
        }
    }
    
    var isConfigured: Bool { cfg.hasElevenLabs }
    
    // MARK: - Streaming Accumulate Implementation
    
    private func speakStreamingAccumulate(_ text: String) async throws {
        await setupAudioSession()
        
        // Build streaming request
        let url = URL(string: "\(base)/\(cfg.elevenLabsVoiceId)/stream?optimize_streaming_latency=\(cfg.elevenLabsLatencyMode)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")  // Request MP3 format
        
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
        
        // Start streaming and accumulate all data
        print("🌊 Starting MP3 stream accumulation...")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ElevenLabsError.invalidResponse
        }
        
        await MainActor.run {
            isGenerating = true
            // Pause STT during generation (not playback yet)
            ContentView.sharedSpeechRecognizer?.stopRecording()
            print("🎤 STT paused during streaming generation")
        }
        
        // Accumulate all MP3 data
        var mp3Data = Data()
        var chunkCount = 0
        
        do {
            for try await byte in bytes {
                mp3Data.append(byte)
                chunkCount += 1
                
                // Log progress every 1KB
                if chunkCount % 1024 == 0 {
                    print("📥 Accumulated \(mp3Data.count) bytes...")
                }
            }
            
            print("✅ Stream complete! Total MP3 data: \(mp3Data.count) bytes")
            
            await MainActor.run {
                isGenerating = false
                isSpeaking = true
            }
            
            // Now play the complete MP3 file
            await playAccumulatedMP3(mp3Data)
            
        } catch {
            await MainActor.run {
                isGenerating = false
            }
            throw error
        }
        
        await MainActor.run {
            isSpeaking = false
            // Resume STT after playback is completely done
            ContentView.sharedSpeechRecognizer?.startRecording()
            print("🎤 STT resumed after streaming playback")
        }
    }
    
    @MainActor
    private func playAccumulatedMP3(_ data: Data) async {
        // Clean up any existing audio engine
        engine?.stop()
        engine = nil
        playerNode = nil

        // Build new audio processing graph with gain boost
        let eng  = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let eq   = AVAudioUnitEQ(numberOfBands: 1)
        eq.globalGain = 12.0  // +12dB boost for clarity

        eng.attach(node)
        eng.attach(eq)
        eng.connect(node, to: eq, format: nil)
        eng.connect(eq,  to: eng.mainMixerNode, format: nil)
        
        do {
            try eng.start()
            engine = eng
            playerNode = node
        } catch {
            print("⚠️ Failed to start audio engine: \(error)")
            return
        }

        // Create temporary MP3 file
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("streaming-\(UUID().uuidString).mp3")
        
        guard (try? data.write(to: tmpURL)) != nil,
              let file = try? AVAudioFile(forReading: tmpURL) else {
            print("⚠️ Failed to create temp file or AVAudioFile")
            isSpeaking = false
            return
        }

        print("🔊 Starting accumulated MP3 playback — file duration: \(file.length) frames")
        print("🔊 File format: \(file.processingFormat)")
        
        node.play()  // Start the audio engine clocks
        await node.scheduleFile(file, at: nil)  // Schedule and wait for completion
        
        print("🟢 Accumulated MP3 playback completed")
        
        // Cleanup
        try? FileManager.default.removeItem(at: tmpURL)
        eng.stop()
        engine = nil
        playerNode = nil
    }
    
    // MARK: - MP3 Blocking Implementation (Fallback)
    
    private func speakBlockingMP3(_ text: String) async throws {
        await setupAudioSession()
        
        // Build blocking request
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

        // Fetch MP3 audio data
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ElevenLabsError.invalidResponse
        }

        // Play MP3 via AVAudioEngine
        await playBlockingMP3(data)
    }

    @MainActor
    private func playBlockingMP3(_ data: Data) async {
        // Clean up any existing audio engine
        engine?.stop()
        engine = nil
        playerNode = nil

        // Build new audio processing graph with gain boost
        let eng  = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let eq   = AVAudioUnitEQ(numberOfBands: 1)
        eq.globalGain = 12.0  // +12dB boost for clarity

        eng.attach(node)
        eng.attach(eq)
        eng.connect(node, to: eq, format: nil)
        eng.connect(eq,  to: eng.mainMixerNode, format: nil)
        try? eng.start()

        engine     = eng
        playerNode = node

        // Create temporary MP3 file
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("george-\(UUID().uuidString).mp3")
        
        guard (try? data.write(to: tmpURL)) != nil,
              let file = try? AVAudioFile(forReading: tmpURL) else {
            print("⚠️ Failed to create temp file or AVAudioFile")
            isSpeaking = false
            return
        }

        // Pause speech recognition during playback
        ContentView.sharedSpeechRecognizer?.stopRecording()
        print("🎤 STT paused for blocking playback")

        isSpeaking = true
        print("🔊 Starting blocking MP3 playback — engine running:", eng.isRunning)
        
        node.play()  // Start the audio engine clocks
        await node.scheduleFile(file, at: nil)  // Schedule and wait for completion
        
        print("🟢 Blocking MP3 playback completed")
        
        // Cleanup
        try? FileManager.default.removeItem(at: tmpURL)
        isSpeaking = false
        eng.stop()
        engine = nil
        playerNode = nil

        // Resume speech recognition
        ContentView.sharedSpeechRecognizer?.startRecording()
        print("🎤 STT resumed after blocking playback")
    }
    
    // MARK: - Audio Session Setup
    
    @MainActor
    private func setupAudioSession() async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                  mode: .voiceChat,
                                  options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            print("⚠️ Failed to setup audio session: \(error)")
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
        
        await MainActor.run {
            isSpeaking = true
            synth.speak(utterance)
        }
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.fallbackSynth = nil
        }
    }
    
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.fallbackSynth = nil
        }
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

// MARK: - Error Types
enum ElevenLabsError: Error {
    case invalidResponse
    case apiError(String)
}
