import Foundation

/// Protocol for enforcing constraints on agent input and output
public protocol Guardrail {
    /// Validates input before it is sent to the agent
    /// - Parameter input: The input to validate
    /// - Returns: The validated input, possibly modified
    /// - Throws: GuardrailError if the input is invalid
    func validateInput(_ input: String) throws -> String
    
    /// Validates output from the agent before it is returned to the user
    /// - Parameter output: The output to validate
    /// - Returns: The validated output, possibly modified
    /// - Throws: GuardrailError if the output is invalid
    func validateOutput(_ output: String) throws -> String
}

/// Errors that can occur during guardrail validation
public enum GuardrailError: Error {
    /// The input was invalid
    case invalidInput(reason: String)
    
    /// The output was invalid
    case invalidOutput(reason: String)
}

/// A guardrail that enforces constraints on input length
public struct InputLengthGuardrail: Guardrail {
    /// The maximum allowed input length
    private let maxLength: Int
    
    /// Creates a new input length guardrail
    /// - Parameter maxLength: The maximum allowed input length
    public init(maxLength: Int) {
        self.maxLength = maxLength
    }
    
    /// Validates that the input length is within the allowed limit
    /// - Parameter input: The input to validate
    /// - Returns: The input if it is valid
    /// - Throws: GuardrailError if the input is too long
    public func validateInput(_ input: String) throws -> String {
        if input.count > maxLength {
            throw GuardrailError.invalidInput(reason: "Input is too long. Maximum length is \(maxLength) characters.")
        }
        return input
    }
    
    /// Pass-through for output validation
    /// - Parameter output: The output to validate
    /// - Returns: The output unchanged
    public func validateOutput(_ output: String) throws -> String {
        return output
    }
}

/// A guardrail that enforces constraints on output content using a regular expression
public struct RegexContentGuardrail: Guardrail {
    /// The regular expression to match against the output
    private let regex: NSRegularExpression
    
    /// Whether to block matches (true) or require matches (false)
    private let blockMatches: Bool
    
    /// Creates a new regex content guardrail
    /// - Parameters:
    ///   - pattern: The regex pattern to match against the output
    ///   - blockMatches: Whether to block matches (true) or require matches (false)
    /// - Throws: An error if the regex pattern is invalid
    public init(pattern: String, blockMatches: Bool = true) throws {
        self.regex = try NSRegularExpression(pattern: pattern, options: [])
        self.blockMatches = blockMatches
    }
    
    /// Pass-through for input validation
    /// - Parameter input: The input to validate
    /// - Returns: The input unchanged
    public func validateInput(_ input: String) throws -> String {
        return input
    }
    
    /// Validates that the output matches the regex constraints
    /// - Parameter output: The output to validate
    /// - Returns: The output if it is valid
    /// - Throws: GuardrailError if the output does not match the constraints
    public func validateOutput(_ output: String) throws -> String {
        let range = NSRange(location: 0, length: output.utf16.count)
        let matches = regex.matches(in: output, options: [], range: range)
        
        if blockMatches && !matches.isEmpty {
            throw GuardrailError.invalidOutput(reason: "Output contains blocked content.")
        } else if !blockMatches && matches.isEmpty {
            throw GuardrailError.invalidOutput(reason: "Output does not contain required content.")
        }
        
        return output
    }
}