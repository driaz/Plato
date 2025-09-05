//
//  RealtimeManager.swift
//  Plato
//
//  Manager for OpenAI Realtime API WebSocket connection
//  Handles bidirectional audio streaming and conversation state
//

import Foundation
import AVFoundation
import SwiftUI

// MARK: - Avatar State (for future 3D avatar integration)
enum AvatarState {
    case idle
    case listening
    case thinking
    case speaking
    case error
}

// MARK: - Realtime Connection State
enum RealtimeConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(Error)
    
    static func == (lhs: RealtimeConnectionState, rhs: RealtimeConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected):
            return true
        case (.failed, .failed):
            return true  // Simplified - could compare error details
        default:
            return false
        }
    }
}

// MARK: - Realtime Manager
@MainActor
final class RealtimeManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published var connectionState: RealtimeConnectionState = .disconnected
    @Published var avatarState: AvatarState = .idle
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var currentTranscript: String = ""
    @Published var assistantResponse: String = ""
    @Published var lastReceivedMessage: String = "None"
    @Published var connectionStatusText: String = "Ready to connect"
    @Published var audioLevel: Float = 0.0
    @Published var isAudioReady: Bool = false
    
    // MARK: - WebSocket Properties
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isReceivingMessages = false
    
    // MARK: - Audio Properties
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var inputNode: AVAudioInputNode?
    private var audioFormat: AVAudioFormat?
    private var isAudioEngineRunning: Bool = false
    private var audioLevelTimer: Timer?
    
    // MARK: - Configuration
    private let apiKey = ConfigManager.shared.openAIAPIKey
    private let realtimeURL = "wss://api.openai.com/v1/realtime"
    private let model = "gpt-4o-mini-realtime-preview"
    
    // MARK: - State Management
    private var sessionId: String?
    private var conversationId: String?
    private var isConnected: Bool = false
    
    // MARK: - Latency Tracking
    private var speechStartTime: Date?
    private var firstResponseTime: Date?
    @Published var lastLatencyMs: Int = 0
    
    // MARK: - Initialization
    init() {
        // Completely empty - no audio work whatsoever
        print("🌐 RealtimeManager initialized - WebSocket ready, audio on demand")
    }
    
    deinit {
        // Don't create async tasks in deinit as they create retain cycles
        // Just do synchronous cleanup
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession = nil
        isReceivingMessages = false
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
        // Stop audio engine synchronously
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        audioEngine = nil
        audioPlayerNode = nil
        print("🔧 RealtimeManager deinit completed safely")
    }
    
    // MARK: - Audio Setup
    private func setupAudioEngine() {
        print("🎵 Setting up audio engine...")
        
        do {
            // Configure audio session first - this is critical
            try configureAudioSession()
            
            audioEngine = AVAudioEngine()
            audioPlayerNode = AVAudioPlayerNode()
            
            guard let engine = audioEngine,
                  let playerNode = audioPlayerNode else {
                print("❌ Failed to create audio components")
                return
            }
            
            // Attach player node
            engine.attach(playerNode)
            
            // Get input node and its format
            inputNode = engine.inputNode
            let inputFormat = inputNode!.outputFormat(forBus: 0)
            
            // Create target format for Realtime API (24kHz, 16-bit, mono)
            audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                       sampleRate: Double(SessionConfig.sampleRate), 
                                       channels: 1, 
                                       interleaved: true)
            
            guard let targetFormat = audioFormat else {
                print("❌ Failed to create target audio format")
                return
            }
            
            // Connect player to output (use main mixer's format for playback)
            let mainMixer = engine.mainMixerNode
            let outputFormat = mainMixer.outputFormat(forBus: 0)
            engine.connect(playerNode, to: mainMixer, format: outputFormat)
            
            print("✅ Audio engine setup successful")
            print("   Input: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
            print("   Target: \(targetFormat.sampleRate)Hz, \(targetFormat.channelCount)ch")
            print("   Output: \(outputFormat.sampleRate)Hz, \(outputFormat.channelCount)ch")
            
            isAudioReady = true
            
        } catch {
            print("❌ Audio engine setup failed: \(error)")
            print("❌ Error details: \(error.localizedDescription)")
            isAudioReady = false
            audioEngine = nil
            audioPlayerNode = nil
            inputNode = nil
        }
    }
    
    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        
        #if targetEnvironment(simulator)
        // Simulator has limited audio session capabilities - remove .mixWithOthers for clearer audio
        try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        print("🎵 Audio session configured for simulator (NO mixWithOthers)")
        #else
        // Full configuration for device  
        try audioSession.setCategory(.playAndRecord, 
                                   mode: .voiceChat, 
                                   options: [.defaultToSpeaker, .allowBluetooth])
        print("🎵 Audio session configured for device (NO mixWithOthers)")
        #endif
        
        try audioSession.setActive(true)
        print("🎵 Audio session activated successfully")
        
        // Debug audio session state
        print("🔍 Audio session debug:")
        print("   Category: \(audioSession.category.rawValue)")
        print("   Mode: \(audioSession.mode.rawValue)")  
        print("   Output volume: \(audioSession.outputVolume)")
        
        // Force output to speaker
        try audioSession.overrideOutputAudioPort(.speaker)
        print("🔊 Forced output to speaker")
    }
    
    // MARK: - Connection Management
    func connect() {
        guard connectionState != .connected else { return }
        guard !apiKey.isEmpty else {
            connectionState = .failed(NSError(domain: "RealtimeManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key not configured"]))
            return
        }
        
        connectionState = .connecting
        avatarState = .idle
        
        print("🌐 RealtimeManager: Connecting to Realtime API")
        
        // Step 1: Check microphone permission first
        checkMicrophonePermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                
                if !granted {
                    self.connectionState = .failed(NSError(domain: "RealtimeManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]))
                    return
                }
                
                // Step 2: Audio will be setup on-demand when user taps Start
                // For now, just mark that we have microphone permission
                print("✅ Microphone permission confirmed")
                
                // Step 3: Create WebSocket connection
                self.createWebSocketConnection()
            }
        }
    }
    
    private func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            print("✅ Microphone permission already granted")
            completion(true)
        case .denied:
            print("❌ Microphone permission denied")
            completion(false)
        case .undetermined:
            print("🤔 Requesting microphone permission")
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    print(granted ? "✅ Microphone permission granted" : "❌ Microphone permission denied")
                    completion(granted)
                }
            }
        @unknown default:
            completion(false)
        }
    }
    
    private func setupAudioEngineIfNeeded() {
        guard audioEngine == nil else { 
            print("🎵 Audio engine already set up")
            return 
        }
        setupAudioEngine()
    }
    
    private func createWebSocketConnection() {
        // Create URL with model parameter
        guard let url = URL(string: "\(realtimeURL)?model=\(model)") else {
            connectionState = .failed(NSError(domain: "RealtimeManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid WebSocket URL"]))
            return
        }
        
        // Create request with authentication
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        // Create URL session
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
        
        // Create WebSocket task
        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()
        
        print("🔌 WebSocket task created, starting to receive messages...")
        connectionStatusText = "WebSocket created, waiting for connection..."
        
        // Start receiving messages
        startReceivingMessages()
        
        // Check connection after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.connectionState == .connecting {
                print("✅ WebSocket connected successfully")
                self.connectionStatusText = "Connected! Sending session configuration..."
                // Send initial session configuration once connected
                self.sendSessionUpdate()
                self.connectionState = .connected
                self.connectionStatusText = "Ready for conversation"
            }
        }
    }
    
    func disconnect() {
        print("RealtimeManager: Disconnecting")
        
        stopListening()
        stopSpeaking()
        
        isReceivingMessages = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession = nil
        
        connectionState = .disconnected
        avatarState = .idle
        isConnected = false
    }
    
    // MARK: - Audio Control
    func startListening() {
        print("🎤 startListening() called")
        print("   isListening: \(isListening)")
        print("   connectionState: \(connectionState)")
        
        guard !isListening, connectionState == .connected else { 
            print("⚠️ Cannot start listening - not connected or already listening")
            return 
        }
        
        print("🎤 Starting audio capture...")
        
        // Setup audio engine on demand
        setupAudioEngineIfNeeded()
        
        print("   isAudioReady: \(isAudioReady)")
        guard isAudioReady else {
            print("❌ Cannot start listening - audio engine not ready")
            connectionStatusText = "Audio setup failed"
            return
        }
        
        isListening = true
        avatarState = .listening
        assistantResponse = "" // Clear previous response
        speechStartTime = Date() // Start tracking immediately
        firstResponseTime = nil
        lastLatencyMs = 0
        connectionStatusText = "Listening..."
        
        startAudioCapture()
        startAudioLevelMonitoring()
    }
    
    func stopListening() {
        guard isListening else { return }
        
        print("🎤 Stopping audio capture")
        
        isListening = false
        if avatarState == .listening {
            avatarState = .idle
        }
        
        connectionStatusText = "Connected - ready to listen"
        
        stopAudioCapture()
        stopAudioLevelMonitoring()
        
        // Send input audio buffer commit to signal end of speech
        let commitMessage: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]
        sendWebSocketMessage(commitMessage)
    }
    
    func startSpeaking() {
        isSpeaking = true
        avatarState = .speaking
        connectionStatusText = "Assistant speaking..."
        
        print("🔊 Assistant started speaking")
    }
    
    func stopSpeaking() {
        guard isSpeaking else { return }
        
        print("🔊 Assistant stopped speaking")
        
        isSpeaking = false
        if avatarState == .speaking {
            avatarState = .idle
        }
        
        connectionStatusText = "Ready to listen"
        
        // Don't stop the player node completely, just let current buffers finish
    }
    
    // MARK: - Audio Streaming
    private func startAudioCapture() {
        guard let engine = audioEngine,
              let inputNode = inputNode else { 
            print("⚠️ Cannot start audio capture - engine not available")
            return 
        }
        
        do {
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // Remove any existing tap
            inputNode.removeTap(onBus: 0)
            
            print("🎵 Installing audio tap with buffer size 1024")
            
            // Install tap with smaller buffer for lower latency
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                Task { @MainActor in
                    self?.processAudioBuffer(buffer)
                }
            }
            
            // Start the audio engine
            if !engine.isRunning {
                try engine.start()
                isAudioEngineRunning = true
                print("✅ Audio engine started")
            }
            
            print("✅ Audio capture active at \(inputFormat.sampleRate)Hz")
            
        } catch {
            print("❌ Failed to start audio capture: \(error)")
            Task { @MainActor in
                self.isListening = false
                self.avatarState = .error
                self.connectionStatusText = "Audio capture failed: \(error.localizedDescription)"
            }
        }
    }
    
    private func stopAudioCapture() {
        guard let engine = audioEngine,
              let inputNode = inputNode else { return }
        
        print("🎵 Stopping audio capture")
        inputNode.removeTap(onBus: 0)
        
        if engine.isRunning {
            engine.stop()
            isAudioEngineRunning = false
            print("🎵 Audio engine stopped")
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        
        // Calculate audio level for UI feedback
        updateAudioLevel(from: buffer)
        
        // Convert and send audio to WebSocket
        sendAudioBuffer(buffer)
    }
    
    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let targetFormat = audioFormat else { return }
        
        // Convert buffer to target format (24kHz, 16-bit, mono)
        let convertedData = convertAudioBuffer(buffer, to: targetFormat)
        guard !convertedData.isEmpty else { return }
        
        let base64Audio = convertedData.base64EncodedString()
        
        let audioMessage: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        
        sendWebSocketMessage(audioMessage)
    }
    
    private func convertAudioBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> Data {
        guard let floatChannelData = buffer.floatChannelData?[0] else { return Data() }
        
        let frameCount = Int(buffer.frameLength)
        let inputSampleRate = buffer.format.sampleRate
        let targetSampleRate = targetFormat.sampleRate
        
        // Simple sample rate conversion (for production, use AVAudioConverter)
        let ratio = targetSampleRate / inputSampleRate
        let targetFrameCount = Int(Double(frameCount) * ratio)
        
        var int16Data = [Int16]()
        int16Data.reserveCapacity(targetFrameCount)
        
        for i in 0..<targetFrameCount {
            let sourceIndex = Int(Double(i) / ratio)
            if sourceIndex < frameCount {
                // Convert float32 to int16 with proper scaling
                let sample = max(-1.0, min(1.0, floatChannelData[sourceIndex]))
                int16Data.append(Int16(sample * 32767.0))
            }
        }
        
        return Data(bytes: int16Data, count: int16Data.count * 2)
    }
    
    private func convertApiAudioToOutputFormat(_ audioData: Data, outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        // API sends PCM16 mono at 24kHz, we need to convert to output format (usually 44.1kHz stereo)
        let inputSampleRate: Double = 24000 // API format
        let inputChannels: UInt32 = 1 // Mono
        
        let outputSampleRate = outputFormat.sampleRate
        let outputChannels = outputFormat.channelCount
        
        print("🔄 Converting audio format:")
        print("   Input: \(inputSampleRate)Hz, \(inputChannels)ch, PCM16, \(audioData.count) bytes")
        print("   Output: \(outputSampleRate)Hz, \(outputChannels)ch, \(outputFormat.commonFormat.rawValue)")
        print("   Output format description: \(outputFormat)")
        
        // Create input format matching API data
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                            sampleRate: inputSampleRate, 
                                            channels: inputChannels, 
                                            interleaved: true) else { return nil }
        
        // Calculate frame counts
        let inputFrameCount = audioData.count / 2 // 2 bytes per Int16
        let sampleRateRatio = outputSampleRate / inputSampleRate
        let outputFrameCount = Int(Double(inputFrameCount) * sampleRateRatio)
        
        // Create output buffer
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, 
                                                frameCapacity: AVAudioFrameCount(outputFrameCount)) else { return nil }
        
        // Convert audio data - Handle both Float32 and Int16 output formats
        audioData.withUnsafeBytes { bytes in
            guard let inputPointer = bytes.bindMemory(to: Int16.self).baseAddress else { return }
            
            if outputFormat.commonFormat == .pcmFormatFloat32 {
                // Output format is Float32 - convert Int16 to Float32
                if outputChannels == 1 {
                    // Mono Float32 output
                    guard let outputPointer = outputBuffer.floatChannelData?[0] else { return }
                    for i in 0..<outputFrameCount {
                        let inputIndex = Int(Double(i) / sampleRateRatio)
                        if inputIndex < inputFrameCount {
                            // Convert Int16 to Float32 (normalize to -1.0 to 1.0)
                            outputPointer[i] = Float(inputPointer[inputIndex]) / 32768.0
                        }
                    }
                } else if outputChannels == 2 {
                    // Stereo Float32 output - duplicate mono to both channels
                    guard let leftPointer = outputBuffer.floatChannelData?[0],
                          let rightPointer = outputBuffer.floatChannelData?[1] else { return }
                    for i in 0..<outputFrameCount {
                        let inputIndex = Int(Double(i) / sampleRateRatio)
                        if inputIndex < inputFrameCount {
                            // Convert Int16 to Float32 and duplicate to both channels
                            let sample = Float(inputPointer[inputIndex]) / 32768.0
                            leftPointer[i] = sample
                            rightPointer[i] = sample
                        }
                    }
                }
            } else if outputFormat.commonFormat == .pcmFormatInt16 {
                // Output format is Int16 - direct copy
                if outputChannels == 1 {
                    // Mono Int16 output
                    guard let outputPointer = outputBuffer.int16ChannelData?[0] else { return }
                    for i in 0..<outputFrameCount {
                        let inputIndex = Int(Double(i) / sampleRateRatio)
                        if inputIndex < inputFrameCount {
                            outputPointer[i] = inputPointer[inputIndex]
                        }
                    }
                } else if outputChannels == 2 {
                    // Stereo Int16 output - duplicate mono to both channels
                    guard let leftPointer = outputBuffer.int16ChannelData?[0],
                          let rightPointer = outputBuffer.int16ChannelData?[1] else { return }
                    for i in 0..<outputFrameCount {
                        let inputIndex = Int(Double(i) / sampleRateRatio)
                        if inputIndex < inputFrameCount {
                            let sample = inputPointer[inputIndex]
                            leftPointer[i] = sample
                            rightPointer[i] = sample
                        }
                    }
                }
            }
        }
        
        outputBuffer.frameLength = AVAudioFrameCount(outputFrameCount)
        
        // Debug: Check if we produced valid audio data
        print("✅ Audio conversion completed:")
        print("   Output buffer frame length: \(outputBuffer.frameLength)")
        print("   Output buffer frame capacity: \(outputBuffer.frameCapacity)")
        
        if outputFormat.commonFormat == .pcmFormatFloat32 {
            if let channelData = outputBuffer.floatChannelData?[0] {
                let firstSample = channelData[0]
                let midSample = outputFrameCount > 100 ? channelData[100] : 0.0
                print("   Sample data (Float32): first=\(firstSample), mid=\(midSample)")
            }
        } else if outputFormat.commonFormat == .pcmFormatInt16 {
            if let channelData = outputBuffer.int16ChannelData?[0] {
                let firstSample = channelData[0]
                let midSample = outputFrameCount > 100 ? channelData[100] : 0
                print("   Sample data (Int16): first=\(firstSample), mid=\(midSample)")
            }
        }
        
        return outputBuffer
    }
    
    private func playAudioDelta(_ base64Audio: String) {
        guard let audioData = Data(base64Encoded: base64Audio),
              !audioData.isEmpty else { return }
        
        Task { @MainActor in
            // Track latency on first audio response
            if firstResponseTime == nil, let startTime = speechStartTime {
                firstResponseTime = Date()
                let latency = firstResponseTime!.timeIntervalSince(startTime) * 1000
                lastLatencyMs = Int(latency)
                print("⚡ First audio response latency: \(lastLatencyMs)ms")
                connectionStatusText = "Received audio (\(lastLatencyMs)ms)"
            }
            
            playAudioData(audioData)
        }
    }
    
    private func playAudioData(_ audioData: Data) {
        guard let playerNode = audioPlayerNode,
              let engine = audioEngine else { return }
        
        // Use the main mixer's output format for playback (typically 44.1kHz stereo)
        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)
        
        print("🔊 Preparing audio playback:")
        print("   Output format: \(outputFormat.sampleRate)Hz, \(outputFormat.channelCount)ch")
        print("   Received data: \(audioData.count) bytes")
        
        // Create audio buffer from received data (API sends mono PCM16 at 24kHz)
        let receivedFrameCount = audioData.count / 2 // 2 bytes per Int16
        guard receivedFrameCount > 0 else { return }
        
        // Convert from API format (24kHz mono) to output format (44.1kHz stereo)
        guard let convertedBuffer = convertApiAudioToOutputFormat(audioData, outputFormat: outputFormat) else { return }
        
        let buffer = convertedBuffer
        
        // Ensure engine is running for playback
        if !engine.isRunning {
            do {
                try engine.start()
                isAudioEngineRunning = true
            } catch {
                print("❌ Failed to start engine for playback: \(error)")
                return
            }
        }
        
        // Start player if not already playing
        if !playerNode.isPlaying {
            playerNode.play()
            print("🔊 Started audio player node")
            if !isSpeaking {
                startSpeaking()
            }
        }
        
        // Debug player state
        print("🔍 Audio player debug:")
        print("   Player is playing: \(playerNode.isPlaying)")
        print("   Buffer frame count: \(buffer.frameLength)")
        print("   Buffer format: \(buffer.format)")
        
        // Schedule buffer for playback
        playerNode.scheduleBuffer(buffer) {
            print("🎵 Audio buffer completed playback")
        }
        
        print("🔊 Scheduled audio buffer for playback")
    }
    
    // MARK: - Audio Level Monitoring
    private func startAudioLevelMonitoring() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            // Audio level is updated in processAudioBuffer via updateAudioLevel
            // Timer just ensures regular updates, actual level is set by audio processing
        }
    }
    
    private func stopAudioLevelMonitoring() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
        audioLevel = 0.0
    }
    
    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        
        for i in 0..<frameCount {
            sum += abs(channelData[i])
        }
        
        let average = sum / Float(frameCount)
        let level = min(1.0, average * 10) // Scale and clamp to 0-1
        
        Task { @MainActor in
            self.audioLevel = level
        }
    }
    
    private func stopAudioEngine() {
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            isAudioEngineRunning = false
            print("🎵 Audio engine stopped")
        }
    }
    
    // MARK: - Message Receiving
    private func startReceivingMessages() {
        guard !isReceivingMessages else { return }
        isReceivingMessages = true
        receiveMessage()
    }
    
    private func receiveMessage() {
        guard isReceivingMessages else { return }
        
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                
                switch result {
                case .success(let message):
                    self.handleWebSocketMessage(message)
                    // Continue receiving if still connected
                    if self.isReceivingMessages {
                        self.receiveMessage()
                    }
                    
                case .failure(let error):
                    print("❌ WebSocket receive error: \(error)")
                    self.connectionStatusText = "Connection failed: \(error.localizedDescription)"
                    self.connectionState = .failed(error)
                    self.isReceivingMessages = false
                }
            }
        }
    }
    
    // MARK: - Message Handling
    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            print("📥 Received WebSocket text: \(text.prefix(200))...")
            lastReceivedMessage = "Text: \(text.prefix(50))..."
            parseRealtimeMessage(text)
            
        case .data(let data):
            print("📥 Received WebSocket binary data: \(data.count) bytes")
            lastReceivedMessage = "Binary: \(data.count) bytes"
            // Handle binary audio data if needed
            
        @unknown default:
            print("❓ Unknown WebSocket message type")
            lastReceivedMessage = "Unknown message type"
        }
    }
    
    private func parseRealtimeMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }
            
            print("📋 Realtime message type: \(type)")
            connectionStatusText = "Received: \(type)"
            
            switch type {
            case "session.created":
                handleSessionCreated(json)
            case "session.updated":
                handleSessionUpdated(json)
            case "conversation.item.created":
                handleConversationItemCreated(json)
            case "response.audio.delta":
                handleResponseAudioDelta(json)
            case "response.audio.done":
                handleResponseAudioDone(json)
            case "response.text.delta":
                handleResponseTextDelta(json)
            case "response.text.done":
                handleResponseTextDone(json)
            case "error":
                handleError(json)
            default:
                print("Unknown message type: \(type)")
            }
        } catch {
            print("Failed to parse WebSocket message: \(error)")
        }
    }
    
    // MARK: - Send Message
    func sendTextMessage(_ text: String) {
        guard connectionState == .connected else {
            print("❌ Cannot send message - not connected")
            connectionStatusText = "Error: Not connected"
            return
        }
        
        print("📤 Sending test message: \(text)")
        connectionStatusText = "Sending test message..."
        
        let testTime = Date()
        
        // Send a simple conversation item
        let message: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ]
        
        sendWebSocketMessage(message)
        
        // Trigger response generation
        let responseMessage: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["text"]
            ]
        ]
        
        sendWebSocketMessage(responseMessage)
        
        // Track latency
        speechStartTime = testTime
        connectionStatusText = "Message sent, waiting for response..."
    }
    
    // MARK: - Session Configuration
    private func sendSessionUpdate() {
        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": SessionConfig.stoicInstructions,
                "voice": SessionConfig.voice,
                "input_audio_format": SessionConfig.inputAudioFormat,
                "output_audio_format": SessionConfig.outputAudioFormat,
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 800
                ]
            ]
        ]
        
        sendWebSocketMessage(sessionConfig)
    }
    
    private func sendWebSocketMessage(_ message: [String: Any]) {
        guard let webSocket = webSocket else { 
            print("❌ No WebSocket available for sending")
            return 
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            
            print("📤 Sending: \(jsonString.prefix(200))...")
            
            webSocket.send(.string(jsonString)) { error in
                Task { @MainActor in
                    if let error = error {
                        print("❌ WebSocket send error: \(error)")
                        self.connectionStatusText = "Send failed: \(error.localizedDescription)"
                    } else {
                        print("✅ Message sent successfully")
                    }
                }
            }
        } catch {
            print("❌ Failed to serialize message: \(error)")
            connectionStatusText = "Serialization failed: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Message Handlers
    private func handleSessionCreated(_ json: [String: Any]) {
        if let session = json["session"] as? [String: Any],
           let id = session["id"] as? String {
            sessionId = id
            print("Session created with ID: \(id)")
        }
    }
    
    private func handleSessionUpdated(_ json: [String: Any]) {
        print("Session configuration updated")
    }
    
    private func handleConversationItemCreated(_ json: [String: Any]) {
        if let item = json["item"] as? [String: Any],
           let type = item["type"] as? String {
            print("Conversation item created: \(type)")
        }
    }
    
    private func handleResponseAudioDelta(_ json: [String: Any]) {
        if let delta = json["delta"] as? String {
            // Handle audio chunk - this will be implemented in audio streaming
            print("Received audio delta: \(delta.count) chars")
            playAudioDelta(delta)
        }
    }
    
    private func handleResponseAudioDone(_ json: [String: Any]) {
        print("🔊 Audio response complete")
        Task { @MainActor in
            self.stopSpeaking()
        }
    }
    
    private func handleResponseTextDelta(_ json: [String: Any]) {
        if let delta = json["delta"] as? String {
            assistantResponse += delta
            print("💬 Text delta: \(delta)")
            
            // Track latency on first text response
            if firstResponseTime == nil, let startTime = speechStartTime {
                firstResponseTime = Date()
                let latency = firstResponseTime!.timeIntervalSince(startTime) * 1000
                lastLatencyMs = Int(latency)
                print("⚡ First text response latency: \(lastLatencyMs)ms")
                connectionStatusText = "Response received (\(lastLatencyMs)ms latency)"
            }
        }
    }
    
    private func handleResponseTextDone(_ json: [String: Any]) {
        print("Text response complete: \(assistantResponse)")
    }
    
    private func handleError(_ json: [String: Any]) {
        let errorMessage = json["error"] as? [String: Any] ?? [:]
        let message = errorMessage["message"] as? String ?? "Unknown error"
        print("Realtime API error: \(message)")
        
        let error = NSError(domain: "RealtimeAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        connectionState = .failed(error)
    }
}

// MARK: - Extensions for Configuration
extension RealtimeManager {
    struct SessionConfig {
        static let model: String = "gpt-4o-mini-realtime-preview"
        static let voice: String = "alloy"
        static let inputAudioFormat: String = "pcm16"
        static let outputAudioFormat: String = "pcm16"
        static let sampleRate: Int = 24000
        
        static let stoicInstructions: String = """
        You are Plato, an AI philosophical guide inspired by ancient Stoic wisdom, primarily Marcus Aurelius, Epictetus, and Seneca. 

        Your core principles:
        - Speak with warm authority and gentle wisdom
        - Focus on what we can control vs. what we cannot
        - Emphasize virtue, resilience, and inner peace
        - Use practical examples and analogies
        - Keep responses conversational and accessible
        - Be encouraging yet realistic about life's challenges

        Respond naturally in a conversational tone, as if you're having a thoughtful discussion with a friend seeking guidance. Keep responses concise but meaningful, typically 1-3 sentences unless deeper explanation is needed.

        Remember: You help people find strength within themselves, not give them external solutions to control.
        """
    }
}