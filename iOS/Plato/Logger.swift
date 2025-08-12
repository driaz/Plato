//
//  Logger.swift
//  Plato
//
//  Central logging system - V1 (Pragmatic Power Edition)
//  Includes state tracking to help diagnose state management issues
//

import Foundation
import os.log

// MARK: - Log Categories
enum LogCategory: String {
    case app = "App"
    case audio = "Audio"
    case speech = "Speech"
    case tts = "TTS"
    case network = "Network"
    case flow = "Flow"
    case state = "State"     // For state transitions
    case echo = "Echo"       // For echo detection
    case performance = "Perf"
    case llm = "LLM"
    
    var icon: String {
        switch self {
        case .app: return "📱"
        case .audio: return "🔊"
        case .speech: return "🎤"
        case .tts: return "🎭"
        case .network: return "🌐"
        case .flow: return "🔄"
        case .state: return "🎯"
        case .echo: return "🛡️"
        case .performance: return "⏱️"
        case .llm: return "🤖"
        }
    }
}

// MARK: - Log Level
enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var prefix: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
}

// MARK: - State Tracking
struct AppStateSnapshot {
    let isRecording: Bool
    let isSpeaking: Bool
    let isPaused: Bool
    let isAlwaysListening: Bool
    let isLoading: Bool
    let echoGuardActive: Bool
    let timestamp = Date()
    
    var description: String {
        var states: [String] = []
        if isRecording { states.append("recording") }
        if isSpeaking { states.append("speaking") }
        if isPaused { states.append("paused") }
        if isAlwaysListening { states.append("always-listening") }
        if isLoading { states.append("loading") }
        if echoGuardActive { states.append("echo-guard") }
        return states.isEmpty ? "idle" : states.joined(separator: ", ")
    }
}

// MARK: - Logger
final class Logger {
    static let shared = Logger()
    
    // Configuration
    private var minimumLevel: LogLevel = .debug
    private let dateFormatter: DateFormatter
    
    // Change log ouput from debug to production
    var useOSLog: Bool = false  // Set to true for production

    
    // State tracking
    private var lastStateSnapshot: AppStateSnapshot?
    private var flowIdStack: [UUID] = []
    
