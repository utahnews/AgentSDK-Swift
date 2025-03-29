// /Sources/AgentSDK-Swift/Tool.swift

import Foundation

// --- Parameter Type Definition (Moved to Top Level) ---
/// Represents the basic JSON Schema types supported for tool parameters.
public enum ParameterType {
    case string
    case number
    case boolean
    case array
    case object

    public var jsonType: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// --- Error Type Definition (Moved to Top Level) ---
/// Error thrown when context type mismatch occurs during tool type erasure.
public enum ToolErasingError: Error, LocalizedError {
    case contextMismatch(String)
    public var errorDescription: String? { if case .contextMismatch(let s) = self { return s }; return nil }
}

/// Represents a tool that can be used by an agent to perform actions
public struct Tool<Context> {
    /// The name of the tool
    public let name: String

    /// A description of what the tool does
    public let description: String

    /// The parameters required by the tool, defining its expected input schema.
    public let parameters: [Parameter]

    /// The function to execute when the tool is called by the AgentRunner.
    /// Receives parameters from LLM and the run context. Returns Any result.
    // fileprivate to restrict direct access from outside, use callAsFunction or eraseToAnyContext
    fileprivate let execute: (ToolParameters, Context) async throws -> Any

    /// Creates a new tool
    public init(
        name: String,
        description: String,
        parameters: [Parameter] = [],
        execute: @escaping (ToolParameters, Context) async throws -> Any
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.execute = execute
    }

    /// Executes the tool with the provided parameters and context. (Public interface)
    public func callAsFunction(_ parameters: ToolParameters, context: Context) async throws -> Any {
        // Directly call the internal execute closure
        try await execute(parameters, context)
    }

    /// Creates a type-erased version of this tool that accepts Any context.
    public func eraseToAnyContext() -> Tool<Any> {
        let originalExecutor: (ToolParameters, Context) async throws -> Any = self.execute

        return Tool<Any>(
            name: self.name,    
            description: self.description,
            parameters: self.parameters.map { param in 
                Tool<Any>.Parameter(
                    name: param.name,
                    description: param.description,
                    type: param.type,
                    required: param.required
                )
            },
            execute: { params, anyContext in 
                guard let specificContext = anyContext as? Context else {
                    let errorDesc = "Context type mismatch during tool execution wrapper for tool '\\(self.name)'. Expected \\(Context.self), got \\(type(of: anyContext))."
                    // Throw the top-level error
                    throw ToolErasingError.contextMismatch(errorDesc)
                }
                return try await originalExecutor(params, specificContext)
            }
        )
    }

    // --- Nested Types for Parameters ---
    /// Represents a parameter for a tool, used for generating the JSON Schema.
    public struct Parameter {
        public let name: String
        public let description: String
        // Use the top-level ParameterType
        public let type: ParameterType
        public let required: Bool
        // Use the top-level ParameterType in the initializer
        public init(name: String, description: String, type: ParameterType, required: Bool = true) {
            self.name = name
            self.description = description
            self.type = type
            self.required = required
        }
    }

    // --- ParameterType enum moved outside the struct ---

} // End Tool Struct

public typealias ToolParameters = [String: Any]


// --- Optional: functionTool Helper ---
/// Creates a function tool from a function that takes a single Decodable input struct.
public func functionTool<Context, Input: Decodable, Output>(
    name: String,
    description: String,
    // Use the nested Parameter struct, which now references the top-level ParameterType
    parameters: [Tool<Context>.Parameter],
    function: @escaping (Input, Context) async throws -> Output
) -> Tool<Context> {
    // Initialize Tool<Context> using its init, which references the nested Parameter struct
    Tool(name: name, description: description, parameters: parameters) { paramsDict, context in
        do {
            let data = try JSONSerialization.data(withJSONObject: paramsDict)
            let input = try JSONDecoder().decode(Input.self, from: data)
            let output: Output = try await function(input, context)
            return output as Any // Cast result to Any
        } catch let decodingError as DecodingError {
            // Provide more context on decoding failure
            throw NSError(domain: "FunctionToolError", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode parameters into expected type \\(Input.self) for tool '\\(name)'.",
                "DecodingErrorDetails": String(describing: decodingError),
                "RawParameters": paramsDict
            ])
        } catch {
            // Rethrow other errors from the function itself
            throw error
        }
    }
}
