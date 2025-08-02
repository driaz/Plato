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
    
    @State private var isAlwaysListening = true {
        didSet { ContentView.isAlwaysListeningGlobal = isAlwaysListening }
    }
    
    @State private var hasShownWelcome = false
    
    // Streaming accumulation for current assistant turn
    @State private var streamingBuffer: String = ""
    
    @State private var lastAssistantUtterance: String = ""
    @State private var echoGuardUntil: Date = .distantPast
    
    // MARK: - Chunked TTS State
    @State private var ttsQueue: [String] = []
    @State private var isPlayingTTS = false
    @State private var currentTTSTask: Task<Void, Never>?
    @State private var pendingSentences: Set<String> = []
    
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
                
                // Voice Configuration Status
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: elevenLabsService.isConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(elevenLabsService.isConfigured ? .green : .orange)
                        Text(elevenLabsService.isConfigured ? "🎭 ElevenLabs Voice (George)" : "🔊 System Voice (Fallback)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if elevenLabsService.isSpeaking || !ttsQueue.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundColor(.blue)
                                    .symbolEffect(.pulse)
                                if !ttsQueue.isEmpty {
                                    Text("(\(ttsQueue.count))")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)
            }
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
                        print("🛡️ Dropping transcript (within echo guard window): \(trimmed)")
                        return
                    }
                    if isEcho(transcript: trimmed, of: lastAssistantUtterance) {
                        print("🛡️ Dropping AI echo transcript: \(trimmed)")
                        return
                    }
                    
                    askQuestion(trimmed)
                    inputText = ""
                    speechRecognizer.transcript = ""
                }
                
                speechRecognizer.onInterruption = {
                    print("🚨 User interrupted AI – stopping voice playback")
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
            
//            .overlay(alignment: .bottom) {
//                VStack {
//                    Button("Test ElevenLabs Formats") {
//                        Task {
//                            await elevenLabsService.probeAllFormats()
//                        }
//                    }
//                    .buttonStyle(.borderedProminent)
//                    .padding()
//                    
//                    Button("Test Streaming Endpoint") {
//                        Task {
//                            await elevenLabsService.testStreamingEndpoint()
//                        }
//                    }
//                    .buttonStyle(.bordered)
//                    .padding()
//                    
//                }
//                .background(.ultraThinMaterial)
//            }
            .onChange(of: speechRecognizer.transcript, initial: false) { oldText, newText in
                guard !elevenLabsService.isSpeaking else { return }
//                print("📥 partial:", newText)
                if !newText.isEmpty {
                    inputText = newText
                }
            }
//            .onChange(of: elevenLabsService.isSpeaking) { _, isSpeaking in
//                guard isAlwaysListening else { return }
//                if isSpeaking {
//                    print("🛑 TTS started - stopping speech recognition immediately")
//                    speechRecognizer.stopRecording()
//                    speechRecognizer.pauseListening()  // Prevent any restarts
//                } else {
//                    print("✅ TTS finished - can resume speech recognition")
//                    speechRecognizer.resumeListening()
//                    
//                    // Resume after a short delay to avoid catching echo
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
//                        if isAlwaysListening && !speechRecognizer.isRecording && !elevenLabsService.isSpeaking {
//                            speechRecognizer.startRecording()
//                        }
//                    }
//                }
//            }
//            .onChange(of: elevenLabsService.isSpeaking) { _, isSpeaking in
//                guard isAlwaysListening else { return }
//                if isSpeaking {
//                    print("🛑 TTS started - stopping speech recognition immediately")
//                    speechRecognizer.stopRecording()
//                }
//                // Let notifyTTSComplete() handle the resume logic
//            }
//            .onChange(of: elevenLabsService.isSpeaking) { _, isSpeaking in
//                guard isAlwaysListening else { return }
//                if isSpeaking {
//                    // Only stop if actually recording to prevent unnecessary stops
//                    if speechRecognizer.isRecording {
//                        print("🛑 Stopping speech recognizer for TTS playback")
//                        speechRecognizer.stopRecording()
//                    }
//                }
//                // Don't handle the false case - let notifyTTSComplete() handle resuming
//            }
            .overlay(alignment: .bottom) {
                #if DEBUG
                VStack {
                    Text("🧪 PCM Streaming Tests")
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.top, 8)
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            Task {
                                // Test tone (Phase 1)
                                print("🛑 Stopping all audio activity for test...")
                                
                                let wasAlwaysListening = isAlwaysListening
                                if wasAlwaysListening {
                                    isAlwaysListening = false
                                    speechRecognizer.stopAlwaysListening()
                                }
                                
                                speechRecognizer.stopRecording()
                                elevenLabsService.stopSpeaking()
                                
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                
                                print("🎵 Running PCM test...")
                                let player = MinimalPCMPlayer()
                                await player.testPCMPlayback()
                                
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                
                                if wasAlwaysListening {
                                    isAlwaysListening = true
                                    speechRecognizer.startAlwaysListening()
                                }
                                
                                print("✅ Test complete, normal operation resumed")
                            }
                        }) {
                            Label("Phase 1", systemImage: "waveform")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button(action: {
                            Task {
                                // ElevenLabs streaming (Phase 2)
                                print("🛑 Stopping all audio activity for streaming test...")
                                
                                let wasAlwaysListening = isAlwaysListening
                                if wasAlwaysListening {
                                    isAlwaysListening = false
                                    speechRecognizer.stopAlwaysListening()
                                }
                                
                                speechRecognizer.stopRecording()
                                elevenLabsService.stopSpeaking()
                                
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                
                                print("🎵 Running ElevenLabs PCM streaming test...")
                                let player = MinimalPCMPlayer()
                                await player.testElevenLabsPCM()
                                
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                
                                if wasAlwaysListening {
                                    isAlwaysListening = true
                                    speechRecognizer.startAlwaysListening()
                                }
                                
                                print("✅ Streaming test complete")
                            }
                        }) {
                            Label("Phase 2", systemImage: "waveform.and.person.filled")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!elevenLabsService.isConfigured)
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .padding(.bottom, 50)
                #endif
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
                    .animation(speechRecognizer.isRecording ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: speechRecognizer.isRecording)
                
                if speechRecognizer.isProcessing {
                    Text("Processing your question...")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else if elevenLabsService.isSpeaking {
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
                let full = try await philosophyService.streamResponse(
                    question: trimmed,
                    history: priorHistory + [userMsg], // don't include placeholder
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
                
                // finalize assistant turn
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

// Add this debug version of askQuestion to your ContentView

extension ContentView {
    
    /// Debug version of askQuestion with PCM logging
    private func askQuestionDebug(_ question: String) {
        print("\n🔍 ===== askQuestion DEBUG START =====")
        print("📝 Question: \(question)")
        print("🔧 PCM Config:")
        print("   - useStreamingTTS: \(ConfigManager.shared.useStreamingTTS)")
        print("   - hasElevenLabs: \(ConfigManager.shared.hasElevenLabs)")
        
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
                print("🤖 Getting philosophy response...")
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
                
                print("✅ Got response: \(full.prefix(50))...")
                
                // finalize assistant turn
                if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[idx].text = full
                }
                isLoading = false
                
                lastAssistantUtterance = normalizeForEcho(full)
                
                // Speak the full response at once
                print("🎤 Starting TTS...")
                print("   - Using \(ConfigManager.shared.useStreamingTTS ? "PCM" : "MP3") mode")
                
                let ttsStart = Date()
                await elevenLabsService.speak(full)
                let ttsDuration = Date().timeIntervalSince(ttsStart) * 1000
                
                print("✅ TTS completed in \(Int(ttsDuration))ms")
                print("🔍 ===== askQuestion DEBUG END =====\n")
                
            } catch {
                print("❌ Error in askQuestion: \(error)")
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

// Also add this test button to your debug overlay
//struct PCMProductionTestButton: View {
//    let parentView: ContentView
//    
//    var body: some View {
//        Button(action: {
//            // Force enable PCM
////            ConfigManager.shared.useStreamingTTS = true
//            UserDefaults.standard.synchronize()
//            
//            // Test with a simple question
//            parentView.askQuestionDebug("What is wisdom?")
//        }) {
//            Label("Test Production PCM", systemImage: "play.circle")
//                .font(.caption)
//        }
//        .buttonStyle(.borderedProminent)
//        .controlSize(.small)
//    }
//}
