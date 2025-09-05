//
//  PlatoApp.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
// /Users/danielriaz/Projects/Plato/iOS/Plato/PlatoApp.swift

import SwiftUI

@main
struct PlatoApp: App {
    
    init() {
        print("🛑 PlatoApp init - ALL INITIALIZATION DISABLED for Realtime testing")
        
        // Original init code commented out to prevent crashes
        /*
        // Configure logging
        #if DEBUG
        Logger.shared.setMinimumLevel(.debug)
        #else
        Logger.shared.setMinimumLevel(.warning)
        #endif
        
        // Configure audio session once at launch
        AudioSessionManager.shared.configureForDuplex()  // ← This was causing crashes!
        */
    }
    
    var body: some Scene {
        WindowGroup {
            NavigationView {
                VStack(spacing: 20) {
                    Text("🛑 CRASH DEBUG MODE")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                    
                    Text("Testing incremental complexity")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    NavigationLink("Test Simple Realtime", destination: SimpleRealtimeTestView())
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    
                    NavigationLink("Test Full ContentView", destination: ContentView())
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    
                    Spacer()
                }
                .padding()
                .navigationTitle("Debug Tests")
            }
        }
    }
}
