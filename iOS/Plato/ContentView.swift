//
//  ContentView.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//  Updated for Chunked TTS
//

import SwiftUI

struct ContentView: View {
    static weak var sharedSpeechRecognizer: SpeechRecognizer?
    static var isAlwaysListeningGlobal = false
    static weak var sharedElevenLabs: ElevenLabsService?

    
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingError = false
    
    @Environment(\.colorScheme) var colorScheme
    
    
    @State private var isAlwaysListening = true {
        didSet { ContentView.isAlwaysListeningGlobal = isAlwaysListening }
    }
    
    @State private var hasShownWelcome = false
    
    // Streaming accumulation for current assistant turn
    @State private var streamingBuffer: String = ""
    
    @State private var lastAssistantUtterance: String = ""
    @State private var echoGuardUntil: Date = .distantPast
    @State private var lastStreamUpdate = Date.distantPast

    
    // MARK: - Chunked TTS State
    @State private var ttsQueue: [String] = []
    @State private var isPlayingTTS = false
    @State private var currentTTSTask: Task<Void, Never>?
    @State private var pendingSentences: Set<String> = []
    
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var elevenLabsService = ElevenLabsService()
    @StateObject private var philosophyService = PhilosophyService()
    
    private var backgroundGradient: LinearGradient {
        let isDarkMode = colorScheme == .dark
        
        if elevenLabsService.isSpeaking {
            // Orange gradient when Plato is speaking
            return LinearGradient(
                colors: isDarkMode ? [
                    // Dark mode: Much stronger orange for visibility
                    Color.orange.opacity(0.25),
                    Color.orange.opacity(0.15),
                    Color.clear
                ] : [
                    // Light mode: Keep current subtle values
                    Color.orange.opacity(0.08),
                    Color.orange.opacity(0.03),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            // Blue gradient when listening/ready
            return LinearGradient(
                colors: isDarkMode ? [
                    // Dark mode: Much stronger blue for visibility
                    Color.blue.opacity(0.25),
                    Color.blue.opacity(0.15),
                    Color.clear
                ] : [
                    // Light mode: Keep current subtle values
                    Color.blue.opacity(0.05),
                    Color.blue.opacity(0.02),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
    
    // Quick question buttons
    let quickQuestions = [
        "How do I deal with stress?",
        "What would Marcus Aurelius say about failure?",
        "How can I be more resilient?",
        "What is the Stoic view on anger?",
        "How do I find peace in difficult times?"
    ]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Chat Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // Welcome placeholder
                            if messages.isEmpty && hasShownWelcome {
                                welcomeView
                            }
                            
                            // Chat bubbles
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            
                            // Loading indicator (LLM working)
                            if isLoading {
                                HStack {
                                    ProgressView().scaleEffect(0.8)
                                    Text(elevenLabsService.isGenerating ? "Generating voice..." : "Contemplating wisdom...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                            }
                        }
                        .padding(.horizontal)
                    }
                    .onChange(of: messages, initial: false) { _, _ in
                        if let lastMessage = messages.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Divider()
                
                // Quick Questions (manual mode)
                if messages.isEmpty && !isAlwaysListening && hasShownWelcome {
                    quickQuestionsView
                }
                
                voiceStatusBar
                
                // Manual text input row (shown when not always listening OR mic perms denied)
                if !isAlwaysListening || !speechRecognizer.isAuthorized {
                    manualInputRow
                }
            }
            .background(backgroundGradient)
            .animation(.easeInOut(duration: 0.3), value: elevenLabsService.isSpeaking)
            .navigationTitle("🏛️ Plato")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                ContentView.sharedSpeechRecognizer = speechRecognizer
                ContentView.sharedElevenLabs = elevenLabsService  
                AudioSessionManager.shared.configureForDuplex()
                speechRecognizer.requestPermission()
                
                speechRecognizer.onAutoUpload = { transcript in
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    
                    if Date() < echoGuardUntil {
                        Logger.shared.echoDetected(trimmed, reason: "Within echo guard window")
                        return
                    }
                    if isEcho(transcript: trimmed, of: lastAssistantUtterance) {
                        Logger.shared.echoDetected(trimmed, reason: "AI echo detected (content overlap)")
                        return
                    }
                    
                    askQuestion(trimmed)
                    inputText = ""
                    speechRecognizer.transcript = ""
                }
                
                speechRecognizer.onInterruption = {
                    log("User interrupted AI - stopping voice playback", category: .flow, level: .info)
                    stopAllTTS()
                }
                
                hasShownWelcome = true
            }
            .onChange(of: speechRecognizer.isAuthorized, initial: false) { _, isAuth in
                if isAuth && isAlwaysListening && !speechRecognizer.isRecording {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        speechRecognizer.startAlwaysListening()
                    }
                }
            }
            .onDisappear {
                speechRecognizer.stopAlwaysListening()
                stopAllTTS()
            }
            .onChange(of: speechRecognizer.transcript, initial: false) { oldText, newText in
                guard !elevenLabsService.isSpeaking else { return }
                if !newText.isEmpty {
                    inputText = newText
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func isEcho(transcript: String, of assistant: String) -> Bool {
        guard !assistant.isEmpty else { return false }
        let t = transcript.lowercased()
        let a = assistant.lowercased()
        
        if a.contains(t) || t.contains(a) { return true }
        
        let tTokens = Set(t.split{ !$0.isLetter })
        let aTokens = Set(a.split{ !$0.isLetter })
        guard !tTokens.isEmpty else { return false }
        let overlap = Double(tTokens.intersection(aTokens).count) / Double(tTokens.count)
        return overlap >= 0.7
    }
    
    private func normalizeForEcho(_ s: String) -> String {
        s.lowercased()
         .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
         .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Views
    
    private var welcomeView: some View {
        Group {
            if speechRecognizer.isAuthorized {
                Spacer()
                Spacer()
                Spacer()

                VStack(spacing: 32) {
                    // Larger Plato silhouette
                    Image("PlatoSilhouette")
                        .resizable()
                        .scaledToFit()
                        .frame(height: UIScreen.main.bounds.height * 0.26) // 26% of screen height
                    
                    VStack(spacing: 20) {
                        // Gray philosophical text
                        Text("I'm listening and ready for your questions about life, wisdom, and philosophy.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        // Simplified CTA
                        Text("Just start speaking!")
                            .font(.callout)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 40)
                
                Spacer()
                Spacer()
                Spacer()  // Extra spacer to push content up slightly from absolute center
            } else {
                // Permission request view
                VStack(spacing: 32) {
                    // Same large silhouette
                    Image("PlatoSilhouette")
                        .resizable()
                        .scaledToFit()
                        .frame(height: UIScreen.main.bounds.height * 0.26)
                    
                    VStack(spacing: 16) {
                        Text("To enable voice conversations, please grant microphone and speech recognition permissions.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        
                        Button("Open Settings") {
                            if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(settingsUrl)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                        
                        Text("You can still type questions below!")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    private var quickQuestionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("💭 Quick Questions")
                .font(.headline)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickQuestions, id: \.self) { question in
                        Button(action: {
                            askQuestion(question)
                        }) {
                            Text(question)
                                .font(.caption)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(16)
                        }
                        .disabled(isLoading)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }
    
    
    private var voiceStatusBar: some View {
        VStack(spacing: 4) {
            HStack {
                // Two-state dot: Blue (listening/ready) or Orange (speaking)
                Circle()
                    .fill(elevenLabsService.isSpeaking ? Color.orange : Color.blue)
                    .frame(width: 8, height: 8)
                    .scaleEffect(elevenLabsService.isSpeaking ? 1.2 : 1.0)
                    .animation(
                        elevenLabsService.isSpeaking ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                        value: elevenLabsService.isSpeaking
                    )
                
                // Keep all your existing status text logic - it's good!
                if speechRecognizer.isProcessing {
                    Text("Processing your question...")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else if elevenLabsService.isSpeaking {
                    Text("Plato is speaking right now...")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if speechRecognizer.isRecording && !inputText.isEmpty {
                    Text("Listening: \"\(inputText.prefix(30))\(inputText.count > 30 ? "..." : "")\"")
                        .font(.caption)
                        .foregroundColor(.primary)
                } else if speechRecognizer.isRecording {
                    Text("Listening for your question...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if isAlwaysListening {
                    Text("Ready to listen")
                        .font(.caption)
                        .foregroundColor(.blue)  // Changed from .red to match blue state
                } else {
                    Text("Always-listening disabled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: toggleAlwaysListening) {
                    Image(systemName: isAlwaysListening ? "ear.and.waveform" : "ear.and.waveform.slash")
                        .font(.caption)
                        .foregroundColor(isAlwaysListening ? .blue : .gray)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }
    
    private var manualInputRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                TextField("Type your question or toggle listening above...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(isLoading)
                    .onSubmit {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            askQuestion(inputText)
                        }
                    }
                
                Button(action: toggleRecording) {
                    Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundColor(speechRecognizer.isRecording ? .red : .blue)
                        .symbolEffect(.pulse, isActive: speechRecognizer.isRecording)
                }
                .disabled(isLoading)
                
                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: {
                        askQuestion(inputText)
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                    .disabled(isLoading)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }
    
    // MARK: - Actions
    
    private func toggleAlwaysListening() {
        isAlwaysListening.toggle()
        if isAlwaysListening {
            speechRecognizer.startAlwaysListening()
        } else {
            speechRecognizer.stopAlwaysListening()
        }
    }
    
    private func toggleRecording() {
        if speechRecognizer.isRecording {
            speechRecognizer.manualUpload()
        } else {
            speechRecognizer.startRecording()
            inputText = ""
        }
    }
    
    /// Streaming ask with chunked TTS
    private func askQuestion(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !isLoading else { return }
        
        // Stop any ongoing TTS
        stopAllTTS()
        
        // capture history BEFORE adding assistant placeholder
        let priorHistory = messages
        
        // append user message
        let userMsg = ChatMessage.user(trimmed)
        messages.append(userMsg)
        inputText = ""
        
        // manual mode stop if needed
        if !isAlwaysListening && speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        }
        
        isLoading = true
        speechRecognizer.stopRecording()
        streamingBuffer = ""
        
        // placeholder for assistant
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
        
        Task {
            do {
                let full = try await philosophyService.streamResponseWithSearch(
                    question: trimmed,
                    history: priorHistory + [userMsg],
                    onDelta: { delta in
                        streamingBuffer += delta
                        
                        // Throttle UI updates to prevent "multiple times per frame" warning
                        let now = Date()
                        if now.timeIntervalSince(lastStreamUpdate) >= 0.1 { // 100ms = 10 updates/sec
                            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                                messages[idx].text = streamingBuffer
                            }
                            lastStreamUpdate = now
                        }
                    },
                    onSentence: { _ in
                        // Intentionally empty - we're not using chunked TTS
                    }
                )
                
                // finalize assistant turn (ensures we don't miss the final text due to throttling)
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].text = full
                }
                isLoading = false
                
                lastAssistantUtterance = normalizeForEcho(full)
                
                // Speak the full response at once (smooth audio)
                await elevenLabsService.speak(full)
                
            } catch {
                let errText = "I apologize—trouble connecting to my wisdom. (\(error.localizedDescription))"
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].text = errText
                }
                isLoading = false
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
    
    // MARK: - Chunked TTS Management
    
    /// Plays the TTS queue sequentially
    private func playTTSQueue() async {
        isPlayingTTS = true
        
        while !ttsQueue.isEmpty {
            let sentence = ttsQueue.removeFirst()
            
            // Update echo guard with current sentence
            echoGuardUntil = Date().addingTimeInterval(2.0)
            
            await elevenLabsService.speak(sentence)
            
            // Wait for TTS to complete
            while elevenLabsService.isSpeaking {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
            }
            
            // Small gap between sentences for naturalness
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s (reduced from 0.2s)
        }
        
        isPlayingTTS = false
        
        // Resume listening after all TTS is done
        if isAlwaysListening && !speechRecognizer.isRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                speechRecognizer.startRecording()
            }
        }
    }
    
    /// Stops all TTS and clears the queue
    private func stopAllTTS() {
        currentTTSTask?.cancel()
        currentTTSTask = nil
        elevenLabsService.stopSpeaking()
        ttsQueue.removeAll()
        pendingSentences.removeAll()
        isPlayingTTS = false
    }
}

// MARK: - Message Bubble View
struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(18)
                    Text("You")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .cornerRadius(18)
                    Text("🏛️ Plato")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
}

// Add this debug version of askQuestion to your ContentView

extension ContentView {
    
    /// Debug version of askQuestion with PCM logging
    private func askQuestionDebug(_ question: String) {
        
        let flowId = Logger.shared.startFlow("askQuestion: \(question.prefix(30))...")
        logDebug("PCM Config - streaming: \(ConfigManager.shared.useStreamingTTS), elevenLabs: \(ConfigManager.shared.hasElevenLabs)", category: .tts)
        
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !isLoading else { return }
        
        // Stop any ongoing TTS
        stopAllTTS()
        
        // capture history BEFORE adding assistant placeholder
        let priorHistory = messages
        
        // append user message
        let userMsg = ChatMessage.user(trimmed)
        messages.append(userMsg)
        inputText = ""
        
        // manual mode stop if needed
        if !isAlwaysListening && speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        }
        
        isLoading = true
        speechRecognizer.stopRecording()
        streamingBuffer = ""
        
        // placeholder for assistant
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
        
        Task {
            do {
                Logger.shared.startTimer("Philosophy API")
                logDebug("Getting philosophy response", category: .llm)
                
                let full = try await philosophyService.streamResponse(
                    question: trimmed,
                    history: priorHistory + [userMsg],
                    onDelta: { delta in
                        streamingBuffer += delta
                        if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                            messages[idx].text = streamingBuffer
                        }
                    },
                    onSentence: { _ in
                        // Intentionally empty - we're not using chunked TTS
                    }
                )
                
                Logger.shared.endTimer("Philosophy API")
                logDebug("Got response: \(full.prefix(50))...", category: .llm)
                
                // finalize assistant turn
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].text = full
                }
                isLoading = false
                
                lastAssistantUtterance = normalizeForEcho(full)
                
                // Speak the full response at once
                let ttsMode = ConfigManager.shared.useStreamingTTS ? "PCM" : "MP3"
                log("Starting TTS in \(ttsMode) mode", category: .tts)

                Logger.shared.startTimer("TTS Speak")
                await elevenLabsService.speak(full)
                Logger.shared.endTimer("TTS Speak")

                Logger.shared.endFlow(flowId, name: "askQuestion")
                
            } catch {
                logError("Error in askQuestion: \(error)", category: .flow)
                let errText = "I apologize—trouble connecting to my wisdom. (\(error.localizedDescription))"
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].text = errText
                }
                isLoading = false
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}


