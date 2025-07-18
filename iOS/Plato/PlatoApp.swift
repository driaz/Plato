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
           // Configure audio session once at launch
           AudioSessionManager.shared.configureForDuplex()
       }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
