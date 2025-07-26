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
    @Published var hasContent: Bool = false
    
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Always-on listening
    private var isAlwaysListening = false
    private var isPaused = false
    
    // Auto-upload
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 3.0
    private var lastTranscriptUpdate = Date()
    
    // Callbacks
    var onAutoUpload: ((String) -> Void)?
    var onInterruption: (() -> Void)?
    
    init() {
        print("🎤 SpeechRecognizer initialized")
        speechRecognizer?.defaultTaskHint = .dictation
    }
    
    // MARK: - Permissions
    
    func requestPermission() {
        print("🎤 Requesting permissions...")
        Task { @MainActor in
            // Microphone permission
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
            
            print("🎤 Microphone permission: \(micGranted)")
            
            guard micGranted else {
                self.isAuthorized = false
                print("❌ Microphone permission denied")
                return
            }
            
            // Speech recognition permission
            let speechAuth = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }
            
            self.isAuthorized = (speechAuth == .authorized)
            print(self.isAuthorized ? "✅ Speech recognition authorized" : "❌ Speech recognition not authorized: \(speechAuth.rawValue)")
            
            // Don't auto-start here - let ContentView control it
            if self.isAuthorized {
                print("🎤 Ready to start listening")
            }
        }
    }
    
    // MARK: - Always Listening
    
    func startAlwaysListening() {
        print("🎤 startAlwaysListening called - isAuthorized: \(isAuthorized)")
        guard isAuthorized else {
            print("❌ Speech recognition not authorized for always-on listening")
            return
        }
        isAlwaysListening = true
        isPaused = false
        print("🎤 Starting recording...")
        startRecording()
    }
    
    func stopAlwaysListening() {
        print("🎤 stopAlwaysListening called")
        isAlwaysListening = false
        isPaused = false
        stopRecording()
    }
    
    func pauseListening(aiResponse: String = "") {
        print("🎤 pauseListening called - isAlwaysListening: \(isAlwaysListening)")
        guard isAlwaysListening else { return }
        isPaused = true
        print("🔇 SpeechRecognizer paused (AI speaking)")
    }
    
    func resumeListening() {
        print("🎤 resumeListening called - isAlwaysListening: \(isAlwaysListening), isPaused: \(isPaused)")
        guard isAlwaysListening else { return }
        isPaused = false
        transcript = ""
        hasContent = false
        print("🎙️ SpeechRecognizer resumed - will restart recording")
        
        // Restart recording after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.isRecording && self.isAlwaysListening && !self.isPaused {
                print("🎤 Restarting recording after resume...")
                self.startRecording()
            }
        }
    }
    
    // MARK: - Recording
    
    func startRecording() {
        print("🎤 startRecording called - isRecording: \(isRecording), isAuthorized: \(isAuthorized)")
        
        guard isAuthorized else {
            print("❌ Not authorized to record")
            return
        }
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("❌ Speech recognizer not available")
            return
        }
        
        // Clean up any existing session
        stopRecording()
        
        // Configure audio session
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio session configured")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
            return
        }
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        
        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                self.handleRecognition(result: result)
            }
            
            if let error = error {
                Task { @MainActor in
                    print("❌ Recognition error: \(error)")
                    self.stopRecording()
                    
                    // Only restart for recoverable errors, not "No speech detected"
                    let nsError = error as NSError
                    if nsError.code == 1110 { // No speech detected
                        print("🔇 No speech detected - waiting for resume signal")
                        return
                    }
                    
                    // Restart if in always-listening mode
                    if self.isAlwaysListening && !self.isPaused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            print("🎤 Restarting after error...")
                            self.startRecording()
                        }
                    }
                }
            }
        }
        
        // Configure audio input
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            print("🎙️ Audio engine started - listening...")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            stopRecording()
        }
    }
    
    func stopRecording() {
        print("🎤 stopRecording called")
        
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            print("🔇 Audio engine stopped")
        }
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        isRecording = false
        hasContent = false
    }
    
    // MARK: - Recognition Handling
    
    private func handleRecognition(result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription.formattedString
        
        // Ensure UI updates on main thread
        Task { @MainActor in
            self.transcript = self.correctCommonMistakes(transcription)
            print("📝 Transcript: \(self.transcript)")
            
            self.lastTranscriptUpdate = Date()
            self.hasContent = !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            
            // Reset silence timer
            if self.hasContent && !self.isPaused {
                self.resetSilenceTimer()
            }
            
            // Handle final result
            if result.isFinal {
                print("📝 Final transcript: \(self.transcript)")
                if self.hasContent && !self.isPaused {
                    self.processAutoUpload()
                }
            }
        }
    }
    
    // MARK: - Auto Upload
    
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        
        guard hasContent && isRecording && !isPaused else { return }
        
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.processAutoUpload()
            }
        }
    }
    
    private func processAutoUpload() {
        guard hasContent && !transcript.isEmpty && !isPaused else { return }
        
        print("📤 Processing auto-upload: \(transcript)")
        
        isProcessing = true
        let finalTranscript = normalizeColloquialSpeech(transcript)
        
        // Clear state
        transcript = ""
        hasContent = false
        
        // Stop recording for upload
        if isRecording {
            stopRecording()
        }
        
        // Call upload handler
        onAutoUpload?(finalTranscript)
        
        isProcessing = false
        
        // Restart if always listening
        if isAlwaysListening && !isPaused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                print("🎤 Restarting after upload...")
                self.startRecording()
            }
        }
    }
    
    // MARK: - Text Processing
    
    private func correctCommonMistakes(_ text: String) -> String {
        var corrected = text
        
        let corrections = [
            "markets": "Marcus",
            "market": "Marcus",
            "markets aurelius": "Marcus Aurelius",
            "market aurelius": "Marcus Aurelius",
            "epic titus": "Epictetus",
            "epic tea tus": "Epictetus",
            "stoic": "Stoic",
            "stoicism": "Stoicism",
            "play-doh": "Plato",
            "play doh": "Plato",
            "playdo": "Plato",
            "playdough": "Plato"
        ]
        
        for (mistake, correction) in corrections {
            corrected = corrected.replacingOccurrences(
                of: mistake,
                with: correction,
                options: [.caseInsensitive],
                range: nil
            )
        }
        
        return corrected
    }
    
    private func normalizeColloquialSpeech(_ text: String) -> String {
        var normalized = text
        
        // Remove filler words at the beginning
        let fillerPrefixes = ["um ", "uh ", "so ", "like ", "well ", "hey "]
        for filler in fillerPrefixes {
            if normalized.lowercased().hasPrefix(filler) {
                normalized = String(normalized.dropFirst(filler.count))
            }
        }
        
        // Clean up
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Capitalize first letter
        if !normalized.isEmpty {
            normalized = normalized.prefix(1).uppercased() + normalized.dropFirst()
        }
        
        // Add question mark if needed
        let questionStarters = ["how", "what", "when", "where", "why", "who", "can", "could", "would", "should"]
        let firstWord = normalized.split(separator: " ").first?.lowercased() ?? ""
        if questionStarters.contains(firstWord) && !normalized.hasSuffix("?") {
            normalized += "?"
        }
        
        return normalized
    }
    
    // MARK: - Manual Upload
    
    func manualUpload() {
        processAutoUpload()
    }
}
