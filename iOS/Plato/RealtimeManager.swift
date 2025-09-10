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
    private let voiceOption = "ballad"  // Warm and expressive voice
    private let volumeAmplification: Float = 1.75  // 75% louder, adjustable between 1.0-2.0
    
    // MARK: - State Management
    private var sessionId: String?
    private var conversationId: String?
    private var isConnected: Bool = false
    @Published var isAISpeaking = false
    private var lastAudioPlaybackTime: Date?
    private var responseCount = 0
    private var hasLoggedBlocked = false
    private var gracePeriodTimer: Timer?
    private var isInGracePeriod = false
    private var audioBufferCount = 0
    private var audioSentCount = 0
    private var lastLogTime = Date()
    private var lastResponseTime: Date = Date.distantPast
    private var peakAudioDuringGrace: Float = 0
    private var audioChunkCount = 0
    
    // MARK: - Latency Tracking
    private var speechStartTime: Date?
    private var firstResponseTime: Date?
    @Published var lastLatencyMs: Int = 0
    
    // MARK: - Initialization
    init() {
        // Completely empty - no audio work whatsoever
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
        // RealtimeManager deinit completed safely
    }
    
    // MARK: - Audio Setup
    private func setupAudioEngine() {
        // Setting up audio engine
        
        do {
            // Configure audio session first - this is critical
            try configureAudioSession()
            
            audioEngine = AVAudioEngine()
            audioPlayerNode = AVAudioPlayerNode()
            
            guard let engine = audioEngine,
                  let playerNode = audioPlayerNode else {
                // Failed to create audio components
                return
            }
            
            // Attach player node
            engine.attach(playerNode)
            
            // Get input node and its format
            inputNode = engine.inputNode
            _ = inputNode!.outputFormat(forBus: 0)
            
            // Create target format for Realtime API (24kHz, 16-bit, mono)
            audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                       sampleRate: Double(SessionConfig.sampleRate), 
                                       channels: 1, 
                                       interleaved: true)
            
            guard audioFormat != nil else {
                // Failed to create target audio format
                return
            }
            
            // Connect player to output (use main mixer's format for playback)
            let mainMixer = engine.mainMixerNode
            let outputFormat = mainMixer.outputFormat(forBus: 0)
            engine.connect(playerNode, to: mainMixer, format: outputFormat)
            
            // Audio engine setup successful
            
            isAudioReady = true
            
        } catch {
            // Audio engine setup failed
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
        // Audio session configured for simulator
        #else
        // Full configuration for device  
        try audioSession.setCategory(.playAndRecord, 
                                   mode: .voiceChat, 
                                   options: [.defaultToSpeaker, .allowBluetooth])
        // Audio session configured for device
        #endif
        
        try audioSession.setActive(true)
        // Audio session activated and configured
        try audioSession.overrideOutputAudioPort(.speaker)
    }
    
    // MARK: - Connection Management
    func connect() {
        print("🔗 connect() called")
        print("📊 Current connection state: \(connectionState)")
        
        guard connectionState != .connected else { 
            print("⚠️ Already connected, skipping")
            return 
        }
        
        print("🔑 API Key present: \(!apiKey.isEmpty)")
        print("🔑 API Key length: \(apiKey.count)")
        
        guard !apiKey.isEmpty else {
            print("❌ API key missing!")
            connectionState = .failed(NSError(domain: "RealtimeManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "OpenAI API key not configured"]))
            return
        }
        
        print("🔄 Setting connection state to .connecting")
        connectionState = .connecting
        avatarState = .idle
        
        print("🚀 Starting connection process...")
        
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
                // Microphone permission confirmed
                
                // Step 3: Create WebSocket connection
                self.createWebSocketConnection()
            }
        }
    }
    
    private func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            // Microphone permission already granted
            completion(true)
        case .denied:
            // Microphone permission denied
            completion(false)
        case .undetermined:
            // Requesting microphone permission
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    // Handle microphone permission result
                    completion(granted)
                }
            }
        @unknown default:
            completion(false)
        }
    }
    
    private func setupAudioEngineIfNeeded() {
        guard audioEngine == nil else { 
            // Audio engine already set up
            return 
        }
        setupAudioEngine()
    }
    
    private func createWebSocketConnection() {
        print("🌐 createWebSocketConnection() called")
        
        // Create URL with model parameter
        let urlString = "\(realtimeURL)?model=\(model)"
        print("📡 Connecting to: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            print("❌ Invalid WebSocket URL: \(urlString)")
            connectionState = .failed(NSError(domain: "RealtimeManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid WebSocket URL"]))
            return
        }
        
        print("✅ URL created successfully: \(url)")
        
        // Create request with authentication
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        print("🔑 Authorization header set")
        print("📋 Authorization: Bearer \(apiKey.prefix(10))...") // Log only first 10 chars for security
        print("📋 OpenAI-Beta: realtime=v1")
        
        // Create URL session
        let config = URLSessionConfiguration.default
        urlSession = URLSession(configuration: config)
        print("📝 URL session created")
        
        // Create WebSocket task
        webSocket = urlSession?.webSocketTask(with: request)
        print("🔌 WebSocket task created")
        
        webSocket?.resume()
        print("▶️ WebSocket task resumed")
        
        // WebSocket task created
        connectionStatusText = "WebSocket created, waiting for connection..."
        
        // Start receiving messages
        startReceivingMessages()
        print("📨 Started receiving messages")
        
        // Check connection after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            print("⏰ Connection timeout check (3s elapsed)")
            print("📊 Current connection state: \(self.connectionState)")
            
            if self.connectionState == .connecting {
                print("✅ Assuming WebSocket connected successfully (still in .connecting state)")
                self.connectionStatusText = "Connected! Sending session configuration..."
                
                // Send initial session configuration once connected
                print("📤 Sending session configuration...")
                self.sendSessionUpdate()
                
                print("🔄 Setting connection state to .connected")
                self.connectionState = .connected
                self.connectionStatusText = "Ready for conversation"
                print("🎉 Connection process completed!")
            } else {
                print("⚠️ Connection state changed during timeout period: \(self.connectionState)")
            }
        }
    }
    
    func disconnect() {
        // Disconnecting
        
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
        guard !isListening, connectionState == .connected else { 
            return 
        }
        
        // Reset AI speaking state to ensure clean start
        isAISpeaking = false
        print("🔄 Reset isAISpeaking to false on start")
        
        // Log WebSocket connection state
        print("📡 WebSocket connected: \(webSocket?.state == .running)")
        
        // Setup audio engine on demand
        setupAudioEngineIfNeeded()
        
        guard isAudioReady else {
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
        
        // Stopping audio capture
        
        isListening = false
        if avatarState == .listening {
            avatarState = .idle
        }
        
        connectionStatusText = "Connected - ready to listen"
        
        stopAudioCapture()
        stopAudioLevelMonitoring()
        
        // Don't commit if AI is still speaking to prevent response loops
        guard !isAISpeaking else { 
            print("⚠️ Blocked commit while AI speaking")
            return 
        }
        
        // Send input audio buffer commit to signal end of speech
        print("📤 COMMIT triggered from: stopListening()")
        let commitMessage: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]
        sendWebSocketMessage(commitMessage)
    }
    
    func startSpeaking() {
        isSpeaking = true
        avatarState = .speaking
        connectionStatusText = "Assistant speaking..."
    }
    
    func stopSpeaking() {
        guard isSpeaking else { return }
        
        isSpeaking = false
        if avatarState == .speaking {
            avatarState = .idle
        }
        
        connectionStatusText = "Ready to listen"
        
        // Don't stop the player node completely, just let current buffers finish
    }
    
    func interruptAI() {
        guard isAISpeaking else { 
            print("⚠️ No AI speech to interrupt")
            return 
        }
        
        print("🛑 Interrupting AI speech")
        
        // Cancel the OpenAI response
        let cancelMsg: [String: Any] = ["type": "response.cancel"]
        sendWebSocketMessage(cancelMsg)
        print("📤 Sent response.cancel to OpenAI")
        
        // Clear any pending audio
        let clearMsg: [String: Any] = ["type": "input_audio_buffer.clear"]
        sendWebSocketMessage(clearMsg)
        
        // Stop audio playback immediately
        stopAudioPlayback()
        
        // Reset states
        isAISpeaking = false
        isInGracePeriod = false
        gracePeriodTimer?.invalidate()
        gracePeriodTimer = nil
        audioChunkCount = 0
        
        print("✅ AI interrupted successfully")
    }
    
    private func stopAudioPlayback() {
        // Stop the audio player node immediately
        audioPlayerNode?.stop()
        
        // Reset speaking state
        if isSpeaking {
            isSpeaking = false
            if avatarState == .speaking {
                avatarState = .idle
            }
        }
    }
    
    // MARK: - Audio Streaming
    private func startAudioCapture() {
        guard let engine = audioEngine,
              let inputNode = inputNode else { 
            // Cannot start audio capture - engine not available
            return 
        }
        
        do {
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            // Remove any existing tap
            inputNode.removeTap(onBus: 0)
            
            // Installing audio tap
            
            // Install tap with smaller buffer for lower latency
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    
                    // VERY FIRST CHECK: Block everything if AI is speaking
                    guard !self.isAISpeaking else { 
                        self.audioLevel = 0.0
                        if !self.hasLoggedBlocked {
                            print("🎤 Microphone blocked")
                            self.hasLoggedBlocked = true
                        }
                        return // Don't process anything!
                    }
                    
                    // Additional timing check for extra safety
                    if let lastTime = self.lastAudioPlaybackTime, Date().timeIntervalSince(lastTime) < 2.5 {
                        self.audioLevel = 0.0
                        return
                    }
                    
                    self.processAudioBuffer(buffer)
                }
            }
            
            // Start the audio engine
            if !engine.isRunning {
                try engine.start()
                isAudioEngineRunning = true
            }
            
        } catch {
            // Failed to start audio capture
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
        
        inputNode.removeTap(onBus: 0)
        
        if engine.isRunning {
            engine.stop()
            isAudioEngineRunning = false
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        
        // FIRST LINE: Check if we should block completely
        guard !(isAISpeaking || isInGracePeriod) else {
            audioBufferCount += 1
            
            // During grace period, monitor peak audio levels (but still block transmission)
            if isInGracePeriod {
                let audioLevel = calculateBufferLevel(buffer)
                peakAudioDuringGrace = max(peakAudioDuringGrace, audioLevel)
            }
            
            return
        }
        
        // Calculate audio level for UI feedback and monitoring only
        updateAudioLevel(from: buffer)
        let audioLevel = calculateBufferLevel(buffer)
        
        // For ALL buffers when mic is active: send continuous audio stream
        sendContinuousAudioBuffer(buffer, audioLevel: audioLevel)
        
        // Increment counters
        audioBufferCount += 1
        audioSentCount += 1
        
        // Log metrics every 3 seconds
        let now = Date()
        if now.timeIntervalSince(lastLogTime) >= 3.0 {
            let percentage = audioBufferCount > 0 ? Int((Float(audioSentCount) / Float(audioBufferCount)) * 100) : 0
            let state = isAISpeaking ? "AI Speaking" : (isInGracePeriod ? "Grace Period" : "Active")
            print("📊 Audio: \(audioSentCount)/\(audioBufferCount) buffers (\(percentage)%), State: \(state)")
            lastLogTime = now
        }
    }
    
    private func sendContinuousAudioBuffer(_ buffer: AVAudioPCMBuffer, audioLevel: Float) {
        guard let targetFormat = audioFormat else { return }
        
        // Dynamic amplification based on RMS level
        let amplification: Float
        if audioLevel < 0.001 {
            amplification = 1.0  // Keep quiet sounds quiet
        } else if audioLevel < 0.01 {
            amplification = 4.0  // Soft speech
        } else {
            amplification = 8.0  // Normal speech
        }
        
        // Check minimum RMS gate after amplification
        let amplifiedRMS = audioLevel * amplification
        if amplifiedRMS < 0.0005 {
            // Send silence instead of amplified noise
            let silenceData = createSilenceData(targetFormat: targetFormat, frameCount: Int(buffer.frameLength))
            let base64Audio = silenceData.base64EncodedString()
            
            let audioMessage: [String: Any] = [
                "type": "input_audio_buffer.append",
                "audio": base64Audio
            ]
            
            sendWebSocketMessage(audioMessage)
            return
        }
        
        // Convert with dynamic amplification
        let convertedData = convertAudioBufferWithAmplification(buffer, to: targetFormat, amplification: amplification)
        guard !convertedData.isEmpty else { return }
        
        let base64Audio = convertedData.base64EncodedString()
        
        let audioMessage: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        
        sendWebSocketMessage(audioMessage)
    }
    
    private func sendAudioBuffer(_ buffer: AVAudioPCMBuffer, audioLevel: Float) {
        // Legacy method - replaced by sendContinuousAudioBuffer
        sendContinuousAudioBuffer(buffer, audioLevel: audioLevel)
    }
    
    private func convertAudioBufferWithAmplification(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat, amplification: Float) -> Data {
        guard let floatChannelData = buffer.floatChannelData?[0] else { return Data() }
        
        let frameCount = Int(buffer.frameLength)
        let inputSampleRate = buffer.format.sampleRate
        let targetSampleRate = targetFormat.sampleRate
        
        // Simple sample rate conversion
        let ratio = targetSampleRate / inputSampleRate
        let targetFrameCount = Int(Double(frameCount) * ratio)
        
        var int16Data = [Int16]()
        int16Data.reserveCapacity(targetFrameCount)
        
        for i in 0..<targetFrameCount {
            let sourceIndex = Int(Double(i) / ratio)
            if sourceIndex < frameCount {
                // Apply 8x amplification and clip to range -1.0 to 1.0
                let amplifiedSample = floatChannelData[sourceIndex] * amplification
                let clippedSample = max(-1.0, min(1.0, amplifiedSample))
                // Convert to Int16 with proper scaling
                int16Data.append(Int16(clippedSample * Float(Int16.max)))
            }
        }
        
        return Data(bytes: int16Data, count: int16Data.count * 2)
    }
    
    private func createSilenceData(targetFormat: AVAudioFormat, frameCount: Int) -> Data {
        // Create silence data with the target format
        let targetSampleRate = targetFormat.sampleRate
        let adjustedFrameCount = Int(Double(frameCount) * (targetSampleRate / 48000.0))  // Adjust for sample rate
        
        // Create array of zeros (silence) as Int16
        let silenceData = [Int16](repeating: 0, count: adjustedFrameCount)
        return Data(bytes: silenceData, count: silenceData.count * 2)
    }
    
    private func convertAudioBuffer(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat, amplificationFactor: Float = 1.0) -> Data {
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
                // Apply amplification and convert float32 to int16 with proper scaling
                let amplifiedSample = floatChannelData[sourceIndex] * amplificationFactor
                let sample = max(-1.0, min(1.0, amplifiedSample))
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
        
        // Converting audio format
        
        // Create input format matching API data
        guard AVAudioFormat(commonFormat: .pcmFormatInt16, 
                           sampleRate: inputSampleRate, 
                           channels: inputChannels, 
                           interleaved: true) != nil else { return nil }
        
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
        
        // Audio conversion completed
        
        return outputBuffer
    }
    
    private func playAudioDelta(_ base64Audio: String) {
        guard let audioData = Data(base64Encoded: base64Audio),
              !audioData.isEmpty else { return }
        
        // Amplify the audio for better volume
        let amplifiedData = amplifyAudioData(audioData, factor: volumeAmplification)
        
        Task { @MainActor in
            // Track latency on first audio response
            if firstResponseTime == nil, let startTime = speechStartTime {
                firstResponseTime = Date()
                let latency = firstResponseTime!.timeIntervalSince(startTime) * 1000
                lastLatencyMs = Int(latency)
                // First audio response latency tracked
                connectionStatusText = "Received audio (\(lastLatencyMs)ms)"
            }
            
            playAudioData(amplifiedData)
        }
    }
    
    private func playAudioData(_ audioData: Data) {
        guard let playerNode = audioPlayerNode,
              let engine = audioEngine else { return }
        
        // Use the main mixer's output format for playback (typically 44.1kHz stereo)
        let mainMixer = engine.mainMixerNode
        let outputFormat = mainMixer.outputFormat(forBus: 0)
        
        // Preparing audio playback
        
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
                // Failed to start engine for playback
                return
            }
        }
        
        // Start player if not already playing
        if !playerNode.isPlaying {
            playerNode.play()
            // Started audio player node
            if !isSpeaking {
                startSpeaking()
            }
        }
        
        // Schedule buffer for playback
        playerNode.scheduleBuffer(buffer) {
            // Audio buffer completed playback
        }
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
    
    private func calculateBufferLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0.0 }
        
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        
        for i in 0..<frameCount {
            sum += abs(channelData[i])
        }
        
        return sum / Float(frameCount)
    }
    
    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        
        // Don't update audio level if AI is speaking
        if isAISpeaking {
            Task { @MainActor in
                self.audioLevel = 0.0
            }
            return
        }
        
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
            // Audio engine stopped
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
                    print("❌ WebSocket receive error: \(error.localizedDescription)")
                    print("🔌 Error details: \(error)")
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
            // Received WebSocket text
            lastReceivedMessage = "Text: \(text.prefix(50))..."
            parseRealtimeMessage(text)
            
        case .data(let data):
            // Received WebSocket binary data
            lastReceivedMessage = "Binary: \(data.count) bytes"
            // Handle binary audio data if needed
            
        @unknown default:
            // Unknown WebSocket message type
            lastReceivedMessage = "Unknown message type"
        }
    }
    
    private func parseRealtimeMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }
            
            // Only log critical message types
            let criticalTypes = ["conversation.item.created", "response.created", "response.audio.delta", "response.audio.done", "response.text.delta", "response.text.done", "error"]
            if criticalTypes.contains(type) {
                print("📨 WS: \(type)")
            }
            connectionStatusText = "Received: \(type)"
            
            switch type {
            case "session.created":
                handleSessionCreated(json)
            case "session.updated":
                handleSessionUpdated(json)
            case "conversation.item.created":
                handleConversationItemCreated(json)
            case "response.audio.delta":
                audioChunkCount += 1
                handleResponseAudioDelta(json)
            case "response.audio.done":
                handleResponseAudioDone(json)
            case "response.text.delta":
                handleResponseTextDelta(json)
            case "response.text.done":
                handleResponseTextDone(json)
            case "response.created":
                handleResponseCreated(json)
            case "response.audio_transcript.done":
                break // Ignore transcript done
            case "response.content_part.done":
                break // Ignore content part done
            case "response.output_item.done":
                break // Ignore output item done
            case "response.done":
                handleResponseDone(json)
            case "rate_limits.updated":
                break // Ignore rate limits
            case "error":
                handleError(json)
            default:
                break // Silently ignore unknown message types
            }
        } catch {
            // Failed to parse WebSocket message
        }
    }
    
    // MARK: - Send Message
    func sendTextMessage(_ text: String) {
        guard connectionState == .connected else {
            connectionStatusText = "Error: Not connected"
            return
        }
        
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
                "voice": voiceOption,
                "input_audio_format": SessionConfig.inputAudioFormat,
                "output_audio_format": SessionConfig.outputAudioFormat,
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ]
            ]
        ]
        
        sendWebSocketMessage(sessionConfig)
    }
    
    private func sendWebSocketMessage(_ message: [String: Any]) {
        guard let webSocket = webSocket else { 
            // No WebSocket available for sending
            return 
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            let jsonString = String(data: data, encoding: .utf8) ?? ""
            
            // Silent message sending
            
            webSocket.send(.string(jsonString)) { error in
                Task { @MainActor in
                    if let error = error {
                        self.connectionStatusText = "Send failed: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            connectionStatusText = "Serialization failed: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Message Handlers
    private func handleSessionCreated(_ json: [String: Any]) {
        if let session = json["session"] as? [String: Any],
           let id = session["id"] as? String {
            sessionId = id
        }
    }
    
    private func handleSessionUpdated(_ json: [String: Any]) {
        // Session configuration updated
    }
    
    private func handleConversationItemCreated(_ json: [String: Any]) {
        print("🎤 Speech detected while isAISpeaking=\(isAISpeaking)")
        
        // CRITICAL: Ignore speech detection while AI is speaking
        guard !isAISpeaking else {
            print("⚠️ Ignoring speech detection - AI is speaking")
            // Clear the buffer to remove any echo
            clearInputAudioBuffer()
            return
        }
        
        // Check minimum time between responses (3 second cooldown)
        let timeSinceLastResponse = Date().timeIntervalSince(lastResponseTime)
        if timeSinceLastResponse < 3.0 {
            print("🛡️ Ignoring potential echo (too soon after last response)")
            clearInputAudioBuffer()
            return
        }
        
        // Only process real user speech
        // (Future: Add any user speech handling logic here if needed)
    }
    
    private func handleResponseCreated(_ json: [String: Any]) {
        isAISpeaking = true
        lastResponseTime = Date()  // Track when AI response begins
        print("🔄 Reset audioChunkCount to 0 at handleResponseCreated (new response)")
        audioChunkCount = 0  // Reset counter for new response
        print("🤖 AI started speaking")
        clearInputAudioBuffer()
    }
    
    private func handleResponseAudioDelta(_ json: [String: Any]) {
        if let delta = json["delta"] as? String {
            // AI is speaking - disable mic
            if !isAISpeaking {
                isAISpeaking = true
                print("🔊 isAISpeaking = true (AI Speaking - mic disabled)")
            }
            lastAudioPlaybackTime = Date()
            playAudioDelta(delta)
        }
    }
    
    private func handleResponseAudioDone(_ json: [String: Any]) {
        Task { @MainActor in
            print("📍 Calling handleAIStoppedSpeaking from response.audio.done")
            self.stopSpeaking()
            self.lastAudioPlaybackTime = Date()
            // Start grace period
            self.handleAIStoppedSpeaking()
        }
    }
    
    private func handleResponseTextDelta(_ json: [String: Any]) {
        if let delta = json["delta"] as? String {
            assistantResponse += delta
            // Track latency on first text response
            if firstResponseTime == nil, let startTime = speechStartTime {
                firstResponseTime = Date()
                let latency = firstResponseTime!.timeIntervalSince(startTime) * 1000
                lastLatencyMs = Int(latency)
                connectionStatusText = "Response received (\(lastLatencyMs)ms latency)"
            }
        }
    }
    
    private func handleResponseTextDone(_ json: [String: Any]) {
        // Text response complete
    }
    
    private func handleResponseDone(_ json: [String: Any]) {
        if let response = json["response"] as? [String: Any],
           let status = response["status"] as? String {
            
            print("📝 Response status: \(status)")
            
            // For both cancelled and completed responses, start grace period
            if status == "cancelled" {
                print("❌ Response was cancelled")
                print("📍 Calling handleAIStoppedSpeaking from response.done (cancelled)")
                handleAIStoppedSpeaking()
                return
            }
            
            if status == "completed" {
                print("✅ Response completed")
                print("📍 Calling handleAIStoppedSpeaking from response.done (completed)")
                handleAIStoppedSpeaking()
            }
        }
    }
    
    private func handleError(_ json: [String: Any]) {
        let errorMessage = json["error"] as? [String: Any] ?? [:]
        let message = errorMessage["message"] as? String ?? "Unknown error"
        // Realtime API error
        
        let error = NSError(domain: "RealtimeAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        connectionState = .failed(error)
    }
    
    // MARK: - Helper Methods
    private func amplifyAudioData(_ data: Data, factor: Float) -> Data {
        var amplifiedData = Data()
        
        // Process as 16-bit PCM samples
        data.withUnsafeBytes { rawBytes in
            let int16Ptr = rawBytes.bindMemory(to: Int16.self)
            let sampleCount = data.count / 2
            
            for i in 0..<sampleCount {
                let sample = Float(int16Ptr[i])
                let amplified = sample * factor
                
                // Clip to prevent distortion
                let clipped = max(Float(Int16.min), min(Float(Int16.max), amplified))
                let int16Value = Int16(clipped)
                
                withUnsafeBytes(of: int16Value.littleEndian) { bytes in
                    amplifiedData.append(contentsOf: bytes)
                }
            }
        }
        
        return amplifiedData
    }
    
    private func clearInputAudioBuffer() {
        let message: [String: Any] = ["type": "input_audio_buffer.clear"]
        sendWebSocketMessage(message)
    }
    
    private func commitAudioBuffer() {
        let message: [String: Any] = ["type": "input_audio_buffer.commit"]
        sendWebSocketMessage(message)
        print("📤 COMMIT message sent")
    }
    
    private func handleAIStoppedSpeaking() {
        guard gracePeriodTimer == nil else {
            print("⚠️ Grace period already active (timer exists), skipping duplicate")
            return
        }
        
        print("🔍 handleAIStoppedSpeaking called with \(audioChunkCount) chunks")
        print("   Stack trace: \(Thread.callStackSymbols[1...min(3, Thread.callStackSymbols.count-1)].joined(separator: "\n   "))")
        
        // Set states
        isAISpeaking = false
        print("🔊 isAISpeaking = false (AI stopped speaking)")
        isInGracePeriod = true
        peakAudioDuringGrace = 0  // Reset peak audio tracking
        
        // Cancel existing timer if any
        gracePeriodTimer?.invalidate()
        
        // Calculate grace period based on actual audio duration
        // Conservative estimate: 200ms per chunk for slow eloquent voice
        let estimatedDuration = Double(audioChunkCount) * 0.2

        // Add 4 second buffer for echo dissipation and safety
        let gracePeriod = estimatedDuration + 4.5

        // Log the calculation for debugging
        print("🔊 AI audio: \(audioChunkCount) chunks, ~\(String(format: "%.1f", estimatedDuration))s estimated playback")
        print("⏸️ Grace period started (\(String(format: "%.1f", gracePeriod))s)")
        
        if gracePeriod > 20.0 {
            print("⚠️ Long response detected: \(gracePeriod)s grace period")
        }

        // Reset peak tracking
        peakAudioDuringGrace = 0

        // Create timer with dynamic period
        gracePeriodTimer = Timer.scheduledTimer(withTimeInterval: gracePeriod, repeats: false) { [weak self] _ in
           guard let self = self else { return }
           self.gracePeriodTimer = nil
           self.isInGracePeriod = false
           print("📊 Peak audio during grace: \(String(format: "%.4f", self.peakAudioDuringGrace))")
           print("🎤 Mic resumed after grace period")
        }

        // Counter will be reset when new response starts (handleResponseCreated)
        // NOT here - this was the bug!
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
        You are a wise and compassionate Stoic philosopher mentor. Draw from the wisdom of Marcus Aurelius, Epictetus, and Seneca, but speak with warmth and understanding. Your role is to help users navigate life's challenges with practical Stoic principles. Keep responses concise - aim for 2-3 sentences that deliver one clear, actionable insight. Be encouraging yet honest, gentle yet direct. Remember that Stoicism is not about suppressing emotions, but understanding and working with them wisely.
        """
    }
}