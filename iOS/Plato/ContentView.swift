//
//  ContentView.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
// /Users/danielriaz/Projects/Plato/iOS/Plato/ContentView.swift

import SwiftUI

struct ContentView: View {
    static weak var sharedSpeechRecognizer: SpeechRecognizer?
    static var isAlwaysListeningGlobal = false
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingError = false
    
    @State private var isAlwaysListening = true {
        didSet { ContentView.isAlwaysListeningGlobal = isAlwaysListening }
    }
    
    @State private var hasShownWelcome = false
    
    // Streaming accumulation for current assistant turn
    @State private var streamingBuffer: String = ""
    
    @State private var lastAssistantUtterance: String = ""
    @State private var echoGuardUntil: Date = .distantPast
    
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var elevenLabsService = ElevenLabsService()
    @StateObject private var philosophyService = PhilosophyService()

    
    
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
                            withAnimation(.easeOut(duration: 0.15)) {   // shorter anim for frequent updates
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
                
                // Voice Configuration Status
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: elevenLabsService.isConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(elevenLabsService.isConfigured ? .green : .orange)
                        Text(elevenLabsService.isConfigured ? "🎭 ElevenLabs Voice (George)" : "🔊 System Voice (Fallback)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if elevenLabsService.isSpeaking {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundColor(.blue)
                                .symbolEffect(.pulse)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("🏛️ Plato")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                //--------------------------------------------------
                // 1.  Register global reference (needed by TTS)
                //--------------------------------------------------
                ContentView.sharedSpeechRecognizer = speechRecognizer

                //--------------------------------------------------
                // 2.  Configure duplex session once UI is visible
                //--------------------------------------------------
                AudioSessionManager.shared.configureForDuplex()

                //--------------------------------------------------
                // 3.  Request permissions (do it only once)
                //--------------------------------------------------
                speechRecognizer.requestPermission()

                //--------------------------------------------------
                // 4.  Auto-upload callback
                //--------------------------------------------------
                speechRecognizer.onAutoUpload = { transcript in
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }

                    // Echo-guard: ignore early or AI-echo transcripts
                    if Date() < echoGuardUntil {           // time guard
                        print("🛡️ Dropping transcript (within echo guard window): \(trimmed)")
                        return
                    }
                    if isEcho(transcript: trimmed, of: lastAssistantUtterance) { // content guard
                        print("🛡️ Dropping AI echo transcript: \(trimmed)")
                        return
                    }

                    askQuestion(trimmed)
                    inputText = ""        // reset draft so next STT turn starts fresh
                    speechRecognizer.transcript = ""   // clear subtitle line (optional)
                }

                //--------------------------------------------------
                // 5.  Interruption callback
                //--------------------------------------------------
                speechRecognizer.onInterruption = {
                    print("🚨 User interrupted AI – stopping voice playback")
                    elevenLabsService.stopSpeaking()
                }

                hasShownWelcome = true

                /* Optional debug probe
                #if DEBUG
                Task {
                    await elevenLabsService.debugProbeStreamFormat(
                        sampleText: "George voice format probe.",
                        accept: "application/octet-stream",
                        outputFormat: "pcm_22050"
                    )
                }
                #endif
                */
            }

            
            // Mic permission → start always-listening
            .onChange(of: speechRecognizer.isAuthorized, initial: false) { _, isAuth in
                if isAuth && isAlwaysListening && !speechRecognizer.isRecording {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        speechRecognizer.startAlwaysListening()
                    }
                }
            }
            
            .onDisappear {
                speechRecognizer.stopAlwaysListening()
            }
            
            // Live transcript → show in text field (ignore while AI speaks)
            .onChange(of: speechRecognizer.transcript, initial: false) { oldText, newText in
                // Ignore updates while George is talking
                guard !elevenLabsService.isSpeaking else { return }

                // 🔍 Debug – see each partial result as it arrives
                print("📥 partial:", newText)

                // Mirror the live transcript into the draft field
                if !newText.isEmpty {
                    inputText = newText
                }
            }

            
            .onChange(of: elevenLabsService.isSpeaking) {
                guard isAlwaysListening else { return }

                if elevenLabsService.isSpeaking {
                    // TTS just started → pause mic
                    speechRecognizer.stopRecording()
                }
            }

            
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
            }
        }
    }
    
    private func isEcho(transcript: String, of assistant: String) -> Bool {
        guard !assistant.isEmpty else { return false }
        let t = transcript.lowercased()
        let a = assistant.lowercased()
        
        // Quick wins:
        if a.contains(t) || t.contains(a) { return true }
        
        // Token overlap heuristic
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
                VStack(spacing: 16) {
                    Image(systemName: "ear.and.waveform")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                        .symbolEffect(.pulse)
                    
                    VStack(spacing: 8) {
                        Text("🏛️ Welcome to Plato")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("I'm listening and ready for your questions about life, wisdom, and philosophy.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Text("Just start speaking - no need to tap anything!")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 60)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "mic.slash.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    
                    VStack(spacing: 8) {
                        Text("🏛️ Welcome to Plato")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("To enable voice conversations, please grant microphone and speech recognition permissions in Settings.")
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
                .padding(.vertical, 60)
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
                Circle()
                    .fill(speechRecognizer.isRecording ? Color.red : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(speechRecognizer.isRecording ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: speechRecognizer.isRecording)
                
                if speechRecognizer.isProcessing {
                    Text("Processing your question...")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else if elevenLabsService.isSpeaking || speechRecognizer.isMonitoringForInterruption {
                    Text("AI is speaking (you can interrupt anytime)...")
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
                    Text("Ready to listen (should auto-resume)")
                        .font(.caption)
                        .foregroundColor(.red)
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
    
    /// Streaming ask
    private func askQuestion(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && !isLoading else { return }
        
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
        streamingBuffer = ""
        
        // placeholder for assistant
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))
        
        Task {
            do {
                let full = try await philosophyService.streamResponse(
                    question: trimmed,
                    history: priorHistory + [userMsg] // don't include placeholder
                ) { delta in
                    streamingBuffer += delta
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].text = streamingBuffer
                    }
                }
                
                // finalize assistant turn
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].text = full
                }
                isLoading = false
                
                lastAssistantUtterance = normalizeForEcho(full)
                
                // speak full response (chunked streaming later)
                Task {
                    await elevenLabsService.speak(full)
                }
                
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
                    Text("🏛️ Stoic Sage")
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
