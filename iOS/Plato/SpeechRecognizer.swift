//
//  SpeechRecognizer.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
// /Users/danielriaz/Projects/Plato/iOS/Plato/SpeechRecognizer.swift
//  Phase 1 latency refactor: short silence, stability early trigger, shared audio session.
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
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Turn state
    private var hasContent = false
    private var isAlwaysListening = false
    private var isPaused = false
    
    // Timers
    private var silenceTimer: Timer?
    private var lastTranscriptUpdate = Date()
    
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
        
        // Shared audio session (speaker + mic) *but* STT needs .measurement mode.
        AudioSessionManager.shared.configureForDuplex()     // sets playAndRecord / voiceChat

        do {
            let s = AVAudioSession.sharedInstance()
            // 👉 override just the mode for speech-to-text
            try s.setCategory(.playAndRecord,
                              mode: .measurement,
                              options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
        } catch {
            print("⚠️ Failed to configure STT session:", error)
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
                    print("Speech recognition error: \(error)")
                    self.stopRecording()
                }
            }
        }
        
        // Feed audio
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
            print("🎙️ AudioEngine started (listening).")
        } catch {
            print("Failed to start audio engine: \(error)")
            stopRecording()
        }
    }
    
    func stopRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        isRecording = false
        hasContent = false
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
        onAutoUpload?(trimmed)
        
        // reset for next turn if always listening (keep engine running)
        if isAlwaysListening {
            resetTurnState(clearTranscript: true)
        } else {
            stopRecording()
        }
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
