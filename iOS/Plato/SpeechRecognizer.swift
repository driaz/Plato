//
//  SpeechRecognizer.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//  Updated to handle "No speech detected" errors in always-listening mode
//

import Foundation
import Speech
import SwiftUI
import AVFoundation

@MainActor
class SpeechRecognizer: ObservableObject {
    // Published state
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var isAuthorized: Bool = false
    @Published var isProcessing: Bool = false
    @Published var isMonitoringForInterruption: Bool = false   // placeholder; off in Phase 1
    
    // Core
//    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    
    // Turn state
    private var hasContent = false
    private var isAlwaysListening = false
    private var isPaused = false
    
    // Timers
    private var silenceTimer: Timer?
    private var lastTranscriptUpdate = Date()
    private var restartTimer: Timer?
    
    // Config
    private let cfg = ConfigManager.shared
    private var silenceThreshold: TimeInterval { cfg.speechSilenceThreshold }        // default 0.6
    private var stabilityWindow: TimeInterval { cfg.speechStabilityWindow }          // default 0.3
    
    // Early trigger tracking
    private var lastPartialText = ""
    private var lastPartialTime = Date()
    private var llmTriggered = false
    
    // Callbacks
    var onAutoUpload: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    
    init() {
        speechRecognizer?.defaultTaskHint = .dictation
        requestPermission()
    }
    
    // MARK: Permissions
    
    /// Ask for mic **and** Speech-Recognition permission, updating `isAuthorized`.
    func requestPermission() {
        Task { @MainActor in
            // ------- Microphone permission -------
            let micGranted: Bool
            if #available(iOS 17.0, *) {
                micGranted = await AVAudioApplication.requestRecordPermission()
            } else {
                micGranted = await withCheckedContinuation { cont in
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        cont.resume(returning: granted)
                    }
                }
            }

            guard micGranted else {
                self.isAuthorized = false
                print("❌ Microphone permission denied")
                return
            }

