//
//  RealtimeTestView.swift
//  Plato
//
//  Test view for OpenAI Realtime API integration
//  Simple UI to test WebSocket connection and audio streaming
//

import SwiftUI

struct RealtimeTestView: View {
    @StateObject private var realtimeManager = RealtimeManager()
    @State private var testMessage = ""
    @State private var logMessages: [String] = []
    @State private var startTime: Date?
    @State private var lastLatencyMs: Int = 0
    
    private var statusColor: Color {
        switch realtimeManager.connectionState {
        case .disconnected:
            return .gray
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }
    
    private var statusText: String {
        switch realtimeManager.connectionState {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .failed(let error):
            return "Failed: \(error.localizedDescription)"
        }
    }
    
    private var avatarStateIcon: String {
        switch realtimeManager.avatarState {
        case .idle:
            return "circle"
        case .listening:
            return "waveform.circle"
        case .thinking:
            return "brain"
        case .speaking:
            return "speaker.wave.2.circle"
        case .error:
            return "exclamationmark.circle"
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    connectionStatusView
                    // controlButtonsView - Removed for auto-connection
                    audioControlsView
                    textInputView
                    performanceView
                    
                    if !realtimeManager.currentTranscript.isEmpty {
                        transcriptView
                    }
                    
                    if !realtimeManager.assistantResponse.isEmpty {
                        assistantResponseView
                    }
                    
                    helperTextView
                    
                    Spacer(minLength: 20)
                }
                .padding()
            }
            .navigationTitle("Realtime API Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") {
                        clearAll()
                    }
                }
            }
            .onAppear {
                Task {
                    print("🚀 Auto-starting Realtime connection...")
                    
                    // Connect
                    realtimeManager.connect()
                    
                    // Wait for connection with multiple checks
                    for i in 0..<5 {  // Check 5 times
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                        
                        print("📊 Check \(i+1)/5 - Connection state: \(realtimeManager.connectionState)")
                        
                        if realtimeManager.connectionState == .connected {
                            print("✅ Connected! Starting audio...")
                            realtimeManager.startListening()
                            return  // Exit once we start listening
                        }
                    }
                    
                    // If still not connected after 5 seconds, show error
                    print("❌ Failed to connect after 5 seconds")
                }
            }
        }
    }
    
    // MARK: - View Components
    
    private var connectionStatusView: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.headline)
                    
                    Text(realtimeManager.connectionStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(10)
            
            // Avatar State Indicator
            HStack {
                Image(systemName: avatarStateIcon)
                    .font(.title2)
                    .foregroundColor(.blue)
                
                Text("Avatar: \(String(describing: realtimeManager.avatarState))")
                    .font(.subheadline)
                
                Spacer()
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(10)
        }
    }
    
    private var controlButtonsView: some View {
        Button(action: toggleConnection) {
            Label(
                realtimeManager.connectionState == .connected ? "Disconnect" : "Connect",
                systemImage: realtimeManager.connectionState == .connected ? "wifi.slash" : "wifi"
            )
            .frame(maxWidth: .infinity)
            .padding()
            .background(realtimeManager.connectionState == .connected ? Color.red : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .disabled(realtimeManager.connectionState == .connecting)
    }
    
    private var audioControlsView: some View {
        VStack(spacing: 12) {
            // Audio Level Meter
            if realtimeManager.connectionState == .connected {
                VStack(spacing: 8) {
                    Text("Audio Level")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 8)
                                .cornerRadius(4)
                            
                            // Level indicator
                            Rectangle()
                                .fill(LinearGradient(
                                    colors: [.green, .yellow, .red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: geometry.size.width * CGFloat(realtimeManager.audioLevel), height: 8)
                                .cornerRadius(4)
                                .animation(.easeInOut(duration: 0.1), value: realtimeManager.audioLevel)
                        }
                    }
                    .frame(height: 8)
                }
                .padding(.horizontal, 4)
            }
            
            // Status indicator
            HStack {
                Circle()
                    .fill(realtimeManager.isListening ? Color.green : Color.gray)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color.green.opacity(0.5), lineWidth: realtimeManager.isListening ? 2 : 0)
                            .scaleEffect(realtimeManager.isListening ? 1.5 : 1)
                            .opacity(realtimeManager.isListening ? 0 : 1)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: realtimeManager.isListening)
                    )
                
                Text(getStatusText())
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding()
            
            // Always show interrupt button, just disable when not speaking
            Button(action: {
                realtimeManager.interruptAI()
            }) {
                HStack {
                    Image(systemName: "hand.raised.fill")
                    Text("Interrupt")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(realtimeManager.isAISpeaking ? Color.orange : Color.gray)
                .cornerRadius(12)
            }
            .padding(.horizontal)
            .disabled(!realtimeManager.isAISpeaking)
            
            HStack(spacing: 12) {
                Spacer()
                
                Spacer()
                
                // Audio Status
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Audio Status")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if realtimeManager.isListening {
                        HStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text("Recording")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    } else if realtimeManager.isSpeaking {
                        HStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                            Text("Playing")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    } else if realtimeManager.isAudioReady {
                        HStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Ready")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    } else {
                        HStack {
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 8, height: 8)
                            Text("Setup Required")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
    
    private var textInputView: some View {
        // Text Input Test - Fallback option
        VStack(alignment: .leading, spacing: 8) {
            Text("Text Fallback (WebSocket Only)")
                .font(.headline)
            
            Text("Use this for testing without audio or as backup")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack {
                TextField("Type a test message...", text: $testMessage)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Send") {
                    sendTestMessage()
                }
                .disabled(testMessage.isEmpty || realtimeManager.connectionState != .connected)
            }
            
            // Quick test buttons
            HStack {
                Button("Quick Test 1") {
                    testMessage = "Hello, Plato"
                    sendTestMessage()
                }
                .buttonStyle(.borderedProminent)
                .disabled(realtimeManager.connectionState != .connected)
                
                Button("Quick Test 2") {
                    testMessage = "What is Stoicism?"
                    sendTestMessage()
                }
                .buttonStyle(.borderedProminent)
                .disabled(realtimeManager.connectionState != .connected)
                
                Spacer()
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var performanceView: some View {
        // Status and Metrics
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance & Debug")
                .font(.headline)
            
            HStack {
                VStack(alignment: .leading) {
                    Text("Response Latency")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(realtimeManager.lastLatencyMs > 0 ? "\(realtimeManager.lastLatencyMs)ms" : "—")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(realtimeManager.lastLatencyMs > 0 ? (realtimeManager.lastLatencyMs < 500 ? .green : .orange) : .primary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("Audio Level")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if realtimeManager.isListening {
                        Text("\(Int(realtimeManager.audioLevel * 100))%")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(realtimeManager.audioLevel > 0.1 ? .green : .secondary)
                    } else {
                        Text("—")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Connection Debug Info
            HStack {
                VStack(alignment: .leading) {
                    Text("Last Message")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(realtimeManager.lastReceivedMessage)
                        .font(.caption2)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                
                Spacer()
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)
            
            Text(realtimeManager.currentTranscript)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray5))
                .cornerRadius(8)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var assistantResponseView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🏛️ Assistant Response")
                .font(.headline)
            
            Text(realtimeManager.assistantResponse)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    private var helperTextView: some View {
        // Helper Text
        Group {
            if realtimeManager.connectionState == .connecting {
                VStack(alignment: .center, spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Connecting to OpenAI Realtime API...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.orange.opacity(0.05))
                .cornerRadius(10)
            } else if realtimeManager.connectionState == .connected && realtimeManager.assistantResponse.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    if realtimeManager.isAudioReady {
                        Text("🎤 Ready for Voice Conversation")
                            .font(.headline)
                            .foregroundColor(.green)
                        
                        Text("Tap the microphone button above to start speaking")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Text("Or use the Quick Test buttons for text messaging")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("🌐 Connected to Realtime API")
                            .font(.headline)
                            .foregroundColor(.green)
                        
                        Text("Audio setup will happen when you start listening")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                .background(Color.green.opacity(0.05))
                .cornerRadius(10)
            } else if realtimeManager.connectionState == .disconnected {
                VStack(alignment: .center, spacing: 8) {
                    Text("🔌 Tap Connect to test the WebSocket connection")
                        .font(.headline)
                        .foregroundColor(.blue)
                    
                    Text("This will verify OpenAI API key and network connectivity")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.blue.opacity(0.05))
                .cornerRadius(10)
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func getStatusText() -> String {
        if realtimeManager.isSpeaking {
            return "Plato is speaking..."
        } else if realtimeManager.isListening {
            return "Plato is listening..."
        } else if realtimeManager.connectionState == .connecting {
            return "Connecting..."
        } else if realtimeManager.connectionState == .disconnected {
            return "Disconnected"
        } else {
            return "Initializing..."
        }
    }
    
    // MARK: - Actions
    
    private func toggleConnection() {
        if realtimeManager.connectionState == .connected {
            realtimeManager.disconnect()
            logMessages.append("Disconnected from Realtime API")
        } else {
            realtimeManager.connect()
            logMessages.append("Connecting to Realtime API...")
        }
    }
    
    private func toggleListening() {
        print("🔘 toggleListening() button tapped")
        print("   realtimeManager.isListening: \(realtimeManager.isListening)")
        
        if realtimeManager.isListening {
            print("🔘 Calling stopListening()")
            realtimeManager.stopListening()
            logMessages.append("Stopped listening")
            startTime = nil
        } else {
            print("🔘 Calling startListening()")
            realtimeManager.startListening()
            logMessages.append("Started listening - say something!")
            startTime = Date()
        }
    }
    
    private func sendTestMessage() {
        guard !testMessage.isEmpty else { return }
        
        let messageToSend = testMessage
        realtimeManager.sendTextMessage(messageToSend)
        logMessages.append("Sent: \(messageToSend)")
        testMessage = ""
        
        // Track when we start sending to measure latency
        startTime = Date()
    }
    
    private func clearAll() {
        logMessages.removeAll()
        testMessage = ""
    }
}

// MARK: - Preview
#Preview {
    RealtimeTestView()
}