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
        let flowId = Logger.shared.startFlow("PCM_Stream: \(text.prefix(30))...")
        
        // Cancel any existing stream
        stopSpeaking()
        
        guard cfg.hasElevenLabs else {
            Logger.shared.log("❌ ElevenLabs not configured", category: .tts, level: .error)
            Logger.shared.endFlow(flowId, name: "PCM_Stream")
            return
        }
        
        // Clean the text
        let cleanedText = cleanText(text)
        guard !cleanedText.isEmpty else {
            Logger.shared.log("Empty text after cleaning", category: .tts, level: .warning)
            Logger.shared.endFlow(flowId, name: "PCM_Stream")
            return
        }
        
//        // 🎯 LOG EXACTLY WHAT ELEVENLABS WILL RECEIVE - REVIEWING CLEANED TEXT
//        Logger.shared.log("🎯 ElevenLabs input text (\(cleanedText.count) chars): '\(cleanedText)'", category: .tts, level: .info)
//        
//        // Log as hex to see any hidden characters
//        if let data = cleanedText.data(using: .utf8) {
//            let hexString = data.map { String(format: "%02x", $0) }.joined(separator: " ")
//            Logger.shared.log("🎯 ElevenLabs input (first 100 hex): '\(hexString.prefix(300))'", category: .tts, level: .debug)
//        }
//        
        Logger.shared.log("Starting PCM stream - text length: \(cleanedText.count)", category: .tts, level: .debug)
        
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
        Logger.shared.log("🔊 PCMStreamingService - playback complete, isSpeaking = false", category: .tts)
    }
    
    /// Stop any ongoing speech
    func stopSpeaking() {
        Logger.shared.log("Stopping PCM streaming", category: .tts, level: .debug)

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
            Logger.shared.startTimer("PCM_Engine_Setup")
            try await setupAudioEngine()
            Logger.shared.endTimer("PCM_Engine_Setup")
            
            // Start the stream
            Logger.shared.startTimer("PCM_Streaming_Total")
            try await streamFromElevenLabs(text)
            
            // Wait for actual playback to complete
            Logger.shared.log("Waiting for playback completion...", category: .tts, level: .debug)
            await withCheckedContinuation { continuation in
                self.playbackCompletionContinuation = continuation
                
                // Check if playback already completed (for very short audio)
                if self.scheduledBufferCount == 0 && self.isStreamingComplete {
                    continuation.resume()
                }
            }
            Logger.shared.endTimer("PCM_Streaming_Total")

            // Add a small buffer after playback completes
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
            Logger.shared.log("Post-playback buffer complete (500ms)", category: .tts, level: .debug)

            
        } catch {
            Logger.shared.log("❌ Streaming error: \(error)", category: .tts, level: .error)
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
        
        Logger.shared.log("Audio session configured for PCM playback", category: .audio, level: .debug)
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
            
            Logger.shared.log("Audio session restored to: \(savedCategory)", category: .audio, level: .debug)
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
        
        Logger.shared.log("✅ PCM engine ready (24kHz → \(Int(outputFormat.sampleRate))Hz)", category: .tts)
    }
    
    private func streamFromElevenLabs(_ text: String) async throws {
        // Reset state for new stream
        isStreamingComplete = false
        scheduledBufferCount = 0
        
        let url = URL(string: "\(baseURL)/\(cfg.elevenLabsVoiceId)/stream?output_format=pcm_24000")!
        Logger.shared.log("🎤 Using voice ID: \(cfg.elevenLabsVoiceId)", category: .tts, level: .debug)
        
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
        
        Logger.shared.startTimer("ElevenLabs_API_Request")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw StreamingError.badResponse
        }
        
        Logger.shared.log("ElevenLabs response: \(httpResponse.statusCode)", category: .network, level: .debug)
        
        guard httpResponse.statusCode == 200 else {
            Logger.shared.log("❌ ElevenLabs API error: \(httpResponse.statusCode)", category: .network, level: .error)
            throw StreamingError.badResponse
        }
        
        var buffer = Data()
        var firstChunkReceived = false
        let chunkSize = Int(sampleRate * chunkDuration) * 2 // 2 bytes per sample
        var totalBytes = 0
        var chunkCount = 0
        
        for try await byte in bytes {
            guard !Task.isCancelled else {
                Logger.shared.log("Stream cancelled", category: .tts, level: .warning)
                break
            }
            
            buffer.append(byte)
            totalBytes += 1
            
            if buffer.count >= chunkSize {
                if !firstChunkReceived {
                    firstChunkReceived = true
                    let latency = Date().timeIntervalSince(startTime)
                    Logger.shared.endTimer("ElevenLabs_API_Request")
                    Logger.shared.log("⚡ First audio in \(Int(latency * 1000))ms", category: .tts)
                    isGenerating = false
                    isSpeaking = true
                }
                
                chunkCount += 1
                let chunk = buffer.prefix(chunkSize)
                processAudioChunk(Data(chunk))
                buffer.removeFirst(chunkSize)
                
                // Log progress every 100 chunks (5 seconds of audio)
                if chunkCount % 100 == 0 {
                    Logger.shared.log("Streaming progress: \(chunkCount / 20)s elapsed, \(totalBytes / 1000)KB received",
                                     category: .tts, level: .debug)
                }
            }
        }
        
        // Process remaining data
        if !buffer.isEmpty && !Task.isCancelled {
            processAudioChunk(buffer)
        }
        
        // Mark streaming as complete
        isStreamingComplete = true
        Logger.shared.log("📊 Streaming complete - \(scheduledBufferCount) buffers pending playback", category: .tts)
        
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
        let volumeBoost: Float = 1.5  // Amplification factor (adjust as needed)
        
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
        
        Logger.shared.log("Audio engine cleaned up", category: .audio, level: .debug)
    }
    
    private func signalPlaybackComplete() {
        Logger.shared.log("🎵 All audio buffers played - signaling completion", category: .tts)
        playbackCompletionContinuation?.resume()
        playbackCompletionContinuation = nil
    }
    
    private func cleanText(_ text: String) -> String {
        
        var cleaned = text

            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "\n\n", with: ". ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
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
    
}