    // Performance tracking
    private var performanceTimers: [String: Date] = [:]
    
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }
    
    // MARK: - Configuration
    
    func setMinimumLevel(_ level: LogLevel) {
        minimumLevel = level
    }
    
    // MARK: - Core Logging
    
    func log(_ message: String,
             category: LogCategory = .app,
             level: LogLevel = .info,
             file: String = #file,
             line: Int = #line) {
        
        guard level >= minimumLevel else { return }
        
        let timestamp = dateFormatter.string(from: Date())
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        
        // Format: 🎤 [Speech] ℹ️ Message (File:Line)
        let logMessage = "\(category.icon) [\(category.rawValue)] \(level.prefix) \(message)"
        let detailMessage = "\(timestamp) \(logMessage) (\(fileName):\(line))"
        
        // Use the flag to determine output method
        if useOSLog {
            // Production: Use os_log (visible in Console.app)
            let osLog = OSLog(subsystem: "com.plato.app", category: category.rawValue)
            os_log("%{public}@", log: osLog, type: osLogType(for: level), logMessage)
        } else {
            // Development: Use print (visible in Xcode console)
            print(logMessage)
        }
        
        // Note: We removed the duplicate output here!
    }
    
    // MARK: - Convenience Methods
    
    func debug(_ message: String, category: LogCategory = .app, file: String = #file, line: Int = #line) {
        log(message, category: category, level: .debug, file: file, line: line)
    }
    
    func info(_ message: String, category: LogCategory = .app, file: String = #file, line: Int = #line) {
        log(message, category: category, level: .info, file: file, line: line)
    }
    
    func warning(_ message: String, category: LogCategory = .app, file: String = #file, line: Int = #line) {
        log(message, category: category, level: .warning, file: file, line: line)
    }
    
    func error(_ message: String, category: LogCategory = .app, file: String = #file, line: Int = #line) {
        log(message, category: category, level: .error, file: file, line: line)
    }
    
    // MARK: - State Tracking
    
    func logState(_ current: AppStateSnapshot, trigger: String? = nil) {
        var message = "State: \(current.description)"
        
        // Compare with last state to show what changed
        if let last = lastStateSnapshot {
            var changes: [String] = []
            if last.isRecording != current.isRecording {
                changes.append("recording: \(last.isRecording) → \(current.isRecording)")
            }
            if last.isSpeaking != current.isSpeaking {
                changes.append("speaking: \(last.isSpeaking) → \(current.isSpeaking)")
            }
            if last.isPaused != current.isPaused {
                changes.append("paused: \(last.isPaused) → \(current.isPaused)")
            }
            
            if !changes.isEmpty {
                message = "State changed: \(changes.joined(separator: ", "))"
            }
        }
        
        if let trigger = trigger {
            message += " (trigger: \(trigger))"
        }
        
        log(message, category: .state, level: .debug)
        lastStateSnapshot = current
    }
    
    // MARK: - Flow Tracking
    
    @discardableResult
    func startFlow(_ name: String) -> UUID {
        let flowId = UUID()
        flowIdStack.append(flowId)
        log("Flow started: \(name) [\(flowId.uuidString.prefix(8))]", category: .flow)
        return flowId
    }
    
    func endFlow(_ flowId: UUID? = nil, name: String) {
        let id = flowId ?? flowIdStack.last
        if let id = id {
            flowIdStack.removeAll { $0 == id }
            log("Flow ended: \(name) [\(id.uuidString.prefix(8))]", category: .flow)
        }
    }
    
    // MARK: - Performance Tracking
    
    func startTimer(_ label: String) {
        performanceTimers[label] = Date()
        debug("Timer started: \(label)", category: .performance)
    }
    
    func endTimer(_ label: String) {
        guard let startTime = performanceTimers[label] else {
            warning("No timer found for: \(label)", category: .performance)
            return
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        performanceTimers.removeValue(forKey: label)
        
        let message = String(format: "%@ took %.3f seconds", label, elapsed)
        log(message, category: .performance, level: elapsed > 1.0 ? .warning : .info)
    }
    
    // MARK: - Specialized Logging
    
    func echoDetected(_ transcript: String, reason: String) {
        log("Dropping transcript: '\(transcript)' - \(reason)", category: .echo)
    }
    
    func networkRequest(_ url: URL, method: String = "POST") {
        log("\(method) \(url.absoluteString)", category: .network)
    }
    
    func networkResponse(_ url: URL, statusCode: Int, error: Error? = nil) {
        let level: LogLevel = error != nil ? .error : (statusCode >= 400 ? .warning : .info)
        let message = "Response \(statusCode) from \(url.host ?? "unknown")"
        log(message, category: .network, level: level)
        
        if let error = error {
            log("Error: \(error.localizedDescription)", category: .network, level: .error)
        }
    }
    
    // MARK: - Private Helpers
    
    private func osLogType(for level: LogLevel) -> OSLogType {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

// MARK: - Global Convenience Functions

func log(_ message: String, category: LogCategory = .app, level: LogLevel = .info) {
    Logger.shared.log(message, category: category, level: level)
}

func logDebug(_ message: String, category: LogCategory = .app) {
    Logger.shared.debug(message, category: category)
}

func logInfo(_ message: String, category: LogCategory = .app) {
    Logger.shared.info(message, category: category)
}

func logWarning(_ message: String, category: LogCategory = .app) {
    Logger.shared.warning(message, category: category)
}

func logError(_ message: String, category: LogCategory = .app) {
    Logger.shared.error(message, category: category)
}

func logState(_ snapshot: AppStateSnapshot, trigger: String? = nil) {
    Logger.shared.logState(snapshot, trigger: trigger)
}

// MARK: - Usage Examples
/*
// Basic logging
log("App launched")
logDebug("Processing audio chunk", category: .audio)
logError("Failed to connect", category: .network)

// State tracking
let state = AppStateSnapshot(
    isRecording: true,
    isSpeaking: false,
    isPaused: false,
    isAlwaysListening: true,
    isLoading: false,
    echoGuardActive: false
)
logState(state, trigger: "startRecording")

// Flow tracking
let flowId = Logger.shared.startFlow("Question-Answer")
// ... do work ...
Logger.shared.endFlow(flowId, name: "Question-Answer")

// Performance tracking
Logger.shared.startTimer("API Call")
// ... make API call ...
Logger.shared.endTimer("API Call")

// Specialized logging
Logger.shared.echoDetected("Yes, life is change", reason: "Content overlap > 70%")
Logger.shared.networkRequest(url, method: "POST")
Logger.shared.networkResponse(url, statusCode: 429, error: nil)
*/
