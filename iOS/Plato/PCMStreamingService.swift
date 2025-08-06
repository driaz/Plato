//
//  PCMStreamingService.swift
//  Plato
//
//  Production-ready PCM streaming for ElevenLabs TTS
//

import Foundation
import AVFoundation

@MainActor
final class PCMStreamingService: ObservableObject {
    @Published var isSpeaking = false
    @Published var isGenerating = false
    
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var currentTask: Task<Void, Never>?
    private var isPlaybackComplete = false
    
    private let cfg = ConfigManager.shared
    private let baseURL = "https://api.elevenlabs.io/v1/text-to-speech"
    
    // Use 24kHz for optimal bandwidth/quality balance
    private let sampleRate: Double = 24000
    private let chunkDuration: Double = 0.05 // 50ms chunks
    
    // Completion tracking
    private var scheduledBufferCount = 0
    private var isStreamingComplete = false
    private var playbackCompletionContinuation: CheckedContinuation<Void, Never>?
    
    // MARK: - Public API

    /// Stream text to speech with low latency
    func streamSpeech(_ text: String) async {
        // Cancel any existing stream
        stopSpeaking()
        
        guard cfg.hasElevenLabs else {
            print("❌ ElevenLabs not configured")
            return
        }
        
        // Clean the text
        let cleanedText = cleanText(text)
        guard !cleanedText.isEmpty else { return }
        
        isGenerating = true
        isSpeaking = true  // Set both flags at start
        
        // Create a new task for this stream
        currentTask = Task {
            await performStreaming(cleanedText)
        }
        
        // Wait for completion
        await currentTask?.value
        
        // Ensure isSpeaking is false after everything completes
        isSpeaking = false
        print("🔊 PCMStreamingService - playback complete, isSpeaking = false")
    }
    
    /// Stop any ongoing speech
    func stopSpeaking() {
        currentTask?.cancel()
        currentTask = nil
        
        cleanupAudio()
        
        isSpeaking = false
        isGenerating = false
    }
    
    // MARK: - Private Implementation
    
    private func performStreaming(_ text: String) async {
        do {
            // Setup audio engine
            try await setupAudioEngine()
            
            // Start the stream
            try await streamFromElevenLabs(text)
            
            // Wait for actual playback to complete
            await withCheckedContinuation { continuation in
                self.playbackCompletionContinuation = continuation
                
                // Check if playback already completed (for very short audio)
                if self.scheduledBufferCount == 0 && self.isStreamingComplete {
                    continuation.resume()
                }
            }
            
            // Add a small buffer after playback completes
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            
        } catch {
            print("❌ Streaming error: \(error)")
        }
        
        // Cleanup
        cleanupAudio()
        
        isSpeaking = false
        isGenerating = false
        
    }
    
    private func setupAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        
        // Store current state
        UserDefaults.standard.set(session.category.rawValue, forKey: "saved_audio_category")
        UserDefaults.standard.set(session.mode.rawValue, forKey: "saved_audio_mode")
        