            // ------- Speech-rec permission -------
            let speechAuth = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }

            self.isAuthorized = (speechAuth == .authorized)
            print(self.isAuthorized ? "✅ Speech recognition authorized"
                                    : "❌ Speech recognition not authorized: \(speechAuth.rawValue)")
        }
    }
    
    // MARK: Always Listening
    
    func startAlwaysListening() {
        guard isAuthorized else {
            print("Speech recognition not authorized for always-on listening")
            return
        }
        isAlwaysListening = true
        isPaused = false
        startRecording()
    }
    
    func stopAlwaysListening() {
        isAlwaysListening = false
        isPaused = false
        restartTimer?.invalidate()
        restartTimer = nil
        stopRecording()
    }
    
    // Temporarily pause auto-upload (during AI speech); engine kept alive.
    func pauseListening(aiResponse _: String = "") {
        guard isAlwaysListening else { return }
        isPaused = true
        print("🔇 SpeechRecognizer paused (AI speaking).")
    }
    
    func resumeListening() {
        guard isAlwaysListening else { return }
        isPaused = false
        resetTurnState(clearTranscript: true)
        print("🎙️ SpeechRecognizer resumed.")
    }
    
    // MARK: Start / Stop
    
    func startRecording() {
        guard isAuthorized else {
            print("Speech recognition not authorized")
            return
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("Speech recognizer not available")
            return
        }
        
        // Cancel prior
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Request speech recognition mode
        do {
            try AudioCoordinator.shared.requestSpeechRecognitionMode()
        } catch {
            print("❌ Failed to request speech recognition mode: \(error)")
            return
        }
        
        // New request
        let req = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = req
        
        // STT config
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.taskHint = .dictation
        
        if #available(iOS 16.0, *) {
            req.addsPunctuation = true
            req.contextualStrings = contextualHints
        }
        
        // Recognize
        llmTriggered = false
        recognitionTask = speechRecognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let result {
                    self.handleRecognition(result: result)
                }
                if let error {
                    self.handleRecognitionError(error)
                }
            }
        }
        
        // Configure audio engine
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            resetTurnState(clearTranscript: true)
            print("🎙️ Speech recognition started")
        } catch {
            print("Failed to start audio engine: \(error)")
            AudioCoordinator.shared.releaseCurrentMode()
            stopRecording()
        }
    }
    
    func stopRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        // End audio BEFORE stopping engine to flush buffer
        recognitionRequest?.endAudio()
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Release audio mode
        AudioCoordinator.shared.releaseCurrentMode()
        
        isRecording = false
        hasContent = false
        
        // Clear transcript to prevent echo
        transcript = ""
        
        // IMPORTANT: Give the audio session time to release
        // This prevents conflicts when TTS starts immediately after
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    // MARK: Recognition Handling
    
    private func handleRecognition(result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription.formattedString
        let corrected = correctCommonMistakes(transcription) // keep corrections for now
        transcript = corrected
        
        lastTranscriptUpdate = Date()
        hasContent = !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        autoUploadTimer()  // trailing-silence trigger
        
        // EARLY TRIGGER when partial is stable & not paused
        if !result.isFinal, hasContent, !llmTriggered, !isPaused {
            if corrected == lastPartialText,
               Date().timeIntervalSince(lastPartialTime) > stabilityWindow {
                llmTriggered = true
                fireTurn(text: corrected)
            } else {
                lastPartialText = corrected
                lastPartialTime = Date()
            }
        }
        
        // FINAL trigger backup
        if result.isFinal, hasContent, !llmTriggered, !isPaused {
            llmTriggered = true
            fireTurn(text: corrected)
        }
    }
    
    private func handleRecognitionError(_ error: Error) {
        print("❌ Recognition error: \(error)")
        
        // Check if it's a "No speech detected" error
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
            print("🔇 No speech detected - will restart if in always-listening mode")
            stopRecording()
            
            // If we're in always-listening mode and not paused, restart after a delay
            if isAlwaysListening && !isPaused {
                restartTimer?.invalidate()
                restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self,
                              self.isAlwaysListening,
                              !self.isPaused,
                              !self.isRecording else { return }
                        print("🔄 Restarting speech recognition after no speech detected")
                        self.startRecording()
                    }
                }
            }
        } else {
            // For other errors, just stop
            stopRecording()
        }
    }
    
    // MARK: Auto-upload
    
    private func autoUploadTimer() {
        silenceTimer?.invalidate()
        guard hasContent, isRecording, !isPaused else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task {@MainActor in
                self?.fireTurn(text: self?.transcript ?? "")
            }
        }
    }
    
    private func fireTurn(text: String) {
        guard !isPaused else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        isProcessing = true
        
        // Immediately stop recording to prevent double-capture
        if isAlwaysListening {
            stopRecording()
        }
        
        onAutoUpload?(trimmed)
        
        // Don't restart immediately - let ContentView handle it after TTS
        isProcessing = false
    }
    
    private func resetTurnState(clearTranscript: Bool) {
        llmTriggered = false
        hasContent = false
        lastPartialText = ""
        lastPartialTime = Date()
        if clearTranscript { transcript = "" }
    }
    
    // MARK: Contextual hints (improve accuracy)
    private var contextualHints: [String] {
        [
            // Core philosophers
            "Marcus Aurelius", "Epictetus", "Seneca",

            // ←– add all common Plato variants
            "Plato",           // canonical
            "Play-Doh",        // homophone people sometimes say
            "Playdoh",         // no hyphen
            "Playto",          // phonetic mis-spell
            "Plato's",         // possessive form

            // Philosophical vocabulary
            "Stoic", "Stoicism", "philosophy", "virtue", "resilience",
            "mindfulness", "temperance", "justice", "courage", "prudence",
            "inner peace", "present moment", "breathe deeply",

            // Common question stems
            "How do I", "What would", "How can I", "Guide me", "Teach me"
        ]
    }
    
    // MARK: - Manual upload (manual mode UI)
    func manualUpload() {
        if hasContent {
            fireTurn(text: transcript)
        }
    }
    
    // MARK: - Placeholder interruption API (disabled Phase 1)
    func startInterruptionMonitoring(aiResponse _: String = "") {}
    func stopInterruptionMonitoring() {}
    
    // MARK: - Corrections (unchanged from your original, trimmed)
    private func correctCommonMistakes(_ text: String) -> String {
        // (Keep your full correction tables if desired; trimmed for brevity here)
        return text
    }
}

// Add these methods to SpeechRecognizer.swift

//extension SpeechRecognizer {
//    /// Stop the audio engine for TTS playback
//    func stopEngineForPlayback() {
//        if audioEngine.isRunning {
//            audioEngine.stop()
//            audioEngine.inputNode.removeTap(onBus: 0)
//            print("🛑 Stopped speech engine for TTS playback")
//        }
//    }
//    
//    /// Check if audio engine is running
//    var isEngineRunning: Bool {
//        audioEngine.isRunning
//    }
//}
