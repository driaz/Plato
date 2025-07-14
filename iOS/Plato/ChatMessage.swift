//
//  ChatMessage.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//

import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    let timestamp = Date()
}
