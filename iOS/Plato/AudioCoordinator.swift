//
//  AudioCoordinator.swift
//  Plato
//
//  Coordinates audio session state between STT and TTS
//

import AVFoundation

@MainActor
final class AudioCoordinator {
    static let shared = AudioCoordinator()
    
    enum AudioMode {
        case idle
        case speechRecognition
        case textToSpeech
    }
    
    private(set) var currentMode: AudioMode = .idle
    
    private init() {}
    
    /// Request to switch to speech recognition mode
    func requestSpeechRecognitionMode() throws {
        guard currentMode != .textToSpeech else {
            throw AudioCoordinatorError.ttsBusy
        }
        
        // Don't change the category if we're already in a compatible mode
        if currentMode != .speechRecognition {
            let session = AVAudioSession.sharedInstance()
            // Keep the same category/mode, just ensure it's active
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
        
        currentMode = .speechRecognition
        print("🎤 Audio mode: Speech Recognition")
    }
    /// Request to switch to text-to-speech mode
    func requestTextToSpeechMode() throws {
        // If already in TTS mode, just return
        guard currentMode != .textToSpeech else {
            return
        }
        
        guard currentMode != .speechRecognition else {
            throw AudioCoordinatorError.sttBusy
        }
        
        // Don't change the audio session here - let the player handle it
        currentMode = .textToSpeech
        print("🔊 Audio mode: Text to Speech")
    }
    /// Release current mode
    func releaseCurrentMode() {
        let previousMode = currentMode
        currentMode = .idle
        print("😴 Audio mode: Idle (was \(previousMode))")
        
        // Don't change the audio session - keep it in a stable state
    }
}

enum AudioCoordinatorError: LocalizedError {
    case sttBusy
    case ttsBusy
    
    var errorDescription: String? {
        switch self {
        case .sttBusy:
            return "Cannot start TTS while speech recognition is active"
        case .ttsBusy:
            return "Cannot start speech recognition while TTS is active"
        }
    }
}
