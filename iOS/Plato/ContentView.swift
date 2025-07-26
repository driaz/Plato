//
//  ContentView.swift
//  Plato
//
//  Fixed version with proper threading and single triggers

import SwiftUI

struct ContentView: View {
    // Static reference for ElevenLabsService to control speech recognition
    static weak var sharedSpeechRecognizer: SpeechRecognizer?
    
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var elevenLabsService = ElevenLabsService()
    @StateObject private var philosophyService = PhilosophyService()
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var isAlwaysListening = true
    @State private var hasShownWelcome = false
    @State private var streamingBuffer: String = ""
    
    // Track speaking state to prevent double triggers
    @State private var lastSpeakingState = false
    
    // Quick questions
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
                            if messages.isEmpty && hasShownWelcome {
                                welcomeView
                            }
                            
                            ForEach(messages) { message in
                                ChatBubbleView(message: message)
                            }
                            
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
                    .onChange(of: messages.count) { _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            if let lastMessage = messages.last {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Divider()
                
                if messages.isEmpty && !isAlwaysListening {
                    quickQuestionsView
                }
                
                voiceStatusBar
                
                if !isAlwaysListening || !speechRecognizer.isAuthorized {
                    manualInputRow
                }
                
                // ElevenLabs status
                HStack {
                    Image(systemName: elevenLabsService.isConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(elevenLabsService.isConfigured ? .green : .orange)
                    Text(elevenLabsService.isConfigured ? "🎭 ElevenLabs Voice" : "🔊 System Voice")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .navigationTitle("🏛️ Plato")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                setupSpeechRecognizer()
            }
            .onChange(of: elevenLabsService.isSpeaking) { _, newValue in
                // Prevent double triggers
                guard newValue != lastSpeakingState else { return }
                lastSpeakingState = newValue
                
                handleSpeakingStateChange(isSpeaking: newValue)
            }
            .onDisappear {
                speechRecognizer.stopAlwaysListening()
            }
        }
    }
    
    // MARK: - Views
    
    private var welcomeView: some View {
        VStack(spacing: 16) {
            if speechRecognizer.isAuthorized {
                Image(systemName: "ear.and.waveform")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
                Text("I'm listening...")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Speak your philosophical question,\nand I'll share ancient wisdom.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "mic.slash.circle")
                    .font(.system(size: 50))
                    .foregroundColor(.red)
                Text("Microphone Access Required")
                    .font(.title2)
                    .fontWeight(.semibold)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 50)
    }
    
    private var quickQuestionsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(quickQuestions, id: \.self) { question in
                    Button(action: { askQuestion(question) }) {
                        Text(question)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(16)
                    }
                    .disabled(isLoading)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }
    
    private var voiceStatusBar: some View {
        HStack {
            Circle()
                .fill(speechRecognizer.isRecording ? Color.red : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
                .scaleEffect(speechRecognizer.isRecording ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: speechRecognizer.isRecording)
            
            if speechRecognizer.isProcessing {
                Text("Processing...")
                    .font(.caption)
                    .foregroundColor(.blue)
            } else if elevenLabsService.isSpeaking {
                Text("Speaking wisdom...")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if speechRecognizer.isRecording {
                Text("Listening...")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if isAlwaysListening {
                Text("Ready")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text("Tap mic to speak")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { isAlwaysListening.toggle() }) {
                Image(systemName: isAlwaysListening ? "ear.and.waveform" : "mic.slash")
                    .font(.caption)
                    .foregroundColor(isAlwaysListening ? .blue : .gray)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }
    
    private var manualInputRow: some View {
        HStack(spacing: 12) {
            TextField("Type your question...", text: $inputText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onSubmit {
                    if !inputText.isEmpty {
                        askQuestion(inputText)
                    }
                }
            
            Button(action: toggleRecording) {
                Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic.circle.fill")
                    .font(.title2)
                    .foregroundColor(speechRecognizer.isRecording ? .red : .blue)
            }
            .disabled(!speechRecognizer.isAuthorized)
        }
        .padding()
    }
    
    // MARK: - Actions
    
    private func setupSpeechRecognizer() {
        // Set static reference for ElevenLabsService
        ContentView.sharedSpeechRecognizer = speechRecognizer
        
        speechRecognizer.requestPermission()
        
        // Single handler for auto-upload
        speechRecognizer.onAutoUpload = { transcript in
            Task { @MainActor in
                print("📤 Auto-upload triggered with: \(transcript)")
                askQuestion(transcript)
            }
        }
        
        // Wait for authorization then start listening
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if speechRecognizer.isAuthorized && isAlwaysListening {
                print("🚀 Starting always-listening mode after authorization...")
                speechRecognizer.startAlwaysListening()
            }
        }
        
        hasShownWelcome = true
    }
    
    private func handleSpeakingStateChange(isSpeaking: Bool) {
        print("🔊 Speaking state changed: \(isSpeaking)")
        
        guard isAlwaysListening else { return }
        
        if isSpeaking {
            print("🔇 Pausing speech recognition...")
            speechRecognizer.pauseListening()
        } else {
            print("🎙️ Will resume speech recognition...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !elevenLabsService.isSpeaking { // Double check
                    speechRecognizer.resumeListening()
                }
            }
        }
    }
    
    private func toggleRecording() {
        if speechRecognizer.isRecording {
            speechRecognizer.manualUpload()
        } else {
            speechRecognizer.startRecording()
        }
    }
    
    private func askQuestion(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isLoading else { return } // Prevent double submissions
        
        inputText = ""
        
        // Add messages
        let userMsg = ChatMessage.user(trimmed)
        messages.append(userMsg)
        
        let assistantID = UUID()
        let assistantMsg = ChatMessage(id: assistantID, role: .assistant, text: "...")
        messages.append(assistantMsg)
        
        isLoading = true
        streamingBuffer = ""
        
        Task {
            do {
                let priorHistory = messages.dropLast(2).map { $0 }
                
                let fullResponse = try await philosophyService.streamResponse(
                    question: trimmed,
                    history: priorHistory + [userMsg]
                ) { delta in
                    Task { @MainActor in
                        streamingBuffer += delta
                        if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                            messages[idx].text = streamingBuffer
                        }
                    }
                }
                
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].text = fullResponse
                    }
                    isLoading = false
                }
                
                // Speak the response
                print("🎭 Starting TTS for: \(fullResponse.prefix(50))...")
                await elevenLabsService.speak(fullResponse)
                
            } catch {
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                        messages[idx].text = "I apologize, I had trouble connecting to my wisdom."
                    }
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
}
