//
//  ContentView.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//


import SwiftUI

struct ContentView: View {
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var elevenLabsService = ElevenLabsService()
    @StateObject private var philosophyService = PhilosophyService()
    
    @State private var messages: [Message] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var isAlwaysListening = true
    @State private var hasShownWelcome = false
    
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
                            // Welcome message for always-on listening
                            if messages.isEmpty && hasShownWelcome {
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
                            }
                            
                            // Chat messages
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            
                            // Loading indicator
                            if isLoading {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
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
                        // Auto-scroll to bottom when new message arrives
                        if let lastMessage = messages.last {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                
                Divider()
                
                // Quick Questions Section (only when no messages and not always listening)
                if messages.isEmpty && !isAlwaysListening && hasShownWelcome {
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
                
                // Voice Status Bar - Always visible
                VStack(spacing: 4) {
                    HStack {
                        // Listening indicator
                        Circle()
                            .fill(speechRecognizer.isRecording ? Color.red : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .scaleEffect(speechRecognizer.isRecording ? 1.2 : 1.0)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: speechRecognizer.isRecording)
                        
                        if speechRecognizer.isProcessing {
                            Text("Processing your question...")
                                .font(.caption)
                                .foregroundColor(.blue)
                        } else if elevenLabsService.isSpeaking {
                            Text("AI is speaking (listening paused)...")
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
                                .foregroundColor(.red) // Red to indicate this shouldn't stay
                        } else {
                            Text("Always-listening disabled")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Toggle always-listening mode
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
                
                // Manual text input (only when always-listening is off)
                if !isAlwaysListening {
                    VStack(spacing: 12) {
                        // Text Input Row
                        HStack(spacing: 12) {
                            // Text Field
                            TextField("Type your question or toggle listening above...", text: $inputText)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .disabled(isLoading)
                                .onSubmit {
                                    if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        askQuestion(inputText)
                                    }
                                }
                            
                            // Voice Button (manual mode)
                            Button(action: toggleRecording) {
                                Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(speechRecognizer.isRecording ? .red : .blue)
                                    .symbolEffect(.pulse, isActive: speechRecognizer.isRecording)
                            }
                            .disabled(isLoading)
                            
                            // Send Button
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
                speechRecognizer.requestPermission()
                
                // Set up auto-upload callback
                speechRecognizer.onAutoUpload = { transcript in
                    askQuestion(transcript)
                }
                
                // Start always-listening after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if isAlwaysListening {
                        speechRecognizer.startAlwaysListening()
                    }
                    hasShownWelcome = true
                }
            }
            .onDisappear {
                // Stop listening when app goes away
                speechRecognizer.stopAlwaysListening()
            }
            .onChange(of: speechRecognizer.transcript) { transcript in
                if !transcript.isEmpty {
                    inputText = transcript
                }
            }
            .onChange(of: elevenLabsService.isSpeaking) { isSpeaking in
                // Pause/resume listening based on AI speaking state
                print("AI speaking state changed: \(isSpeaking)")
                if isAlwaysListening {
                    if isSpeaking {
                        // Pause listening while AI is speaking
                        print("Pausing listening - AI started speaking")
                        speechRecognizer.pauseListening()
                    } else {
                        // Resume listening when AI finishes speaking
                        print("AI finished speaking - resuming in 1 second...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            print("Attempting to resume listening...")
                            speechRecognizer.resumeListening()
                        }
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
            }
        }
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
        // This is only used in manual mode
        if speechRecognizer.isRecording {
            speechRecognizer.manualUpload()
        } else {
            speechRecognizer.startRecording()
            inputText = ""
        }
    }
    
    private func askQuestion(_ question: String) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty && !isLoading else { return }
        
        // Add user message
        let userMessage = Message(text: trimmedQuestion, isUser: true)
        messages.append(userMessage)
        
        // Clear input
        inputText = ""
        
        // Stop any ongoing recording if in manual mode
        if !isAlwaysListening && speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        }
        
        // Set loading state
        isLoading = true
        
        // Get AI response
        Task {
            do {
                let response = try await philosophyService.getPhilosophicalResponse(
                    for: trimmedQuestion,
                    conversationHistory: messages.filter { !$0.isUser }
                )
                
                await MainActor.run {
                    // Add AI response to UI immediately
                    let aiMessage = Message(text: response, isUser: false)
                    messages.append(aiMessage)
                    isLoading = false
                }
                
                // Start voice generation in parallel
                Task {
                    await elevenLabsService.speak(response)
                }
                
            } catch {
                await MainActor.run {
                    // Add error message to chat
                    let errorMsg = Message(text: "I apologize, but I'm having trouble connecting to my wisdom. Please try again. (\(error.localizedDescription))", isUser: false)
                    messages.append(errorMsg)
                    
                    // Show error alert
                    errorMessage = error.localizedDescription
                    showingError = true
                    
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Message Bubble View
struct MessageBubble: View {
    let message: Message
    
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
