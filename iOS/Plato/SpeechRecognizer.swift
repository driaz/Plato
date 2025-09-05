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
    
    // Flow tracking
    private var currentRecognitionFlow: UUID?
    private var currentTurnFlow: UUID?
    
    // IMPORTANT: Add reference to check TTS state
    private weak var elevenLabsService: ElevenLabsService? {
        // Simply return the static reference from ContentView
        return ContentView.sharedElevenLabs
    }
    
    init() {
        print("🛑 SpeechRecognizer init DISABLED for Realtime testing")
        
        // Original init code commented out to prevent permission requests
        // speechRecognizer?.defaultTaskHint = .dictation
        // Logger.shared.log("SpeechRecognizer initialized", category: .speech, level: .info)
        // requestPermission()
    }
    
    // MARK: Permissions
    
    func requestPermission() {
        print("🛑 SpeechRecognizer.requestPermission() DISABLED for Realtime testing")
        // Original method commented out to prevent audio permission requests
        /*
        Task { @MainActor in
            Logger.shared.log("Requesting audio permissions", category: .speech, level: .info)

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
                Logger.shared.log("Microphone permission denied", category: .speech, level: .error)
                return
            }

            // ------- Speech-rec permission -------
            let speechAuth = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }

            self.isAuthorized = (speechAuth == .authorized)
            
            if self.isAuthorized {
                            Logger.shared.log("Speech recognition authorized", category: .speech, level: .info)
                        } else {
                            Logger.shared.log("Speech recognition not authorized: \(speechAuth.rawValue)",
                                             category: .speech, level: .error)
                        }
            
        }
        */  // End of commented out requestPermission method
    }
    
    // MARK: Always Listening
    
    func startAlwaysListening() {
        print("🛑 SpeechRecognizer.startAlwaysListening() DISABLED for Realtime testing")
        // Original method commented out
        /*
        guard isAuthorized else {
            Logger.shared.log("Cannot start always-listening: not authorized", category: .speech, level: .warning)
            return
        }
        
        Logger.shared.log("Starting always-listening mode", category: .speech, level: .info)
        isAlwaysListening = true
        isPaused = false
        startRecording()
    }
    */  // End of commented out startAlwaysListening method
    }
    
    func stopAlwaysListening() {
        Logger.shared.log("Stopping always-listening mode", category: .speech, level: .info)

        isAlwaysListening = false
        isPaused = false
        restartTimer?.invalidate()
        restartTimer = nil
        stopRecording()
    }
    
    func pauseListening(aiResponse: String = "") {
        guard isAlwaysListening else { return }
        isPaused = true
        if !aiResponse.isEmpty {
            Logger.shared.log("STT paused (AI speaking): \(aiResponse.prefix(50))...", category: .speech, level: .debug)
        } else {
            Logger.shared.log("STT paused for AI speech", category: .speech, level: .debug)
        }
    }
    
    func resumeListening() {
        guard isAlwaysListening else { return }
        isPaused = false
        resetTurnState(clearTranscript: true)
        Logger.shared.log("STT resumed after AI speech", category: .speech, level: .debug)

        // IMPORTANT: Actually restart recording if not already recording
        if !isRecording {
            Logger.shared.log("Starting recording in resumeListening", category: .speech, level: .debug)
            startRecording()
        }
    }
    
    // MARK: Start / Stop
    
    func startRecording() {
        guard isAuthorized else {
            Logger.shared.log("Cannot start recording: not authorized", category: .speech, level: .warning)
            return
        }
        
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            Logger.shared.log("Speech recognizer not available", category: .speech, level: .error)
            return
        }
        
        // Start recognition flow
        currentRecognitionFlow = Logger.shared.startFlow("speech_recognition")
        Logger.shared.startTimer("stt_session")
        
        // Cancel prior
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Request speech recognition mode
        do {
            try AudioCoordinator.shared.requestSpeechRecognitionMode()
            Logger.shared.log("Audio coordinator: speech mode acquired", category: .audio, level: .debug)
        } catch {
            Logger.shared.log("Failed to request speech recognition mode: \(error)", category: .speech, level: .error)
            if let flowId = currentRecognitionFlow {
                Logger.shared.endFlow(flowId, name: "speech_recognition")
            }
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
            Logger.shared.log("Added \(contextualHints.count) contextual hints", category: .speech, level: .debug)
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
        
        Logger.shared.log("Audio format: \(format.sampleRate)Hz, \(format.channelCount)ch", category: .audio, level: .debug)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            resetTurnState(clearTranscript: true)
            Logger.shared.log("Speech recognition started successfully", category: .speech, level: .info)
        } catch {
            Logger.shared.log("Failed to start audio engine: \(error)", category: .speech, level: .error)
            AudioCoordinator.shared.releaseCurrentMode()
            
            if let flowId = currentRecognitionFlow {
            Logger.shared.endFlow(flowId, name: "speech_recognition")
            }
            stopRecording()
        }
    }
    
    func stopRecording() {
        Logger.shared.log("Stopping recording", category: .speech, level: .info)

        // End timers
        if let flowId = currentRecognitionFlow {
            Logger.shared.endFlow(flowId, name: "speech_recognition")
            currentRecognitionFlow = nil
        }
        Logger.shared.endTimer("stt_session")
        
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        // End audio BEFORE stopping engine to flush buffer
        recognitionRequest?.endAudio()
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            Logger.shared.log("Audio engine stopped", category: .audio, level: .debug)
        }
        
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Release audio mode
        AudioCoordinator.shared.releaseCurrentMode()
        
        isRecording = false
        hasContent = false
        
        // Clear transcript to prevent echo
        let clearedText = transcript
        transcript = ""
        if !clearedText.isEmpty {
            Logger.shared.log("Cleared transcript: '\(clearedText.prefix(30))...'", category: .echo, level: .debug)
        }
        
        // IMPORTANT: Give the audio session time to release
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
    
    // MARK: Recognition Handling
    
    private func handleRecognition(result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription.formattedString
        let corrected = correctCommonMistakes(transcription)
        
        let oldTranscript = transcript
        transcript = corrected
        
//        if oldTranscript != corrected {
//            let diff = corrected.count - oldTranscript.count
//            if abs(diff) > 3 || result.isFinal {  // Log if 3+ char change or final
//                Logger.shared.log("Transcript: '\(corrected.suffix(50))'", category: .speech, level: .debug)
//            }
//        }
        
        
        lastTranscriptUpdate = Date()
        hasContent = !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if hasContent {
            autoUploadTimer()  // Reset silence timer
        }
        
        // EARLY TRIGGER when partial is stable & not paused
        if !result.isFinal, hasContent, !llmTriggered, !isPaused {
            let timeSinceLastPartial = Date().timeIntervalSince(lastPartialTime)

            if corrected == lastPartialText && timeSinceLastPartial > stabilityWindow {
                Logger.shared.log("Early trigger: stable for \(Int(timeSinceLastPartial * 1000))ms", category: .speech, level: .info)
                llmTriggered = true
                fireTurn(text: corrected)
            } else {
                lastPartialText = corrected
                lastPartialTime = Date()
            }
        }
        
        // Final trigger
        if result.isFinal {
            Logger.shared.log("Recognition final: '\(corrected.prefix(50))...'", category: .speech, level: .info)
            
            if hasContent && !llmTriggered && !isPaused {
                llmTriggered = true
                fireTurn(text: corrected)
            }
        }
    }
    
    private func handleRecognitionError(_ error: Error) {
        let nsError = error as NSError
        
        // Check for "No speech detected" error
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
            Logger.shared.log("No speech detected - will restart if in always-listening", category: .speech, level: .info)
            stopRecording()
            
            // Restart if in always-listening mode
            if isAlwaysListening && !isPaused {
                restartTimer?.invalidate()
                restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self,
                              self.isAlwaysListening,
                              !self.isPaused,
                              !self.isRecording else { return }
                        Logger.shared.log("Auto-restarting speech recognition", category: .speech, level: .info)
                        self.startRecording()
                    }
                }
            }
        } else {
            Logger.shared.log("Recognition error: \(error)", category: .speech, level: .error)
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
                      !self.isRecording else {
                    Logger.shared.log("Delayed restart skipped - conditions not met", category: .state, level: .debug)
                    return
                }
                
                // Check again if TTS is done
                if let elevenLabs = ContentView.sharedElevenLabs,
                   (elevenLabs.isSpeaking || elevenLabs.isGenerating) {
                    Logger.shared.log("TTS still active, scheduling another check in 2s", category: .state, level: .debug)
                    self.scheduleDelayedRestart()
                    return
                }
                
                Logger.shared.log("TTS finished, restarting speech recognition", category: .speech, level: .info)
                self.startRecording()
            }
        }
    }
    // MARK: Auto-upload
    
    private func autoUploadTimer() {
        silenceTimer?.invalidate()
        guard hasContent, isRecording, !isPaused else { return }
        
        // Don't log every timer reset - too noisy
        // Logger.shared.log("Silence timer started (\(silenceThreshold)s)", category: .speech, level: .debug)
        
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task {@MainActor in
                guard let self = self else { return }
                Logger.shared.log("Silence threshold reached - triggering turn", category: .speech, level: .info)

                self.fireTurn(text: self.transcript)
            }
        }
    }
    
    private func fireTurn(text: String) {
        guard !isPaused else {
            Logger.shared.log("Turn skipped - STT is paused", category: .state, level: .debug)
            return
        }
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Logger.shared.log("Turn skipped - empty text", category: .speech, level: .debug)
            return
        }
        
        // Start turn flow
        currentTurnFlow = Logger.shared.startFlow("user_turn")
        Logger.shared.log("Firing turn: '\(trimmed.prefix(50))...' (\(trimmed.count) chars)", category: .speech, level: .info)
        
        isProcessing = true
        
        // Immediately stop recording to prevent double-capture
        if isAlwaysListening {
            Logger.shared.log("Stopping recording for turn processing", category: .state, level: .debug)
            stopRecording()
        }
        // Trigger callback
        onAutoUpload?(trimmed)
        
        // End turn flow
         if let flowId = currentTurnFlow {
             Logger.shared.endFlow(flowId, name: "user_turn")
             currentTurnFlow = nil
         }
        
        // Don't restart immediately - let ContentView handle it after TTS
        isProcessing = false
    }
    
    private func resetTurnState(clearTranscript: Bool) {
        Logger.shared.log("Resetting turn state (clear: \(clearTranscript))", category: .state, level: .debug)
        llmTriggered = false
        hasContent = false
        lastPartialText = ""
        lastPartialTime = Date()
        if clearTranscript { transcript = "" }
    }
    
    // MARK: Contextual hints
    private var contextualHints: [String] {
        [
            // Core philosophers
            "Marcus Aurelius", "Epictetus", "Seneca",
            
            // Plato variants
            "Plato", "Play-Doh", "Playdoh", "Playto", "Plato's",
            
            // Philosophical vocabulary
            "Stoic", "Stoicism", "philosophy", "virtue", "resilience",
            "mindfulness", "temperance", "justice", "courage", "prudence",
            "inner peace", "present moment", "breathe deeply",
            
            // Common question stems
            "How do I", "What would", "How can I", "Guide me", "Teach me"
        ]
    }
    
    // MARK: - Manual upload
    func manualUpload() {
        if hasContent {
            Logger.shared.log("Manual upload triggered", category: .speech, level: .info)
            fireTurn(text: transcript)
        } else {
            Logger.shared.log("Manual upload skipped - no content", category: .speech, level: .debug)
        }
    }
    
    func stopForTTS() {
        Logger.shared.log("Force stopping speech recognizer for TTS", category: .state, level: .info)

        // Cancel any pending restart timers
        restartTimer?.invalidate()
        restartTimer = nil
        
        // Stop recording if active
        if isRecording {
            Logger.shared.log("Stopping active recording for TTS", category: .state, level: .debug)
            stopRecording()
        }
        
        // Mark as paused to prevent auto-restarts
        if isAlwaysListening {
            isPaused = true
            Logger.shared.log("STT paused for TTS playback", category: .state, level: .debug)
        }
    }
    
    func notifyTTSComplete() {
        lastTTSEndTime = Date()
        Logger.shared.log("TTS completed, setting grace period", category: .state, level: .info)
        Logger.shared.log("State - always:\(isAlwaysListening) recording:\(isRecording) paused:\(isPaused)", category: .state, level: .debug)
        
        
        // If somehow still recording, stop it first
        if isRecording {
            Logger.shared.log("⚠️ Still recording after TTS - stopping first", category: .state, level: .warning)
            stopRecording()
        }
        
        // Resume listening if it was paused
        if isPaused {
            Logger.shared.log("Resuming from paused state after TTS", category: .state, level: .info)
            resumeListening()
        } else if isAlwaysListening && !isRecording {
            // If we're in always-listening mode and not currently recording,
            // schedule a restart after a brief delay
            Logger.shared.log("Scheduling STT restart in 0.5s", category: .state, level: .debug)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if self.isAlwaysListening && !self.isRecording && !self.isPaused {
                    Logger.shared.log("Resuming speech recognition after TTS", category: .speech, level: .info)
                    self.startRecording()
                } else {
                    Logger.shared.log("Restart conditions not met - always:\(self.isAlwaysListening) recording:\(self.isRecording) paused:\(self.isPaused)", category: .state, level: .warning)
                }
            }
        } else {
            Logger.shared.log("Not scheduling restart - conditions not met", category: .state, level: .debug)
        }
    }
    // MARK: - Placeholder interruption API
    func startInterruptionMonitoring(aiResponse _: String = "") {
        Logger.shared.log("Interruption monitoring not implemented", category: .speech, level: .debug)

    }
    
    func stopInterruptionMonitoring() {}
    
    // MARK: - Corrections
    private func correctCommonMistakes(_ text: String) -> String {
        // Keep your correction logic minimal for now
        // Log only significant corrections
        let corrected = text // Your actual correction logic here
        
        if corrected != text {
            Logger.shared.log("Text corrected: '\(text)' -> '\(corrected)'",
                             category: .speech, level: .debug)
        }
        
        return corrected
    }
}

