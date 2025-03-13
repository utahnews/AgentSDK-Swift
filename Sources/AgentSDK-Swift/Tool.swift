import Foundation

/// Represents a tool that can be used by an agent to perform actions
public struct Tool<Context> {
    /// The name of the tool
    public let name: String
    
    /// A description of what the tool does
    public let description: String
    
    /// The parameters required by the tool
    public let parameters: [Parameter]
    
    /// The function to execute when the tool is called
    private let execute: (ToolParameters, Context) async throws -> Any
    
    /// Creates a new tool
    /// - Parameters:
    ///   - name: The name of the tool
    ///   - description: A description of what the tool does
    ///   - parameters: The parameters required by the tool
    ///   - execute: The function to execute when the tool is called
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
    
    /// Executes the tool with the provided parameters and context
    /// - Parameters:
    ///   - parameters: The parameters for the tool execution
    ///   - context: The context for the tool execution
    /// - Returns: The result of the tool execution
    public func callAsFunction(_ parameters: ToolParameters, context: Context) async throws -> Any {
        try await execute(parameters, context)
    }
    
    /// Executes the tool with the provided parameters and context (internal use)
    /// - Parameters:
    ///   - parameters: The parameters for the tool execution
    ///   - context: The context for the tool execution
    /// - Returns: The result of the tool execution
    internal func execute(parameters: ToolParameters, context: Context) async throws -> Any {
        try await execute(parameters, context)
    }
    
    /// Represents a parameter for a tool
    public struct Parameter {
        /// The name of the parameter
        public let name: String
        
        /// A description of the parameter
        public let description: String
        
        /// The type of the parameter
        public let type: ParameterType
        
        /// Whether the parameter is required
        public let required: Bool
        
        /// Creates a new parameter
        /// - Parameters:
        ///   - name: The name of the parameter
        ///   - description: A description of the parameter
        ///   - type: The type of the parameter
        ///   - required: Whether the parameter is required
        public init(name: String, description: String, type: ParameterType, required: Bool = true) {
            self.name = name
            self.description = description
            self.type = type
            self.required = required
        }
    }
    
    /// Represents the type of a parameter
    public enum ParameterType {
        case string
        case number
        case boolean
        case array
        case object
        
        /// Returns the string representation of the type for OpenAI
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
}

/// Represents the parameters passed to a tool
public typealias ToolParameters = [String: Any]

/// Creates a function tool from a function
/// - Parameters:
///   - name: The name of the tool
///   - description: A description of what the tool does
///   - function: The function to execute when the tool is called
/// - Returns: A new function tool
public func functionTool<Context, Input: Decodable, Output>(
    name: String,
    description: String,
    function: @escaping (Input, Context) async throws -> Output
) -> Tool<Context> {
    Tool(name: name, description: description) { parameters, context in
        // Convert parameters dictionary to Input type
        let data = try JSONSerialization.data(withJSONObject: parameters)
        let input = try JSONDecoder().decode(Input.self, from: data)
        
        // Call the function with the decoded input and context
        return try await function(input, context)
    }
}