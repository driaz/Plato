//
//  SpeechRecognizer.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//

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
    
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Auto-upload functionality
    private var silenceTimer: Timer?
    private var lastTranscriptUpdate = Date()
    private let silenceThreshold: TimeInterval = 3.0
    private var hasContent = false
    private var isAlwaysListening = false
    private var isPaused = false
    
    // Callback for auto-upload
    var onAutoUpload: ((String) -> Void)?
    
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
    
    func pauseListening() {
        print("pauseListening called - isRecording: \(isRecording), isAlwaysListening: \(isAlwaysListening)")
        if isAlwaysListening {
            print("Setting paused state while AI speaks...")
            isPaused = true
            if isRecording {
                stopRecording()
            }
        }
    }
    
    func resumeListening() {
        print("resumeListening called - isAlwaysListening: \(isAlwaysListening), isRecording: \(isRecording), isPaused: \(isPaused)")
        if isAlwaysListening && !isRecording && isPaused {
            print("Resuming listening after AI finished speaking...")
            isPaused = false
            transcript = "" // Clear any picked-up AI speech
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
        
        // Configure audio session with better error handling
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // First deactivate any existing session
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            
            // Configure for recording (remove defaultToSpeaker option)
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio session configured successfully")
        } catch {
            print("Failed to set up audio session: \(error)")
            // Don't return here - try to continue anyway
        }
        
        // Create recognition request with better settings
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            print("Unable to create recognition request")
            return
        }
        
        // Enhanced recognition settings for maximum accuracy
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false // Server has better accuracy
        recognitionRequest.taskHint = .dictation // Best for conversational speech
        
        // Add comprehensive context hints for better recognition
        if #available(iOS 16.0, *) {
            recognitionRequest.addsPunctuation = true
            
            // Extensive contextual vocabulary for philosophical conversations
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
        
        // For iOS 15 and earlier, we'll rely on post-processing corrections
        if #available(iOS 17.0, *) {
            // iOS 17+ has even better recognition capabilities
            recognitionRequest.interactionIdentifier = "philosophical_conversation"
        }
        
        // Get input node with error handling
        let inputNode = audioEngine.inputNode
        
        // Remove any existing taps
        inputNode.removeTap(onBus: 0)
        
        // Create recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result = result {
                    // Get the best transcription
                    let transcription = result.bestTranscription.formattedString
                    
                    // Apply post-processing corrections
                    let correctedText = self?.correctCommonMistakes(transcription) ?? transcription
                    self?.transcript = correctedText
                    
                    // Update timestamp and content flag
                    self?.lastTranscriptUpdate = Date()
                    self?.hasContent = !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    
                    // Reset silence timer
                    self?.resetSilenceTimer()
                    
                    // If this is a final result with content, process immediately
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
        
        // Configure audio input with better quality settings
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
        
        // Start audio engine with error handling
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
    
    // Post-processing to fix common philosophical term mistakes while preserving natural speech
    private func correctCommonMistakes(_ text: String) -> String {
        var corrected = text
        
        // Step 1: Fix philosophical term misrecognitions
        let philosophicalCorrections: [String: String] = [
            "markets": "Marcus",
            "market": "Marcus",
            "Marcus": "Marcus Aurelius", // Expand to full name
            "epic": "Epictetus",
            "epics": "Epictetus",
            "seneca": "Seneca",
            "stoic": "Stoic",
            "stoics": "Stoics",
            "stoicism": "Stoicism"
        ]
        
        // Apply philosophical corrections with word boundaries
        for (mistake, correction) in philosophicalCorrections {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: mistake))\\b"
            corrected = corrected.replacingOccurrences(
                of: pattern,
                with: correction,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        // Step 2: Normalize colloquial speech for better AI understanding
        corrected = normalizeColloquialSpeech(corrected)
        
        return corrected
    }
    
    private func normalizeColloquialSpeech(_ text: String) -> String {
        var normalized = text
        
        // Step 1: Fix common speech recognition errors for philosophical phrases
        let phraseCorrections: [String: String] = [
            // Meditation and mindfulness phrases
            "sit and stillness": "sit in stillness",
            "sit in silence": "sit in silence",
            "inner piece": "inner peace",
            "piece of mind": "peace of mind",
            "presents moment": "present moment",
            "present mmoment": "present moment",
            "letting goal": "letting go",
            "let it goal": "let it go",
            
            // Philosophical concepts
            "ancient wisdom": "ancient wisdom",
            "stoic principals": "Stoic principles",
            "self reflection": "self-reflection",
            "mental clarity": "mental clarity",
            "emotional control": "emotional control",
            
            // Common action phrases
            "except it": "accept it",
            "except what": "accept what",
            "breathe deeply": "breathe deeply",
            "find balance": "find balance",
            
            // Question patterns
            "how do i": "how do I",
            "what would": "what would",
            "how can i": "how can I",
            "what should i": "what should I"
        ]
        
        // Apply phrase corrections first (before word-level fixes)
        for (incorrect, correct) in phraseCorrections {
            normalized = normalized.replacingOccurrences(
                of: incorrect,
                with: correct,
                options: .caseInsensitive
            )
        }
        
        // Step 2: Handle colloquial speech normalization
        let colloquialMappings: [String: String] = [
            // Filler words - keep some, remove excessive
            " uh uh ": " uh ",           // Reduce double fillers
            " um um ": " um ",
            " like like ": " like ",
            
            // Common contractions and casual speech
            "kinda": "kind of",
            "gonna": "going to",
            "wanna": "want to",
            "gotta": "got to",
            "sorta": "sort of",
            
            // Question patterns
            "ya know": "you know",
            "y'know": "you know",
            "ya think": "you think",
            
            // Casual intensifiers
            "super ": "very ",
            "pretty ": "quite ",
            "really really": "really",
            "very very": "very",
            
            // Clean up excessive repetition while keeping natural flow
            "and and": "and",
            "but but": "but",
            "so so": "so",
            "the the": "the",
            
            // Fix common speech recognition errors
            "could of": "could have",
            "would of": "would have",
            "should of": "should have"
        ]
        
        // Apply casual speech normalization
        for (casual, formal) in colloquialMappings {
            normalized = normalized.replacingOccurrences(
                of: casual,
                with: formal,
                options: .caseInsensitive
            )
        }
        
        // Step 3: Clean up spacing and punctuation
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
        
        // Only start timer if we have content and are still recording
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
        
        // Small delay to show processing state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.onAutoUpload?(self.transcript)
            
            // In always-listening mode, stop recording and let the speaking detection restart it
            if self.isAlwaysListening {
                self.stopRecording() // Don't auto-restart - let the speaking detection handle it
            } else {
                self.stopRecording()
            }
            
            self.isProcessing = false
        }
    }
    
    func manualUpload() {
        // Allow manual upload by stopping auto-timer and processing immediately
        silenceTimer?.invalidate()
        if hasContent {
            processAutoUpload()
        }
    }
    
    func stopRecording() {
        // Clean up timers first
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        // Stop audio engine safely
        if audioEngine.isRunning {
            audioEngine.stop()
            
            // Remove tap safely
            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0)
        }
        
        // Clean up recognition request
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Cancel recognition task
        recognitionTask?.cancel()
        recognitionTask = nil
        
        // Update state
        isRecording = false
        hasContent = false
        
        // Deactivate audio session with better error handling
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to deactivate audio session: \(error)")
            // Continue anyway - this is not critical
        }
    }
}