        // Configure for playback
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }
    
    private func restoreAudioSession() async {
        let session = AVAudioSession.sharedInstance()
        
        // Restore saved configuration
        if let savedCategory = UserDefaults.standard.string(forKey: "saved_audio_category"),
           let savedMode = UserDefaults.standard.string(forKey: "saved_audio_mode") {
            
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? await Task.sleep(nanoseconds: 100_000_000)
            
            // Restore original settings
            if savedCategory == AVAudioSession.Category.playAndRecord.rawValue {
                try? session.setCategory(.playAndRecord,
                                       mode: AVAudioSession.Mode(rawValue: savedMode),
                                       options: [.defaultToSpeaker, .allowBluetooth])
            }
            try? session.setActive(true)
        }
    }
    
    private func setupAudioEngine() async throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        
        engine.attach(playerNode)
        
        // Create format - using hardware rate for compatibility
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let nodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: outputFormat.sampleRate,
                                     channels: 1,
                                     interleaved: false)!
        
        engine.connect(playerNode, to: engine.outputNode, format: nodeFormat)
                
        try engine.start()
        playerNode.play()
        
        self.engine = engine
        self.playerNode = playerNode
        
        print("✅ PCM engine ready (24kHz → \(Int(outputFormat.sampleRate))Hz)")
    }
    
    private func streamFromElevenLabs(_ text: String) async throws {
        // Reset state for new stream
        isStreamingComplete = false
        scheduledBufferCount = 0
        
        let url = URL(string: "\(baseURL)/\(cfg.elevenLabsVoiceId)/stream?output_format=pcm_24000")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "optimize_streaming_latency": cfg.elevenLabsLatencyMode,
            "voice_settings": [
                "stability": 0.6,
                "similarity_boost": 0.8,
                "style": 0.2,
                "use_speaker_boost": true
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let startTime = Date()
        isGenerating = true  // Start as true until we get first chunk
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw StreamingError.badResponse
        }
        
        var buffer = Data()
        var firstChunkReceived = false
        let chunkSize = Int(sampleRate * chunkDuration) * 2 // 2 bytes per sample
        
        for try await byte in bytes {
            guard !Task.isCancelled else { break }
            
            buffer.append(byte)
            
            if buffer.count >= chunkSize {
                if !firstChunkReceived {
                    firstChunkReceived = true
                    let latency = Date().timeIntervalSince(startTime)
                    print("⚡ First audio in \(Int(latency * 1000))ms")
                    isGenerating = false
                    isSpeaking = true
                }
                
                let chunk = buffer.prefix(chunkSize)
                processAudioChunk(Data(chunk))
                buffer.removeFirst(chunkSize)
            }
        }
        
        // Process remaining data
        if !buffer.isEmpty && !Task.isCancelled {
            processAudioChunk(buffer)
        }
        
        // Mark streaming as complete
        isStreamingComplete = true
        print("📊 Streaming complete - \(scheduledBufferCount) buffers pending playback")
        
        // If no buffers are scheduled (very short audio), signal completion immediately
        if scheduledBufferCount == 0 {
            signalPlaybackComplete()
        }
    }
    
    private func processAudioChunk(_ data: Data) {
        guard let playerNode = playerNode,
              let engine = engine,
              !Task.isCancelled else { return }
        
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let outputSampleRate = outputFormat.sampleRate
        
        // Calculate frame counts
        let inputFrameCount = data.count / 2  // 16-bit samples
        let outputFrameCount = Int(Double(inputFrameCount) * outputSampleRate / sampleRate)
        
        // Create buffers
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                               frameCapacity: AVAudioFrameCount(inputFrameCount)),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                frameCapacity: AVAudioFrameCount(outputFrameCount)) else {
            return
        }
        
        inputBuffer.frameLength = AVAudioFrameCount(inputFrameCount)
        outputBuffer.frameLength = AVAudioFrameCount(outputFrameCount)
        
        // Copy data to input buffer
        data.withUnsafeBytes { bytes in
            if let channelData = inputBuffer.int16ChannelData?[0] {
                bytes.copyBytes(to: UnsafeMutableBufferPointer(start: channelData,
                                                              count: inputFrameCount))
            }
        }
        
        // Convert to float format
        guard let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false),
              let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat,
                                               frameCapacity: AVAudioFrameCount(inputFrameCount)) else {
            return
        }
        
        floatBuffer.frameLength = AVAudioFrameCount(inputFrameCount)
        
        // Convert int16 to float32
        let volumeBoost: Float = 2.0  // Amplification factor (adjust as needed)
        
        if let int16Data = inputBuffer.int16ChannelData?[0],
           let floatData = floatBuffer.floatChannelData?[0] {
            for i in 0..<inputFrameCount {
                // Amplify and clamp to prevent distortion
                let amplified = Float(int16Data[i]) / Float(Int16.max) * volumeBoost
                floatData[i] = max(-1.0, min(1.0, amplified))
            }
        }
        
        // Create converter and convert to output rate
        if let converter = AVAudioConverter(from: floatFormat, to: outputFormat) {
            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return floatBuffer
            }
            
            if error == nil {
                // Increment the pending buffer count
                scheduledBufferCount += 1
                
                // Schedule with completion handler to track when this buffer finishes
                playerNode.scheduleBuffer(outputBuffer) { [weak self] in
                    DispatchQueue.main.async {
                        self?.scheduledBufferCount -= 1
                        
                        // If this was the last buffer and streaming is complete, signal completion
                        if self?.scheduledBufferCount == 0 && self?.isStreamingComplete == true {
                            self?.signalPlaybackComplete()
                        }
                    }
                }
            }
        }
    }
    private func cleanupAudio() {
        playerNode?.stop()
        engine?.stop()
        
        playerNode = nil
        engine = nil
    }
    
    private func signalPlaybackComplete() {
        print("🎵 All audio buffers played - signaling completion")
        playbackCompletionContinuation?.resume()
        playbackCompletionContinuation = nil
    }
    
    private func cleanText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "\n\n", with: ". ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum StreamingError: LocalizedError {
    case badResponse
    case audioSetupFailed
    
    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Invalid response from ElevenLabs API"
        case .audioSetupFailed:
            return "Failed to setup audio engine"
        }
    }
}
// Add this debug extension to PCMStreamingService to trace the issue

extension PCMStreamingService {
    
