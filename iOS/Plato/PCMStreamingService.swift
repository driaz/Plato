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
    
    private let cfg = ConfigManager.shared
    private let baseURL = "https://api.elevenlabs.io/v1/text-to-speech"
    
    // Use 24kHz for optimal bandwidth/quality balance
    private let sampleRate: Double = 24000
    private let chunkDuration: Double = 0.05 // 50ms chunks
    
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
        
        // Create a new task for this stream
        currentTask = Task {
            await performStreaming(cleanedText)
        }
        
        // Wait for completion
        await currentTask?.value
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
            // Setup audio session
            try await setupAudioSession()
            
            // Setup audio engine
            try await setupAudioEngine()
            
            // Start the stream
            try await streamFromElevenLabs(text)
            
            // Wait for playback to complete
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s buffer
            
        } catch {
            print("❌ Streaming error: \(error)")
        }
        
        // Cleanup
        await restoreAudioSession()
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
        isGenerating = false  // Will be false once we receive first chunk
        
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
        if let int16Data = inputBuffer.int16ChannelData?[0],
           let floatData = floatBuffer.floatChannelData?[0] {
            for i in 0..<inputFrameCount {
                floatData[i] = Float(int16Data[i]) / Float(Int16.max)
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
                playerNode.scheduleBuffer(outputBuffer)
            }
        }
    }
    
    private func cleanupAudio() {
        playerNode?.stop()
        engine?.stop()
        
        playerNode = nil
        engine = nil
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
