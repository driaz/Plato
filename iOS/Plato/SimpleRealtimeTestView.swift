//
//  SimpleRealtimeTestView.swift
//  Plato
//
//  Ultra-minimal Realtime test to isolate crashes
//

import SwiftUI

struct SimpleRealtimeTestView: View {
    @State private var statusText = "Ready to test"
    
    var body: some View {
        VStack(spacing: 20) {
            Text("🎯 Realtime API Test")
                .font(.title)
                .fontWeight(.bold)
            
            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button("Test Basic Connection") {
                statusText = "Testing connection..."
                testBasicConnection()
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            
            Button("Create RealtimeManager") {
                statusText = "Creating manager..."
                testRealtimeManagerCreation()
            }
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(10)
            
            Spacer()
        }
        .padding()
        .navigationTitle("Simple Test")
    }
    
    private func testBasicConnection() {
        // Just test if we can create a basic URL
        if let _ = URL(string: "wss://api.openai.com/v1/realtime") {
            statusText = "✅ Basic URL creation works"
        } else {
            statusText = "❌ URL creation failed"
        }
    }
    
    private func testRealtimeManagerCreation() {
        // Test if RealtimeManager can be created
        do {
            let _ = RealtimeManager()
            statusText = "✅ RealtimeManager created successfully"
        } catch {
            statusText = "❌ RealtimeManager creation failed: \(error)"
        }
    }
}

#Preview {
    SimpleRealtimeTestView()
}