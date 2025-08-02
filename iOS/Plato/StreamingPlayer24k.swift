////
////  StreamingPlayer24k.swift
////  Plato
////
////  24kHz PCM streaming player with its own audio engine
////
//
//import Foundation
//import AVFoundation
//
///// Thread-safe buffer queue management
//private actor BufferQueue {
//    private var buffers: [AVAudioPCMBuffer] = []
//    
//    func append(_ buffer: AVAudioPCMBuffer) {
//        buffers.append(buffer)
//    }
//    
//    func removeFirst() -> AVAudioPCMBuffer? {
//        guard !buffers.isEmpty else { return nil }
//        return buffers.removeFirst()
//    }
//    
//    func removeAll() {
//        buffers.removeAll()
//    }
//    
//    var count: Int {
//        buffers.count
//    }
//    
//    var isEmpty: Bool {
//        buffers.isEmpty
//    }
//}
//
///// Manages real-time PCM audio streaming with its own audio engine
//final class StreamingPlayer24k: NSObject {
//    // Audio components
//    private var engine: AVAudioEngine?
//    private var playerNode: AVAudioPlayerNode?
//    private var eq: AVAudioUnitEQ?
//    
//    // State management
//    private var isSettingUpEngine = false
//    private var isPlaying = false
//    private var totalFramesScheduled: AVAudioFramePosition = 0
//    private let bufferQueue = BufferQueue()
//    
//    // Configuration
//    private let sampleRate: Double = 24_000
//    private let channelCount: AVAudioChannelCount = 1
//    private let bufferDurationMs: Double = 100  // 100ms chunks for low latency
//    private let minBuffersBeforePlay = 2  // Start playing after 200ms buffered
//    
//    // Format
//    private lazy var streamFormat: AVAudioFormat = {
//        AVAudioFormat(commonFormat: .pcmFormatFloat32,
//                     sampleRate: sampleRate,
//                     channels: channelCount,
//                     interleaved: false)!
//    }()
//    
//    // Callback
//    var onPlaybackComplete: (() -> Void)?
//    
//    override init() {
//        super.init()
//        print("🎵 StreamingPlayer24k initialized")
//    }
//    
//    // MARK: - Setup
//    
//    private func ensureEngineReady() async throws {
//        guard engine == nil else { return }
//        
//        // Request TTS mode and wait for it to be ready
//        try await MainActor.run {
//            try AudioCoordinator.shared.requestTextToSpeechMode()
//        }
//        
//        // Longer delay to ensure audio session is fully ready
//        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
//        
//        try await MainActor.run {
//            do {
//                // Configure audio session specifically for playback
//                let session = AVAudioSession.sharedInstance()
//                try session.setCategory(.playback, mode: .default, options: [])
//                try session.setActive(true)
//                
//                // Create engine and nodes
//                let newEngine = AVAudioEngine()
//                let newPlayerNode = AVAudioPlayerNode()
//                let newEQ = AVAudioUnitEQ(numberOfBands: 1)
//                newEQ.globalGain = 12.0
//                
//                // Attach nodes
//                newEngine.attach(newPlayerNode)
//                newEngine.attach(newEQ)
//                
//                // Get output format - this should now be valid
//                let outputFormat = newEngine.outputNode.outputFormat(forBus: 0)
//                
//                // Validate format
//                guard outputFormat.sampleRate > 0 && outputFormat.channelCount > 0 else {
//                    print("❌ Invalid output format: \(outputFormat)")
//                    AudioCoordinator.shared.releaseCurrentMode()
//                    return
//                }
//                
//                let nodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
//                                              sampleRate: outputFormat.sampleRate,
//                                              channels: 1,
//                                              interleaved: false)!
//                
//                // Connect nodes
//                newEngine.connect(newPlayerNode, to: newEQ, format: nodeFormat)
//                newEngine.connect(newEQ, to: newEngine.mainMixerNode, format: nil)
//                
//                // Prepare and start
//                newEngine.prepare()
//                try newEngine.start()
//                
//                self.engine = newEngine
//                self.playerNode = newPlayerNode
//                self.eq = newEQ
//                
//                print("🎵 StreamingPlayer24k engine started successfully")
//                print("📋 Output format: \(outputFormat)")
//                print("📋 Node format: \(nodeFormat)")
//            } catch {
//                print("❌ Failed to configure audio for TTS: \(error)")
//                AudioCoordinator.shared.releaseCurrentMode()
//                throw error
//            }
//        }
//    }
//    
//    // MARK: - Public API
//    
//    /// Feed PCM data from ElevenLabs stream
//    func feedAudioData(_ data: Data) {
//        Task {
//            do {
//                // Only setup engine once, not on every data chunk
//                if engine == nil && !isSettingUpEngine {
//                    isSettingUpEngine = true
//                    try await ensureEngineReady()
//                    isSettingUpEngine = false
//                }
//                
//                guard engine != nil else {
//                    print("❌ Engine not ready, dropping audio data")
//                    return
//                }
//                
//                guard let buffer = createPCMBuffer(from: data) else {
//                    print("❌ Failed to create PCM buffer from data")
//                    return
//                }
//                
//                await bufferQueue.append(buffer)
//                let queueSize = await bufferQueue.count
//                
//                // Start playback when we have enough buffered
//                if !isPlaying && queueSize >= minBuffersBeforePlay {
//                    await startPlayback()
//                }
//                
//                // Schedule available buffers
//                await scheduleNextBuffers()
//            } catch {
//                print("❌ Error feeding audio data: \(error)")
//                isSettingUpEngine = false
//            }
//        }
//    }
//    
//    /// Signal end of stream
//    func finishStreaming() {
//        Task {
//            // Schedule any remaining buffers
//            await scheduleNextBuffers()
//            
//            // Mark stream as complete after last buffer
//            if let playerNode = playerNode, isPlaying {
//                let lastFrameTime = AVAudioTime(sampleTime: totalFramesScheduled,
//                                               atRate: streamFormat.sampleRate)
//                
//                await MainActor.run {
//                    playerNode.scheduleBuffer(AVAudioPCMBuffer(pcmFormat: streamFormat,
//                                                               frameCapacity: 1)!,
//                                             at: lastFrameTime,
//                                             options: []) { [weak self] in
//                        self?.handlePlaybackComplete()
//                    }
//                }
//            }
//        }
//    }
//    
//    /// Stop playback immediately
//    func stop() {
//        Task { @MainActor in
//            playerNode?.stop()
//            
//            if let engine = engine, engine.isRunning {
//                engine.stop()
//            }
//            
//            engine = nil
//            playerNode = nil
//            eq = nil
//            
//            await bufferQueue.removeAll()
//            
//            isPlaying = false
//            totalFramesScheduled = 0
//            
//            // Release audio mode
//            AudioCoordinator.shared.releaseCurrentMode()
//            
//            print("🛑 StreamingPlayer24k stopped")
//        }
//    }
//    
//    // MARK: - Private Methods
//    
//    private func createPCMBuffer(from data: Data) -> AVAudioPCMBuffer? {
//        // ElevenLabs sends 16-bit PCM, but we need Float32 for AVAudioEngine
//        let frameCount = AVAudioFrameCount(data.count / 2)  // 2 bytes per sample for 16-bit
//        
//        guard frameCount > 0 else {
//            print("❌ Invalid frame count: \(data.count) bytes")
//            return nil
//        }
//        
//        // Use the stream format for initial buffer creation
//        guard let buffer = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: frameCount) else {
//            print("❌ Failed to create buffer with stream format")
//            return nil
//        }
//        
//        buffer.frameLength = frameCount
//        
//        // Convert 16-bit PCM to Float32
//        data.withUnsafeBytes { rawBytes in
//            let int16Ptr = rawBytes.bindMemory(to: Int16.self)
//            if let channelData = buffer.floatChannelData?[0] {
//                for i in 0..<Int(frameCount) {
//                    // Convert Int16 to Float32 normalized to [-1, 1]
//                    channelData[i] = Float(int16Ptr[i]) / Float(Int16.max)
//                }
//            }
//        }
//        
//        return buffer
//    }
//    
//    @MainActor
//    private func startPlayback() async {
//        guard !isPlaying, let playerNode = playerNode else { return }
//        
//        playerNode.play()
//        isPlaying = true
//        print("▶️ StreamingPlayer24k started playback")
//    }
//    
//    @MainActor
//    private func scheduleNextBuffers() async {
//        guard let playerNode = playerNode,
//              let engine = engine,
//              engine.isRunning,
//              isPlaying else { return }
//        
//        // Get output format for conversion
//        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
//        let nodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
//                                      sampleRate: outputFormat.sampleRate,
//                                      channels: 1,
//                                      interleaved: false)!
//        
//        // Schedule all available buffers
//        while true {
//            guard let sourceBuffer = await bufferQueue.removeFirst() else { break }
//            
//            // Convert buffer to node format if needed
//            let bufferToSchedule: AVAudioPCMBuffer
//            if sourceBuffer.format.sampleRate == nodeFormat.sampleRate {
//                bufferToSchedule = sourceBuffer
//            } else {
//                // Need to convert from 24kHz to hardware rate
//                guard let converter = AVAudioConverter(from: sourceBuffer.format, to: nodeFormat) else {
//                    print("❌ Failed to create converter")
//                    continue
//                }
//                
//                let ratio = nodeFormat.sampleRate / sourceBuffer.format.sampleRate
//                let outputFrameCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio)
//                
//                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: nodeFormat, frameCapacity: outputFrameCapacity) else {
//                    print("❌ Failed to create output buffer")
//                    continue
//                }
//                
//                var error: NSError?
//                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
//                    outStatus.pointee = .haveData
//                    return sourceBuffer
//                }
//                
//                converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
//                
//                if let error = error {
//                    print("❌ Conversion error: \(error)")
//                    continue
//                }
//                
//                bufferToSchedule = outputBuffer
//            }
//            
//            // Schedule at the end of previously scheduled audio
//            let scheduleTime = AVAudioTime(sampleTime: totalFramesScheduled,
//                                          atRate: nodeFormat.sampleRate)
//            
//            playerNode.scheduleBuffer(bufferToSchedule, at: scheduleTime, options: []) {
//                // Buffer completed callback (optional logging)
//            }
//            
//            totalFramesScheduled += AVAudioFramePosition(bufferToSchedule.frameLength)
//        }
//    }
//    
//    private func handlePlaybackComplete() {
//        Task { @MainActor in
//            self.isPlaying = false
//            self.totalFramesScheduled = 0
//            
//            if let engine = self.engine, engine.isRunning {
//                engine.stop()
//            }
//            
//            self.engine = nil
//            self.playerNode = nil
//            self.eq = nil
//            
//            // Release audio mode
//            AudioCoordinator.shared.releaseCurrentMode()
//            
//            print("✅ StreamingPlayer24k playback complete")
//            self.onPlaybackComplete?()
//        }
//    }
//}
