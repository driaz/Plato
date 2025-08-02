//
//  RobustStreamingPlayer.swift
//  Plato
//
//  Robust PCM streaming using AVAudioEngine with proper setup
//

import Foundation
import AVFoundation

final class RobustStreamingPlayer: NSObject {
    // Audio components
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    
    // Buffer management
    private var isPlaying = false
    private var bufferSemaphore = DispatchSemaphore(value: 1)
    private var scheduledBufferCount = 0
    private let maxScheduledBuffers = 3  // Don't schedule too many at once
    
    // Format info
    private let streamSampleRate: Double = 24_000
    private let streamFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: 24_000,
                                           channels: 1,
                                           interleaved: false)!
    
    // Callbacks
    var onPlaybackComplete: (() -> Void)?
    
    override init() {
        super.init()
        print("🎵 RobustStreamingPlayer initialized")
    }
    
    /// Setup audio engine (call this once before streaming)
    @MainActor
    func setupEngine() async throws {
        // Stop any existing engine
        if let engine = engine, engine.isRunning {
            engine.stop()
            self.engine = nil
            self.playerNode = nil
        }
        
        // Request TTS mode
        try AudioCoordinator.shared.requestTextToSpeechMode()
        
        // Configure session for low-latency playback
        let session = AVAudioSession.sharedInstance()
        do {
            // Use playback category for simpler setup
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(48_000)  // Match device rate
            try session.setPreferredIOBufferDuration(0.005)  // 5ms buffer
            try session.setActive(true)
            
            // Wait for session to stabilize
            try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            
        } catch {
            print("❌ Audio session error: \(error)")
            throw error
        }
        
        // Create engine components
        let newEngine = AVAudioEngine()
        let newPlayerNode = AVAudioPlayerNode()
        
        // Attach player
        newEngine.attach(newPlayerNode)
        
        // Get the actual hardware format
        let outputFormat = newEngine.outputNode.inputFormat(forBus: 0)
        print("📋 Hardware format: \(outputFormat)")
        
        // Connect player directly to output with hardware format
        newEngine.connect(newPlayerNode,
                         to: newEngine.outputNode,
                         format: outputFormat)
        
        // Create converter from our stream format to hardware format
        guard let converter = AVAudioConverter(from: streamFormat, to: outputFormat) else {
            throw AudioError.converterCreationFailed
        }
        self.converter = converter
        
        // Start engine
        do {
            newEngine.prepare()
            try newEngine.start()
            
            self.engine = newEngine
            self.playerNode = newPlayerNode
            
            // Start the player node
            newPlayerNode.play()
            
            print("✅ Audio engine setup complete")
            print("🎵 Engine running: \(newEngine.isRunning)")
            
        } catch {
            print("❌ Engine start error: \(error)")
            throw error
        }
    }
    
    /// Feed PCM data for streaming playback
    func feedAudioData(_ data: Data) {
        guard let engine = engine,
              let playerNode = playerNode,
              let converter = converter,
              engine.isRunning else {
            print("⚠️ Engine not ready for audio data")
            return
        }
        
        // Convert data to PCM buffer
        guard let sourceBuffer = createPCMBuffer(from: data) else {
            print("❌ Failed to create source buffer")
            return
        }
        
        // Get hardware format
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        
        // Calculate output frame capacity
        let outputFrameCapacity = AVAudioFrameCount(
            Double(sourceBuffer.frameLength) * outputFormat.sampleRate / streamSampleRate
        )
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                 frameCapacity: outputFrameCapacity) else {
            print("❌ Failed to create output buffer")
            return
        }
        
        // Convert the buffer
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            print("❌ Conversion error: \(error)")
            return
        }
        
        // Wait if too many buffers are scheduled
        bufferSemaphore.wait()
        if scheduledBufferCount >= maxScheduledBuffers {
            // Wait a bit for buffers to play
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        // Schedule the buffer
        scheduledBufferCount += 1
        playerNode.scheduleBuffer(outputBuffer) { [weak self] in
            self?.bufferSemaphore.wait()
            self?.scheduledBufferCount -= 1
            self?.bufferSemaphore.signal()
        }
        bufferSemaphore.signal()
        
        isPlaying = true
    }
    
    /// Signal end of stream
    func finishStreaming() {
        guard let playerNode = playerNode else { return }
        
        // Schedule an empty buffer to signal completion
        if let outputFormat = engine?.outputNode.inputFormat(forBus: 0),
           let emptyBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1) {
            
            emptyBuffer.frameLength = 0
            playerNode.scheduleBuffer(emptyBuffer) { [weak self] in
                DispatchQueue.main.async {
                    self?.handlePlaybackComplete()
                }
            }
        }
    }
    
    /// Stop playback immediately
    @MainActor
    func stop() {
        playerNode?.stop()
        engine?.stop()
        
        engine = nil
        playerNode = nil
        converter = nil
        isPlaying = false
        scheduledBufferCount = 0
        
        AudioCoordinator.shared.releaseCurrentMode()
        print("🛑 RobustStreamingPlayer stopped")
    }
    
    // MARK: - Private Methods
    
    private func createPCMBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(data.count / 2)  // 16-bit = 2 bytes per sample
        
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: frameCount) else {
            return nil
        }
        
        buffer.frameLength = frameCount
        
        // Copy data directly to buffer
        data.withUnsafeBytes { rawBytes in
            if let channelData = buffer.int16ChannelData?[0] {
                rawBytes.copyBytes(to: UnsafeMutableBufferPointer(start: channelData,
                                                                  count: Int(frameCount)))
            }
        }
        
        return buffer
    }
    
    @MainActor
    private func handlePlaybackComplete() {
        isPlaying = false
        scheduledBufferCount = 0
        onPlaybackComplete?()
        print("✅ Streaming playback complete")
    }
}

// MARK: - Errors

enum AudioError: LocalizedError {
    case engineNotReady
    case converterCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .engineNotReady:
            return "Audio engine is not ready"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        }
    }
}
