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
                
                // Quick Questions Section
                if messages.isEmpty {
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
                
                // Input Section
                VStack(spacing: 12) {
                    // Voice Recognition Status
                    if speechRecognizer.isRecording {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundColor(.red)
                                .symbolEffect(.pulse)
                            Text("Listening...")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    // Text Input Row
                    HStack(spacing: 12) {
                        // Text Field
                        TextField("Ask for wisdom or guidance...", text: $inputText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .disabled(isLoading)
                            .onSubmit {
                                if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    askQuestion(inputText)
                                }
                            }
                        
                        // Voice Button
                        Button(action: toggleRecording) {
                            Image(systemName: speechRecognizer.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.title2)
                                .foregroundColor(speechRecognizer.isRecording ? .red : .blue)
                        }
                        .disabled(isLoading)
                        
                        // Send Button
                        Button(action: {
                            if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                askQuestion(inputText)
                            }
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading ? .gray : .blue)
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
                .background(Color(.systemBackground))
            }
            .navigationTitle("🏛️ Plato")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                speechRecognizer.requestPermission()
            }
            .onChange(of: speechRecognizer.transcript) { transcript in
                if !transcript.isEmpty {
                    inputText = transcript
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
    
    private func toggleRecording() {
        if speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        } else {
            speechRecognizer.startRecording()
            inputText = "" // Clear previous text when starting new recording
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
        
        // Stop any ongoing recording
        if speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        }
        
        // Set loading state
        isLoading = true
        
        // Get AI response
        Task {
            do {
                let response = try await philosophyService.getPhilosophicalResponse(
                    for: trimmedQuestion,
                    conversationHistory: messages.filter { !$0.isUser } // Only pass previous AI responses for context
                )
                
                await MainActor.run {
                    // Add AI response
                    let aiMessage = Message(text: response, isUser: false)
                    messages.append(aiMessage)
                    
                    // Speak the response using ElevenLabs
                    Task {
                        await elevenLabsService.speak(response)
                    }
                    
                    isLoading = false
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