    /// Debug version of streamSpeech with extensive logging
    func streamSpeechDebug(_ text: String) async {
        print("\n🎙️ ===== PCMStreamingService.streamSpeech() START =====")
        print("📝 Text: \(text.prefix(50))...")
        print("🔧 Config check:")
        print("   - hasElevenLabs: \(cfg.hasElevenLabs)")
        print("   - voiceId: \(cfg.elevenLabsVoiceId)")
        print("   - apiKey: \(cfg.elevenLabsAPIKey.prefix(10))...")
        
        // Cancel any existing stream
        stopSpeaking()
        
        guard cfg.hasElevenLabs else {
            print("❌ ElevenLabs not configured")
            return
        }
        
        // Clean the text
        let cleanedText = cleanText(text)
        print("📝 Cleaned text: \(cleanedText.prefix(50))...")
        guard !cleanedText.isEmpty else {
            print("❌ Text is empty after cleaning")
            return
        }
        
        isGenerating = true
        print("🔄 isGenerating = true")
        
        // Create a new task for this stream
        currentTask = Task {
            print("🚀 Starting streaming task...")
            await performStreamingDebug(cleanedText)
        }
        
        // Wait for completion
        print("⏳ Waiting for task completion...")
        await currentTask?.value
        print("✅ Task completed")
        print("🎙️ ===== PCMStreamingService.streamSpeech() END =====\n")
    }
    
    private func performStreamingDebug(_ text: String) async {
        print("\n📡 ===== performStreaming() START =====")
        
        do {
            // Setup audio session
            print("🔊 Setting up audio session...")
            try await setupAudioSessionDebug()
            
            // Setup audio engine
            print("🎚️ Setting up audio engine...")
            try await setupAudioEngineDebug()
            
            // Start the stream
            print("🌊 Starting stream from ElevenLabs...")
            try await streamFromElevenLabsDebug(text)
            
            // Wait for playback to complete
            print("⏸️ Waiting for playback to complete...")
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s buffer
            
        } catch {
            print("❌ Streaming error: \(error)")
            print("📋 Error details: \(error.localizedDescription)")
        }
        
        // Cleanup
        print("🧹 Cleaning up...")
        await restoreAudioSession()
        cleanupAudio()
        
        isSpeaking = false
        isGenerating = false
        print("📡 ===== performStreaming() END =====\n")
    }
    
    private func setupAudioSessionDebug() async throws {
        print("\n🔊 ===== setupAudioSession() =====")
        let session = AVAudioSession.sharedInstance()
        
        // Log current state
        print("📊 Current audio session:")
        print("   - Category: \(session.category.rawValue)")
        print("   - Mode: \(session.mode.rawValue)")
        print("   - Is active: \(session.isOtherAudioPlaying)")
        
        // Store current state
        UserDefaults.standard.set(session.category.rawValue, forKey: "saved_audio_category")
        UserDefaults.standard.set(session.mode.rawValue, forKey: "saved_audio_mode")
        print("💾 Saved current audio state")
        
        // Configure for playback
        print("🔧 Deactivating current session...")
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        print("🔧 Setting category to playback...")
        try session.setCategory(.playback, mode: .default, options: [])
        
        print("🔧 Activating session...")
        try session.setActive(true)
        
        print("✅ Audio session configured:")
        print("   - Category: \(session.category.rawValue)")
        print("   - Mode: \(session.mode.rawValue)")
        print("   - Sample rate: \(session.sampleRate)")
        print("   - Buffer duration: \(session.ioBufferDuration)")
    }
    
    private func setupAudioEngineDebug() async throws {
        print("\n🎚️ ===== setupAudioEngine() =====")
        
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        
        print("📊 Creating audio engine...")
        print("   - Engine: \(engine)")
        print("   - Player node: \(playerNode)")
        
        engine.attach(playerNode)
        print("✅ Player node attached")
        
        // Create format - using hardware rate for compatibility
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        print("📊 Output format:")
        print("   - Sample rate: \(outputFormat.sampleRate)")
        print("   - Channels: \(outputFormat.channelCount)")
        print("   - Common format: \(outputFormat.commonFormat.rawValue)")
        
        let nodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: outputFormat.sampleRate,
                                     channels: 1,
                                     interleaved: false)!
        print("📊 Node format:")
        print("   - Sample rate: \(nodeFormat.sampleRate)")
        print("   - Channels: \(nodeFormat.channelCount)")
        
        engine.connect(playerNode, to: engine.outputNode, format: nodeFormat)
        print("✅ Nodes connected")
        
        print("🚀 Starting engine...")
        try engine.start()
        print("✅ Engine started")
        
        print("▶️ Starting player node...")
        playerNode.play()
        print("✅ Player node playing")
        
        self.engine = engine
        self.playerNode = playerNode
        
