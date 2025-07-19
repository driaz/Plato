//
//  StreamingPlayer.swift
//  Plato
//
//  Created by Daniel Riaz on 7/17/25.
//

import AVFoundation

/// Feeds raw PCM chunks into an AVAudioPlayerNode for near real-time playback.
/// Assumes 16-bit little-endian mono @ 22,050 Hz (must match server output).
final class StreamingPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    
    init(sampleRate: Double = 22_050, channels: AVAudioChannelCount = 1) {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            fatalError("Failed to create AVAudioFormat.")
        }
        self.format = fmt
        
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            print("⚠️ StreamingPlayer: engine start error: \(error)")
        }
    }
    
    /// Schedule a chunk of raw PCM 16-bit little-endian mono audio.
    func schedule(_ data: Data) {
        guard !data.isEmpty else { return }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame) // 2 bytes @ mono 16-bit
        let frameCount = data.count / bytesPerFrame
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
        data.withUnsafeBytes { rawBuf in
            guard let srcI16 = rawBuf.bindMemory(to: Int16.self).baseAddress,
                  let dstI16 = buffer.int16ChannelData?[0] else { return }
            #if swift(>=5.9)
                dstI16.update(from: srcI16, count: frameCount)   // new name
            #else
                dstI16.assign(from: srcI16, count: frameCount)   // legacy
            #endif
            
        }
        
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
    
    func play() {
        if !player.isPlaying { player.play() }
    }
    
    func stop() {
        player.stop()
        engine.stop()
    }
}
