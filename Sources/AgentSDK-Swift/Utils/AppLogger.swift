//
//  File.swift
//  AgentSDK-Swift
//
//  Created by Mark Evans on 3/28/25.
//

// /Utils/AppLogger.swift

import Foundation
import os // Use Apple's unified logging system

/// A simple logger utility for the application.
/// Uses os.Logger for structured logging, falling back to print if needed.
struct AppLogger {

    // Create a logger instance. Replace subsystem with your app's bundle ID.
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.default.UtahNewsAgents" // Or your specific ID
    private static let logger = Logger(subsystem: subsystem, category: "App")

    /// Logs an informational message (default level).
    ///
    /// - Parameters:
    ///   - message: The message string to log.
    ///   - file: The file where the log originated (automatically captured).
    ///   - function: The function where the log originated (automatically captured).
    ///   - line: The line number where the log originated (automatically captured).
    static func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "✅ [\(fileName):\(line)] \(function) - \(message)"
        // Use os_log for better performance and filtering in Console.app
        logger.log("\(logMessage, privacy: .public)")
        // Fallback print for easier debugging in Xcode console during development
        #if DEBUG
        print(logMessage)
        #endif
    }

    /// Logs an error message.
    ///
    /// - Parameters:
    ///   - message: The primary error message.
    ///   - error: An optional underlying Error object.
    ///   - file: The file where the log originated (automatically captured).
    ///   - function: The function where the log originated (automatically captured).
    ///   - line: The line number where the log originated (automatically captured).
    static func error(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        var logMessage = "❌ [ERROR] [\(fileName):\(line)] \(function) - \(message)"
        if let error = error {
            logMessage += " | Error: \(error.localizedDescription)"
        }
        logger.error("\(logMessage, privacy: .public)")
        #if DEBUG
        print(logMessage)
        #endif
    }

    /// Logs a warning message.
    ///
    /// - Parameters:
    ///   - message: The warning message.
    ///   - file: The file where the log originated (automatically captured).
    ///   - function: The function where the log originated (automatically captured).
    ///   - line: The line number where the log originated (automatically captured).
    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "⚠️ [WARN] [\(fileName):\(line)] \(function) - \(message)"
        logger.warning("\(logMessage, privacy: .public)")
        #if DEBUG
        print(logMessage)
        #endif
    }
}

// Helper to make AgentName usable in logger if needed (optional)
// If AgentName is just String, this isn't needed. If it's a struct:
/*
extension AgentName: CustomStringConvertible {
    public var description: String {
        return self.value // Assuming it has a 'value' property
    }
}
*/

// Helper to make GuardrailError maybe conform to LocalizedError if it doesn't
// (Check actual GuardrailError definition in SDK)
/*
extension GuardrailError: LocalizedError {
    public var errorDescription: String? {
        // Provide description based on GuardrailError cases
        switch self {
        // ... cases ...
        default: return "Guardrail validation failed."
        }
    }
}
*/
