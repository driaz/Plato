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
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                switch authStatus {
                case .authorized:
                    self?.isAuthorized = true
                case .denied, .restricted, .notDetermined:
                    self?.isAuthorized = false
                @unknown default:
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
            
            // Configure for recording
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
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
        
        // Enhanced recognition settings
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false // Use server for better accuracy
        recognitionRequest.taskHint = .dictation // Better for philosophical conversations
        
        // Add context hints for better recognition of philosophical terms
        if #available(iOS 16.0, *) {
            recognitionRequest.addsPunctuation = true
            recognitionRequest.contextualStrings = [
                "Marcus Aurelius", "Epictetus", "Seneca", "Stoic", "stoicism",
                "philosophy", "philosopher", "wisdom", "virtue", "meditation",
                "acceptance", "resilience", "mindfulness", "contemplation"
            ]
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
    
    // Post-processing to fix common philosophical term mistakes
    private func correctCommonMistakes(_ text: String) -> String {
        var corrected = text
        
        // Common philosophy-related corrections
        let corrections: [String: String] = [
            "markets": "Marcus",
            "market": "Marcus",
            "Marcus": "Marcus Aurelius", // Expand to full name
            "epic": "Epictetus",
            "epics": "Epictetus",
            "seneca": "Seneca",
            "stoic": "Stoic",
            "stoics": "Stoics",
            "stoicism": "Stoicism",
            "philosophy": "philosophy",
            "philosopher": "philosopher",
            "meditations": "Meditations",
            "meditation": "meditation",
            "wisdom": "wisdom",
            "virtue": "virtue",
            "virtues": "virtues",
            "temperance": "temperance",
            "justice": "justice",
            "courage": "courage",
            "prudence": "prudence"
        ]
        
        // Apply word-boundary corrections (so we don't change partial words)
        for (mistake, correction) in corrections {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: mistake))\\b"
            corrected = corrected.replacingOccurrences(
                of: pattern,
                with: correction,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        return corrected
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
