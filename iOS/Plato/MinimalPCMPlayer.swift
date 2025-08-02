//
//  MinimalPCMPlayer.swift
//  Plato
//
//  Phase 1: Get PCM audio working with a test tone
//  Phase 2: Stream ElevenLabs PCM audio
//

import AVFoundation

@MainActor
final class MinimalPCMPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    
    // MARK: - Phase 1: Test Tone
    
    func testPCMPlayback() async {
        print("🎵 Phase 1: Testing minimal PCM playback")
        
        // Step 1: Setup audio session for playback ONLY during test
        let session = AVAudioSession.sharedInstance()
        do {
            // Store current category to restore later
            let previousCategory = session.category
            let previousMode = session.mode
            let previousOptions = session.categoryOptions
            
            // Deactivate first
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            
            // Configure for playback only
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            print("✅ Audio session active for playback")
            
            // Run the test
            await runAudioTest()
            
            // IMPORTANT: Restore previous audio session configuration
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            // Restore original configuration
            try session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            try session.setActive(true)
            print("✅ Audio session restored to: \(previousCategory.rawValue)")
            
        } catch {
            print("❌ Session error: \(error)")
            return
        }
    }
    
    private func runAudioTest() async {
        // Create engine
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        
        engine.attach(playerNode)
        
        // Use the simplest format that works
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: 44100,
                                 channels: 1,
                                 interleaved: false)!
        
        engine.connect(playerNode, to: engine.outputNode, format: format)
        
        // Start engine
        do {
            try engine.start()
            playerNode.play()
            print("✅ Engine started")
        } catch {
            print("❌ Engine error: \(error)")
            return
        }
        
        self.engine = engine
        self.playerNode = playerNode
        
        // Generate test tone
        let sampleRate = format.sampleRate
        let amplitude: Float = 0.1
        let frequency: Float = 440.0 // A440
        let duration = 1.0
        
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("❌ Buffer creation failed")
            return
        }
        
        buffer.frameLength = frameCount
        
        // Generate sine wave
        if let channelData = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                let time = Float(frame) / Float(sampleRate)
                channelData[frame] = amplitude * sin(2.0 * .pi * frequency * time)
            }
        }
        
        // Play it!
        playerNode.scheduleBuffer(buffer) {
            print("✅ Test tone completed")
        }
        
        // Wait for playback
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
        
        // Clean up
        playerNode.stop()
        engine.stop()
        self.engine = nil
        self.playerNode = nil
        
        print("✅ Phase 1 complete - audio engine works!")
    }
    
    // MARK: - Phase 2: ElevenLabs PCM Streaming
    
    func testElevenLabsPCM() async {
        print("🎵 Phase 2: Testing ElevenLabs PCM stream")
        
        let session = AVAudioSession.sharedInstance()
        do {
            // Store current configuration
            let previousCategory = session.category
            let previousMode = session.mode
            let previousOptions = session.categoryOptions
            
            // Configure for playback
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            
            // Run the streaming test
            await streamElevenLabsAudio()
            
            // Restore configuration
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try await Task.sleep(nanoseconds: 100_000_000)
            try session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            try session.setActive(true)
            print("✅ Audio session restored")
            
        } catch {
            print("❌ Session error: \(error)")
        }
    }
    
    private func streamElevenLabsAudio() async {
        // Setup audio engine
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        
        engine.attach(playerNode)
        
        // Use 44.1kHz for initial test (we'll optimize to 24kHz later)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: 44100,
                                 channels: 1,
                                 interleaved: false)!
        
        engine.connect(playerNode, to: engine.outputNode, format: format)
        
        do {
            try engine.start()
            playerNode.play()
            print("✅ Engine ready for streaming")
        } catch {
            print("❌ Engine error: \(error)")
            return
        }
        
        self.engine = engine
        self.playerNode = playerNode
        
        // Stream from ElevenLabs
        await performElevenLabsRequest()
        
        // Wait a bit for final audio to play
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // Clean up
        playerNode.stop()
        engine.stop()
        self.engine = nil
        self.playerNode = nil
        
        print("✅ Phase 2 complete!")
    }
    
    private func performElevenLabsRequest() async {
        let testText = "Hello! This is streaming PCM audio with very low latency. The future of conversational AI is here."
        
        do {
            let apiKey = ConfigManager.shared.elevenLabsAPIKey
            let voiceId = ConfigManager.shared.elevenLabsVoiceId
            
            guard !apiKey.isEmpty else {
                print("❌ ElevenLabs API key not configured")
                return
            }
            
            // Note: Using pcm_44100 for compatibility, we'll optimize later
            let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream?output_format=pcm_44100")!
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let body: [String: Any] = [
                "text": testText,
                "model_id": "eleven_turbo_v2_5",
                "optimize_streaming_latency": 2,  // Balanced latency
                "voice_settings": [
                    "stability": 0.6,
                    "similarity_boost": 0.8
                ]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            print("📡 Starting stream...")
            let startTime = Date()
            
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("❌ Bad response: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            
            print("✅ Stream started")
            
            // Process in chunks
            var buffer = Data()
            var firstChunkTime: Date?
            var totalBytes = 0
            
            for try await byte in bytes {
                buffer.append(byte)
                totalBytes += 1
                
                // Play chunks of ~50ms (4410 samples at 44.1kHz, 2 bytes per sample = 8820 bytes)
                if buffer.count >= 8820 {
                    if firstChunkTime == nil {
                        firstChunkTime = Date()
                        let latency = firstChunkTime!.timeIntervalSince(startTime)
                        print("⚡ First audio chunk ready in \(Int(latency * 1000))ms")
                    }
                    
                    let chunk = buffer.prefix(8820)
                    playPCMChunk(Data(chunk))
                    buffer.removeFirst(8820)
                }
            }
            
            // Play remaining data
            if !buffer.isEmpty {
                playPCMChunk(buffer)
            }
            
            print("✅ Streamed \(totalBytes) bytes total")
            
        } catch {
            print("❌ Streaming error: \(error)")
        }
    }
    
    private func playPCMChunk(_ data: Data) {
        guard let playerNode = playerNode,
              let engine = engine else { return }
        
        let format = engine.outputNode.inputFormat(forBus: 0)
        let frameCount = data.count / 2 // 16-bit samples
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Convert 16-bit PCM to Float32
        data.withUnsafeBytes { bytes in
            let int16Ptr = bytes.bindMemory(to: Int16.self)
            if let channelData = buffer.floatChannelData?[0] {
                for i in 0..<frameCount {
                    channelData[i] = Float(int16Ptr[i]) / Float(Int16.max)
                }
            }
        }
        
        playerNode.scheduleBuffer(buffer)
    }
}
