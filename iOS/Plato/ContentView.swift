//
//  ContentView.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//


import SwiftUI

struct ContentView: View {
    @StateObject private var speechRecognizer = SpeechRecognizer()
    @StateObject private var textToSpeech = TextToSpeech()
    @State private var messages: [String] = []
    @State private var inputText: String = ""
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("🏛️ Plato")
                    .font(.largeTitle)
                
                if textToSpeech.isSpeaking {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.blue)
                        .font(.title2)
                }
            }
            .padding()
            
            // Messages Display
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                        HStack {
                            if message.hasPrefix("You:") {
                                Spacer()
                                Text(message)
                                    .padding(10)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            } else {
                                Text(message)
                                    .padding(10)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(12)
                                Spacer()
                            }
                        }
                    }
                }
                .padding()
            }
            
            // Voice Recording Status
            if speechRecognizer.isRecording {
                Text("🎤 Listening: \(speechRecognizer.transcribedText)")
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
            }
            
            // Input Area
            HStack {
                TextField("Ask for wisdom...", text: $inputText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Send") {
                    sendMessage(inputText)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            
            // Voice Button
            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                    Text(speechRecognizer.isRecording ? "Stop Recording" : "Tap to Speak")
                }
                .foregroundColor(.white)
                .padding()
                .background(speechRecognizer.isRecording ? Color.red : Color.blue)
                .cornerRadius(25)
            }
            .padding()
        }
        .onAppear {
            speechRecognizer.requestPermissions()
        }
        .onChange(of: speechRecognizer.transcribedText) { newText in
            inputText = newText
        }
    }
    
    private func sendMessage(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        
        // Add user message
        messages.append("You: \(message)")
        inputText = ""
        
        // Generate AI response
        let response = generateResponse(for: message)
        
        // Add AI response
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            messages.append("Plato: \(response)")
            // Speak the response
            textToSpeech.speak(response)
        }
    }
    
    private func generateResponse(for question: String) -> String {
        // Simple responses for now - we'll connect to your API later
        let responses = [
            "The unexamined life is not worth living.",
            "Wisdom begins in wonder.",
            "Courage is knowing what not to fear.",
            "The measure of a man is what he does with power.",
            "Opinion is the medium between knowledge and ignorance."
        ]
        
        return responses.randomElement() ?? "Seek wisdom in all things."
    }
    
    private func toggleRecording() {
        if speechRecognizer.isRecording {
            speechRecognizer.stopRecording()
        } else {
            speechRecognizer.startRecording()
        }
    }
}