        print("✅ PCM engine ready (24kHz → \(Int(outputFormat.sampleRate))Hz)")
    }
    
    private func streamFromElevenLabsDebug(_ text: String) async throws {
        print("\n🌊 ===== streamFromElevenLabs() =====")
        
        let url = URL(string: "\(baseURL)/\(cfg.elevenLabsVoiceId)/stream?output_format=pcm_24000")!
        print("🌐 URL: \(url)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "optimize_streaming_latency": cfg.elevenLabsLatencyMode,
            "voice_settings": [
                "stability": 0.6,
                "similarity_boost": 0.8,
                "style": 0.2,
                "use_speaker_boost": true
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        print("📋 Request body: \(body)")
        
        let startTime = Date()
        isGenerating = false  // Will be false once we receive first chunk
        
        print("🚀 Starting URLSession.bytes request...")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ Response is not HTTPURLResponse")
            throw StreamingError.badResponse
        }
        
        print("📡 Response received:")
        print("   - Status code: \(httpResponse.statusCode)")
        print("   - Headers: \(httpResponse.allHeaderFields)")
        
        guard httpResponse.statusCode == 200 else {
            print("❌ Bad status code: \(httpResponse.statusCode)")
            await handleElevenLabsError(httpResponse, bytes: bytes)
            throw StreamingError.badResponse
        }
        
        var buffer = Data()
        var firstChunkReceived = false
        let chunkSize = Int(sampleRate * chunkDuration) * 2 // 2 bytes per sample
        print("📦 Chunk size: \(chunkSize) bytes")
        
        var totalBytes = 0
        var chunkCount = 0
        
        print("🌊 Starting to receive bytes...")
        for try await byte in bytes {
            guard !Task.isCancelled else {
                print("⛔ Task cancelled")
                break
            }
            
            buffer.append(byte)
            totalBytes += 1
            
            if buffer.count >= chunkSize {
                if !firstChunkReceived {
                    firstChunkReceived = true
                    let latency = Date().timeIntervalSince(startTime)
                    print("⚡ First audio chunk in \(Int(latency * 1000))ms")
                    isGenerating = false
                    isSpeaking = true
                }
                
                chunkCount += 1
                let chunk = buffer.prefix(chunkSize)
                print("🔊 Processing chunk #\(chunkCount) (\(chunk.count) bytes)")
                processAudioChunkDebug(Data(chunk))
                buffer.removeFirst(chunkSize)
            }
        }
        
        print("🏁 Stream ended:")
        print("   - Total bytes: \(totalBytes)")
        print("   - Chunks processed: \(chunkCount)")
        print("   - Buffer remaining: \(buffer.count) bytes")
        
        // Process remaining data
        if !buffer.isEmpty && !Task.isCancelled {
            print("🔊 Processing final chunk (\(buffer.count) bytes)")
            processAudioChunkDebug(buffer)
        }
    }
    
    private func processAudioChunkDebug(_ data: Data) {
        print("  🎵 processAudioChunk: \(data.count) bytes")
        
        guard let playerNode = playerNode,
              let engine = engine,
              !Task.isCancelled else {
            print("  ❌ Missing playerNode/engine or task cancelled")
            return
        }
        
        print("  ✅ Player node is playing: \(playerNode.isPlaying)")
        print("  ✅ Engine is running: \(engine.isRunning)")
        
        // Call the original processing method
        processAudioChunk(data)
        print("  ✅ Chunk scheduled to player")
    }
    
    private func handleElevenLabsError(_ httpResponse: HTTPURLResponse, bytes: URLSession.AsyncBytes) async {
        print("❌ ElevenLabs API returned status: \(httpResponse.statusCode)")
        
        switch httpResponse.statusCode {
        case 401:
            print("🔑 Check your ElevenLabs API key in Config.plist")
            
        case 422:
            print("⚠️ Invalid request - check voice ID: \(cfg.elevenLabsVoiceId)")
            
        case 429:
            print("⏳ Rate limited - too many requests")
            print("📋 Rate limit headers:")
            for (key, value) in httpResponse.allHeaderFields {
                if let headerKey = key as? String,
                   headerKey.lowercased().contains("ratelimit") || headerKey.lowercased().contains("rate-limit") {
                    print("   - \(headerKey): \(value)")
                }
            }
            
        case 500:
            print("🔥 ElevenLabs server error - temporary issue")
            
        default:
            print("🤷 Unexpected status code")
        }
        
        // Try to read error body for all error types
        var errorData = Data()
        do {
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 1000 { break }
            }
            
            if let errorString = String(data: errorData, encoding: .utf8) {
                print("📋 Error response: \(errorString)")
            }
            
            if let errorJson = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any] {
                print("📋 Error JSON: \(errorJson)")
                
                if let detail = errorJson["detail"] {
                    print("   - Detail: \(detail)")
                }
                if let message = errorJson["message"] as? String {
                    print("   - Message: \(message)")
                }
            }
        } catch {
            print("⚠️ Could not read error response body")
        }
    }
}
