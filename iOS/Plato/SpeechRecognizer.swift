//
//  SpeechRecognizer.swift
//  Plato
//
//  Updated to prevent auto-restart during TTS playback
//

// NOTE: iOS system logs 1101 errors after multiple recognition cycles
// This is normal behavior and doesn't affect functionality
// Filter with "!1101" in Xcode console if needed

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
    @Published var isMonitoringForInterruption: Bool = false
    
    // Core
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
    private var lastTTSEndTime: Date = .distantPast

    
    // Config
    private let cfg = ConfigManager.shared
    private var silenceThreshold: TimeInterval { cfg.speechSilenceThreshold }
    private var stabilityWindow: TimeInterval { cfg.speechStabilityWindow }
    
    // Early trigger tracking
    private var lastPartialText = ""
    private var lastPartialTime = Date()
    private var llmTriggered = false
    
    // Error tracking
    private var lastErrorCode: Int?
    private var lastErrorTime = Date.distantPast
    private var consecutiveErrorCount = 0
    
    // Callbacks
    var onAutoUpload: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    
    // IMPORTANT: Add reference to check TTS state
    private weak var elevenLabsService: ElevenLabsService? {
        // Simply return the static reference from ContentView
        return ContentView.sharedElevenLabs
    }
    
    init() {
        speechRecognizer?.defaultTaskHint = .dictation
        
        // DEBUG: See what values are actually being used
        print("🎙️ Speech Recognition Timings:")
        print("   - Silence threshold: \(cfg.speechSilenceThreshold)s")
        print("   - Stability window: \(cfg.speechStabilityWindow)s")
        print("   - Post-playback grace: \(cfg.speechPostPlaybackGrace)s")
        print("   - VAD threshold: \(String(describing: cfg.vadEnergyFloorDb)) dB")
        
        requestPermission()
    }
    
    // MARK: Permissions
    
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
        
        // IMPORTANT: Actually restart recording if not already recording
        if !isRecording {
            print("🎤 Starting recording in resumeListening")
            startRecording()
        }
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
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    // MARK: Recognition Handling
    
    private func handleRecognition(result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription.formattedString
        let corrected = correctCommonMistakes(transcription)
        transcript = corrected
        
        lastTranscriptUpdate = Date()
        hasContent = !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        autoUploadTimer()
        
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
        let nsError = error as NSError
        
        // SUPPRESS SPAMMY 1101 ERRORS - COMPLETELY SILENT
        if nsError.code == 1101 {
            // Just return immediately - no logging, no processing
            return
        }
        
        // LIMIT OTHER REPEATED ERRORS
        if nsError.code == lastErrorCode && nsError.code != 1110 { // Don't limit 1110
            consecutiveErrorCount += 1
            if consecutiveErrorCount > 3 {
                if consecutiveErrorCount == 4 {
                    print("❌ Suppressing further '\(error.localizedDescription)' errors...")
                }
                return
            }
        } else {
            lastErrorCode = nsError.code
            consecutiveErrorCount = 1
        }
        
        // Check if it's a "No speech detected" error BEFORE logging
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
            stopRecording()
            
            let isTTSSpeaking = ContentView.sharedElevenLabs?.isSpeaking ?? false
            
            if isAlwaysListening && !isPaused && !isTTSSpeaking {
                restartTimer?.invalidate()
                restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self,
                              self.isAlwaysListening,
                              !self.isPaused,
                              !self.isRecording else { return }
                        
                        let stillNotSpeaking = ContentView.sharedElevenLabs?.isSpeaking != true
                        if stillNotSpeaking {
                            print("🔄 Restarting speech recognition")
                            self.startRecording()
                        }
                    }
                }
            }
        } else {
            // Only log non-1101, non-1110 errors
            print("❌ Recognition error: \(error)")
            stopRecording()
        }
    }
    
    // MARK: Helper to get ElevenLabsService
    
    private func getElevenLabsService() -> ElevenLabsService? {
        // Try multiple approaches to get the service
        
        // First, check if ContentView has a static reference
        if let sharedService = ContentView.sharedElevenLabs {
            return sharedService
        }
        
        // If not, try to find it through the view hierarchy
        // This is a bit hacky but works for SwiftUI apps
        for window in UIApplication.shared.windows {
            if let hostingController = window.rootViewController as? UIHostingController<ContentView> {
                // We can't directly access the ContentView, but we can use a static property
                return nil // Will rely on ContentView.sharedElevenLabs
            }
        }
        
        return nil
    }
    
    // MARK: Delayed restart when TTS is active
    
    private func scheduleDelayedRestart() {
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      self.isAlwaysListening,
                      !self.isPaused,
                      !self.isRecording else { return }
                
                // Check again if TTS is done
                if let elevenLabs = ContentView.sharedElevenLabs,
                   (elevenLabs.isSpeaking || elevenLabs.isGenerating) {
                    print("🔇 Still speaking, scheduling another check")
                    self.scheduleDelayedRestart()
                    return
                }
                
                print("🔄 TTS finished, restarting speech recognition")
                self.startRecording()
            }
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
    
    // MARK: Contextual hints
    private var contextualHints: [String] {
        [
            "Marcus Aurelius", "Epictetus", "Seneca",
            "Plato", "Play-Doh", "Playdoh", "Playto", "Plato's",
            "Stoic", "Stoicism", "philosophy", "virtue", "resilience",
            "mindfulness", "temperance", "justice", "courage", "prudence",
            "inner peace", "present moment", "breathe deeply",
            "How do I", "What would", "How can I", "Guide me", "Teach me"
        ]
    }
    
    // MARK: - Manual upload
    func manualUpload() {
        if hasContent {
            fireTurn(text: transcript)
        }
    }
    
    func stopForTTS() {
        print("🛑 Force stopping speech recognizer for TTS")
        
        // Cancel any pending restart timers
        restartTimer?.invalidate()
        restartTimer = nil
        
        // Stop recording if active
        if isRecording {
            stopRecording()
        }
        
        // Mark as paused to prevent auto-restarts
        if isAlwaysListening {
            isPaused = true
        }
    }
    
    func notifyTTSComplete() {
        lastTTSEndTime = Date()
        print("📢 TTS completed, setting grace period")
        print("   - isAlwaysListening: \(isAlwaysListening)")
        print("   - isRecording: \(isRecording)")
        print("   - isPaused: \(isPaused)")
        
        // If somehow still recording, stop it first
        if isRecording {
            print("   ⚠️ Still recording - stopping first")
            stopRecording()
        }
        
        // Resume listening if it was paused
        if isPaused {
            print("   → Resuming from paused state")
            resumeListening()
        } else if isAlwaysListening && !isRecording {
            // If we're in always-listening mode and not currently recording,
            // schedule a restart after a brief delay
            print("   → Scheduling restart in 0.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if self.isAlwaysListening && !self.isRecording && !self.isPaused {
                    print("🎤 Resuming speech recognition after TTS")
                    self.startRecording()
                } else {
                    print("   ⚠️ Restart conditions not met after delay:")
                    print("      - isAlwaysListening: \(self.isAlwaysListening)")
                    print("      - isRecording: \(self.isRecording)")
                    print("      - isPaused: \(self.isPaused)")
                }
            }
        } else {
            print("   ⚠️ Not scheduling restart - conditions not met")
        }
    }
    // MARK: - Placeholder interruption API
    func startInterruptionMonitoring(aiResponse _: String = "") {}
    func stopInterruptionMonitoring() {}
    
    // MARK: - Corrections
    private func correctCommonMistakes(_ text: String) -> String {
        return text
    }
}

