//
//  AudioSessionManager.swift
//  Plato
//
//  Centralizes AVAudioSession configuration so recording + playback
//  can coexist without category thrash.
//

import AVFoundation

@MainActor
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private init() {}
    
    private var configured = false
    
    /// Configure once for full-duplex conversational audio.
    /// Use .playAndRecord so mic + speaker both stay live; use .voiceChat mode
    /// for voice-optimized processing (echo cancellation, etc) on supported devices.
    func configureForDuplex() {
        guard !configured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [
                                        .defaultToSpeaker,      // route to speaker by default
                                        .allowBluetooth,        // headset mics
                                        .allowBluetoothA2DP,    // high-quality BT out
                                        .mixWithOthers          // be polite to other audio
                                    ])
            // Request a short IO buffer for lower round-trip latency (best effort).
            try session.setPreferredIOBufferDuration(0.005)
            // You can set a preferred sample rate if needed; we accept system default.
            try session.setActive(true)
            configured = true
            print("🔉 AudioSessionManager configured for duplex (.playAndRecord / .voiceChat).")
        } catch {
            print("⚠️ AudioSessionManager configure error: \(error)")
        }
    }
    
    /// Deactivate if you really need to yield audio (seldom needed in always-on flow).
    func deactivate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            configured = false
            print("🔉 AudioSessionManager deactivated.")
        } catch {
            print("⚠️ AudioSessionManager deactivate error: \(error)")
        }
    }
}
