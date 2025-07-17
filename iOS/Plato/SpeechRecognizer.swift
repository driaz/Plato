//
//  SpeechRecognizer.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
// /Users/danielriaz/Projects/Plato/iOS/Plato/SpeechRecognizer.swift

import Foundation
import Speech
import SwiftUI
import AVFoundation

@MainActor
class SpeechRecognizer: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var isAuthorized: Bool = false
    @Published var isProcessing: Bool = false
    @Published var isMonitoringForInterruption: Bool = false
    
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Interruption monitoring
    private var interruptionEngine = AVAudioEngine()
    private var interruptionRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var interruptionRecognitionTask: SFSpeechRecognitionTask?
    
    // Auto-upload functionality
    private var silenceTimer: Timer?
    private var lastTranscriptUpdate = Date()
    private let silenceThreshold: TimeInterval = 3.0
    private var hasContent = false
    private var isAlwaysListening = false
    private var isPaused = false
    
    // Interruption detection
    private let interruptionThreshold: TimeInterval = 0.8
    private var interruptionTimer: Timer?
    private var currentAIResponse: String = ""
    
    // Callbacks
    var onAutoUpload: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    
    init() {
        speechRecognizer?.defaultTaskHint = .dictation
        requestPermission()
    }
    
    func requestPermission() {
        // Request both microphone and speech recognition permissions
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] micGranted in
            if micGranted {
                SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
                    DispatchQueue.main.async {
                        switch authStatus {
                        case .authorized:
                            print("✅ Speech recognition authorized")
                            self?.isAuthorized = true
                        case .denied:
                            print("❌ Speech recognition denied")
                            self?.isAuthorized = false
                        case .restricted:
                            print("❌ Speech recognition restricted")
                            self?.isAuthorized = false
                        case .notDetermined:
                            print("❌ Speech recognition not determined")
                            self?.isAuthorized = false
                        @unknown default:
                            print("❌ Speech recognition unknown status")
                            self?.isAuthorized = false
                        }
                    }
                }
            } else {
                print("❌ Microphone permission denied")
                DispatchQueue.main.async {
                    self?.isAuthorized = false
                }
            }
        }
    }
    
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
    
    func pauseListening(aiResponse: String = "") {
        print("pauseListening called - isRecording: \(isRecording), isAlwaysListening: \(isAlwaysListening)")
        if isAlwaysListening {
            print("Setting paused state while AI speaks...")
            isPaused = true
            if isRecording {
                stopRecording()
            }
            
            // DISABLED: No interruption monitoring for now to fix audio issues
            // startInterruptionMonitoring(aiResponse: aiResponse)
        }
    }
    
    func resumeListening() {
        print("resumeListening called - isAlwaysListening: \(isAlwaysListening), isRecording: \(isRecording), isPaused: \(isPaused)")
        
        // Stop interruption monitoring
        stopInterruptionMonitoring()
        
        if isAlwaysListening && !isRecording && isPaused {
            print("Resuming listening after AI finished speaking...")
            isPaused = false
            transcript = ""
            hasContent = false
            startRecording()
        } else {
            print("Not resuming - conditions not met. isAlwaysListening: \(isAlwaysListening), isRecording: \(isRecording), isPaused: \(isPaused)")
        }
    }
    
    func startRecording() {
        guard isAuthorized else {
            print("Speech recognition not authorized")
            return
        }
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("Speech recognizer not available")
            return
        }
        
        // Prevent multiple simultaneous recordings
        if isRecording {
            print("Already recording, stopping previous session")
            stopRecording()
        }
        
        // Cancel any previous task
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio session configured successfully")
        } catch {
            print("Failed to set up audio session: \(error)")
        }
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            print("Unable to create recognition request")
            return
        }
        
        // Enhanced recognition settings for maximum accuracy
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        recognitionRequest.taskHint = .dictation
        
        // Add comprehensive context hints for better recognition
        if #available(iOS 16.0, *) {
            recognitionRequest.addsPunctuation = true
            recognitionRequest.contextualStrings = [
                // Stoic philosophers
                "Marcus Aurelius", "Epictetus", "Seneca", "Plato",
                
                // Philosophical concepts
                "Stoic", "stoicism", "philosophy", "philosopher", "wisdom", "virtue",
                "meditation", "meditations", "acceptance", "resilience", "mindfulness",
                "contemplation", "temperance", "justice", "courage", "prudence",
                
                // Common meditation/mindfulness phrases
                "sit in stillness", "inner peace", "present moment", "letting go",
                "breathe deeply", "find balance", "mental clarity", "emotional control",
                "self reflection", "personal growth", "life lessons", "ancient wisdom",
                
                // Action words often used in philosophical context
                "cultivate", "embrace", "acknowledge", "recognize", "practice",
                "discipline", "perseverance", "endurance", "tranquility", "serenity",
                
                // Common question starters
                "how do I", "what would", "how can I", "what should I", "why do I",
                "help me understand", "teach me", "show me", "guide me"
            ]
        }
        
        if #available(iOS 17.0, *) {
            recognitionRequest.interactionIdentifier = "philosophical_conversation"
        }
        
        // Get input node
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        
        // Create recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    let correctedText = self?.correctCommonMistakes(transcription) ?? transcription
                    self?.transcript = correctedText
                    
                    self?.lastTranscriptUpdate = Date()
                    self?.hasContent = !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    
                    self?.resetSilenceTimer()
                    
                    if result.isFinal && self?.hasContent == true {
                        self?.processAutoUpload()
                    }
                }
                
                if let error = error {
                    print("Speech recognition error: \(error)")
                    self?.stopRecording()
                }
            }
        }
        
        // Configure audio input
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        do {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }
        } catch {
            print("Failed to install audio tap: \(error)")
            stopRecording()
            return
        }
        
        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            transcript = ""
            hasContent = false
        } catch {
            print("Failed to start audio engine: \(error)")
            stopRecording()
        }
    }
    
    func stopRecording() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        stopInterruptionMonitoring()
        
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
        
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    
    func manualUpload() {
        silenceTimer?.invalidate()
        if hasContent {
            processAutoUpload()
        }
    }
    
    // MARK: - Text Processing
    
    private func correctCommonMistakes(_ text: String) -> String {
        var corrected = text
        
        // Fix philosophical term misrecognitions
        let philosophicalCorrections: [String: String] = [
            "markets": "Marcus",
            "market": "Marcus",
            "Marcus": "Marcus Aurelius",
            "epic": "Epictetus",
            "epics": "Epictetus",
            "seneca": "Seneca",
            "stoic": "Stoic",
            "stoics": "Stoics",
            "stoicism": "Stoicism"
        ]
        
        for (mistake, correction) in philosophicalCorrections {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: mistake))\\b"
            corrected = corrected.replacingOccurrences(
                of: pattern,
                with: correction,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        corrected = normalizeColloquialSpeech(corrected)
        return corrected
    }
    
    private func normalizeColloquialSpeech(_ text: String) -> String {
        var normalized = text
        
        // Fix common speech recognition errors for philosophical phrases
        let phraseCorrections: [String: String] = [
            "sit and stillness": "sit in stillness",
            "sit in silence": "sit in silence",
            "inner piece": "inner peace",
            "piece of mind": "peace of mind",
            "presents moment": "present moment",
            "present mmoment": "present moment",
            "letting goal": "letting go",
            "let it goal": "let it go",
            "ancient wisdom": "ancient wisdom",
            "stoic principals": "Stoic principles",
            "self reflection": "self-reflection",
            "mental clarity": "mental clarity",
            "emotional control": "emotional control",
            "except it": "accept it",
            "except what": "accept what",
            "breathe deeply": "breathe deeply",
            "find balance": "find balance",
            "how do i": "how do I",
            "what would": "what would",
            "how can i": "how can I",
            "what should i": "what should I"
        ]
        
        for (incorrect, correct) in phraseCorrections {
            normalized = normalized.replacingOccurrences(
                of: incorrect,
                with: correct,
                options: .caseInsensitive
            )
        }
        
        // Handle colloquial speech
        let colloquialMappings: [String: String] = [
            " uh uh ": " uh ",
            " um um ": " um ",
            " like like ": " like ",
            "kinda": "kind of",
            "gonna": "going to",
            "wanna": "want to",
            "gotta": "got to",
            "sorta": "sort of",
            "ya know": "you know",
            "y'know": "you know",
            "ya think": "you think",
            "super ": "very ",
            "pretty ": "quite ",
            "really really": "really",
            "very very": "very",
            "and and": "and",
            "but but": "but",
            "so so": "so",
            "the the": "the",
            "could of": "could have",
            "would of": "would have",
            "should of": "should have"
        ]
        
        for (casual, formal) in colloquialMappings {
            normalized = normalized.replacingOccurrences(
                of: casual,
                with: formal,
                options: .caseInsensitive
            )
        }
        
        // Clean up spacing and punctuation
        normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        normalized = normalized.replacingOccurrences(of: " ,", with: ",")
        normalized = normalized.replacingOccurrences(of: " .", with: ".")
        normalized = normalized.replacingOccurrences(of: " ?", with: "?")
        normalized = normalized.replacingOccurrences(of: " !", with: "!")
        
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Auto-upload functionality
    
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        
        guard hasContent && isRecording else { return }
        
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.processAutoUpload()
            }
        }
    }
    
    private func processAutoUpload() {
        guard hasContent && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        isProcessing = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.onAutoUpload?(self.transcript)
            
            if self.isAlwaysListening {
                self.stopRecording()
            } else {
                self.stopRecording()
            }
            
            self.isProcessing = false
        }
    }
    
    // MARK: - Interruption Monitoring
    
    func startInterruptionMonitoring(aiResponse: String = "") {
        guard isAuthorized else {
            print("Cannot start interruption monitoring - not authorized")
            return
        }
        
        guard !isMonitoringForInterruption else {
            print("Already monitoring for interruption")
            return
        }
        
        currentAIResponse = aiResponse.lowercased()
        print("🎤 Starting interruption monitoring while AI speaks: '\(aiResponse.prefix(30))...'")
        
        // Use the same audio session mode as playback to avoid conflicts
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            print("✅ Audio session configured for interruption monitoring (playAndRecord mode)")
        } catch {
            print("Failed to configure audio session for interruption monitoring: \(error)")
            return
        }
        
        interruptionRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let interruptionRequest = interruptionRecognitionRequest else {
            print("Unable to create interruption recognition request")
            return
        }
        
        interruptionRequest.shouldReportPartialResults = true
        interruptionRequest.requiresOnDeviceRecognition = false
        interruptionRequest.taskHint = .dictation
        
        // MUCH SIMPLER: Just look for clear interruption patterns, ignore everything else
        interruptionRecognitionTask = speechRecognizer?.recognitionTask(with: interruptionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result = result {
                    let transcription = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // SIMPLE FILTER: Only accept clear interruption words
                    if self?.isSimpleInterruption(transcription) == true {
                        print("🚨 CLEAR INTERRUPTION DETECTED: '\(transcription)'")
                        self?.handleInterruption(with: transcription)
                    } else if !transcription.isEmpty {
                        print("🔇 Ignored unclear speech: '\(transcription.prefix(20))...'")
                    }
                }
                
                if let error = error {
                    print("Interruption monitoring error: \(error)")
                    self?.stopInterruptionMonitoring()
                }
            }
        }
        
        let inputNode = interruptionEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        
        do {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                interruptionRequest.append(buffer)
            }
        } catch {
            print("Failed to install interruption monitoring tap: \(error)")
            return
        }
        
        interruptionEngine.prepare()
        do {
            try interruptionEngine.start()
            isMonitoringForInterruption = true
            print("✅ Simple interruption monitoring active")
        } catch {
            print("Failed to start interruption monitoring engine: \(error)")
            stopInterruptionMonitoring()
        }
    }
    
    // MUCH SIMPLER: Only accept clear interruption words
    private func isSimpleInterruption(_ transcription: String) -> Bool {
        let cleanTranscription = transcription.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Must be substantial
        guard cleanTranscription.count > 2 else {
            return false
        }
        
        // VERY STRICT: Only accept phrases that clearly start with interruption words OR contain them prominently
        let clearInterruptions = [
            "wait", "stop", "hold on", "excuse me", "actually", "but", "no",
            "let me", "can you", "what about", "how about", "hey", "sorry",
            "i want", "i need", "i have", "question", "can i ask"
        ]
        
        // Check if it starts with interruption words OR contains them prominently
        let hasInterruption = clearInterruptions.contains { word in
            cleanTranscription.hasPrefix(word + " ") ||
            cleanTranscription == word ||
            cleanTranscription.hasPrefix(word) ||
            cleanTranscription.contains(" " + word + " ") ||  // Contains word with spaces around it
            cleanTranscription.hasSuffix(" " + word)          // Ends with the word
        }
        
        if hasInterruption {
            print("✅ Clear interruption detected: '\(cleanTranscription)'")
            return true
        }
        
        print("🔇 Not a clear interruption: '\(cleanTranscription)'")
        return false
    }
    
    func stopInterruptionMonitoring() {
        guard isMonitoringForInterruption else { return }
        
        print("🛑 Stopping interruption monitoring")
        
        interruptionTimer?.invalidate()
        interruptionTimer = nil
        
        if interruptionEngine.isRunning {
            interruptionEngine.stop()
            interruptionEngine.inputNode.removeTap(onBus: 0)
        }
        
        interruptionRecognitionRequest?.endAudio()
        interruptionRecognitionRequest = nil
        
        interruptionRecognitionTask?.cancel()
        interruptionRecognitionTask = nil
        
        isMonitoringForInterruption = false
        
        print("✅ Interruption monitoring stopped")
    }
    
    private func isGenuineUserInterruption(_ transcription: String) -> Bool {
        let cleanTranscription = transcription.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Lower threshold for interruption detection
        guard cleanTranscription.count > 3 else {
            print("🔇 Too short to be interruption: '\(cleanTranscription)'")
            return false
        }
        
        var matchPercentage = 0.0
        
        if !currentAIResponse.isEmpty {
            let aiWords = currentAIResponse.components(separatedBy: " ").filter { !$0.isEmpty }
            let transcriptionWords = cleanTranscription.components(separatedBy: " ").filter { !$0.isEmpty }
            
            // More sophisticated matching - look for exact sequence matches
            let matchingWords = transcriptionWords.filter { word in
                aiWords.contains { aiWord in
                    // Exact match or very close match
                    word == aiWord || (word.count > 3 && aiWord.contains(word)) || (aiWord.count > 3 && word.contains(aiWord))
                }
            }
            
            matchPercentage = transcriptionWords.isEmpty ? 0.0 : Double(matchingWords.count) / Double(transcriptionWords.count)
            
            // Only filter if it's a very high match (90% instead of 70%)
            if matchPercentage > 0.9 {
                print("🔇 Filtered AI echo (\(Int(matchPercentage * 100))% match): '\(cleanTranscription)'")
                return false
            }
        }
        
        // Look for clear interruption patterns
        let interruptionStarters = [
            "actually", "wait", "hold on", "stop", "excuse me", "sorry", "no", "but",
            "let me", "can you", "what about", "how about", "but what",
            "actually let me", "wait a minute", "hold up", "one second", "hey",
            "i want", "i need", "can i", "let me ask", "i have a", "question"
        ]
        
        let hasInterruptionPattern = interruptionStarters.contains { starter in
            cleanTranscription.hasPrefix(starter) || cleanTranscription.contains(" \(starter) ")
        }
        
        // Look for question patterns
        let hasQuestionPattern = cleanTranscription.contains("?") ||
                                cleanTranscription.hasPrefix("how ") ||
                                cleanTranscription.hasPrefix("what ") ||
                                cleanTranscription.hasPrefix("why ") ||
                                cleanTranscription.hasPrefix("when ") ||
                                cleanTranscription.hasPrefix("where ") ||
                                cleanTranscription.hasPrefix("can ") ||
                                cleanTranscription.hasPrefix("will ") ||
                                cleanTranscription.hasPrefix("do ")
        
        // Look for words that are unlikely to be in AI response
        let userSpecificWords = ["i", "me", "my", "myself", "you", "your", "want", "need", "think", "feel"]
        let hasUserWords = userSpecificWords.contains { userWord in
            cleanTranscription.components(separatedBy: " ").contains(userWord)
        }
        
        // Be more lenient - accept if ANY of these conditions are met
        let isGenuine = hasInterruptionPattern || hasQuestionPattern || hasUserWords || matchPercentage < 0.5
        
        if isGenuine {
            print("✅ Genuine interruption detected: '\(cleanTranscription)' - pattern=\(hasInterruptionPattern), question=\(hasQuestionPattern), userWords=\(hasUserWords), match=\(Int(matchPercentage * 100))%")
        } else {
            print("🔇 Not recognized as interruption: '\(cleanTranscription)' - match=\(Int(matchPercentage * 100))%")
        }
        
        return isGenuine
    }
    
    private func handleInterruption(with speech: String) {
        print("🚨 Processing interruption: '\(speech)'")
        
        stopInterruptionMonitoring()
        
        transcript = speech
        hasContent = true
        
        onInterruption?()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.processAutoUpload()
        }
    }
}
