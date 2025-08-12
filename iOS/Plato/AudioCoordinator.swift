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
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
        
        currentMode = .speechRecognition
        Logger.shared.log("Audio mode: Speech Recognition", category: .state, level: .info)
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
        Logger.shared.log("Audio mode: Text to Speech", category: .state, level: .info)
    }
    
    /// Release current mode
    func releaseCurrentMode() {
        let previousMode = currentMode
        currentMode = .idle
        Logger.shared.log("Audio mode: Idle (was \(previousMode))", category: .state, level: .info)
        
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
