//
//  ChatMessage.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
// /Users/danielriaz/Projects/Plato/iOS/Plato/ChatMessage.swift
//  Unified role-based chat model
//

import Foundation

/// Speaker role recognized by OpenAI chat models.
enum ChatRole: String, Codable {
    case system
    case user
    case assistant
}

/// A single turn in the conversation timeline.
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    var text: String
    let timestamp: Date
    
    init(id: UUID = UUID(), role: ChatRole, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
    
    var isUser: Bool { role == .user }
}

/// Convenience helpers
extension ChatMessage {
    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }
    static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text)
    }
    static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, text: text)
    }
}
