import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAPIRuntime

/// Implementation of ModelInterface for OpenAI models
public final class OpenAIModel: ModelInterface {
    /// The API key for OpenAI
    private let apiKey: String
    
    /// The API base URL
    private let apiBaseURL: URL
    
    /// The URL session used for network requests
    private let urlSession: URLSession
    
    /// Creates a new OpenAI model
    /// - Parameters:
    ///   - apiKey: The API key for OpenAI
    ///   - apiBaseURL: The API base URL (defaults to OpenAI's API)
    ///   - urlSession: Optional custom URL session
    public init(
        apiKey: String,
        apiBaseURL: URL = URL(string: "https://api.openai.com/v1")!,
        urlSession: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession ?? URLSession.shared
    }
    
    /// Gets a response from the model
    /// - Parameters:
    ///   - messages: The messages to send to the model
    ///   - settings: The settings to use for the model call
    /// - Returns: The model response
    // --- MODIFIED: Added agentTools parameter ---
    public func getResponse(
        messages: [Message],
        settings: ModelSettings,
        agentTools: [Tool<Any>] // Added to match protocol
    ) async throws -> ModelResponse {
        let requestBody = try createRequestBody(messages: messages, settings: settings)
        
        let endpoint = "\(apiBaseURL)/chat/completions"
        
        // Create request
        var request = createURLRequest(url: endpoint)
        
        // Add request body
        let bodyData = try JSONEncoder().encode(requestBody)
        request.httpBody = bodyData
        
        // Send request
        let (data, response) = try await urlSession.data(for: request, delegate: nil)
        
        // Check response status
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OpenAIModelError.requestFailed(statusCode: statusCode, message: errorString)
        }
        
        // Parse response
        let openAIResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        
        return try convertResponse(openAIResponse)
    }
    
    /// Gets a streamed response from the model
    /// - Parameters:
    ///   - messages: The messages to send to the model
    ///   - settings: The settings to use for the model call
    ///   - callback: The callback to call for each streamed chunk
    // --- MODIFIED: Added agentTools parameter ---
    public func getStreamedResponse(
        messages: [Message],
        settings: ModelSettings,
        agentTools: [Tool<Any>], // Added to match protocol
        callback: @escaping (ModelStreamEvent) async -> Void
    ) async throws -> ModelResponse {
        let streamSettings = settings
        // Pass agentTools down
        var requestBody = try createRequestBody(messages: messages, settings: streamSettings, agentTools: agentTools)
        requestBody.stream = true

        let endpoint = "\(apiBaseURL)/chat/completions"
        var request = createURLRequest(url: endpoint)
        let bodyData = try JSONEncoder().encode(requestBody)
        request.httpBody = bodyData
        
        // Create URLSession task
        let (data, response) = try await urlSession.data(for: request)
        
        // Check response status
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OpenAIModelError.requestFailed(statusCode: statusCode, message: errorString)
        }
        
        // Process streamed response
        var contentBuffer = ""
        var toolCalls: [ModelResponse.ToolCall] = []
        
        // Convert data to string and process line by line
        if let responseStr = String(data: data, encoding: .utf8) {
            let lines = responseStr.split(separator: "\n")
            
            for line in lines {
                if line.hasPrefix("data: ") {
                    let dataContent = line.dropFirst(6)
                    
                    // Check for the "[DONE]" message
                    if dataContent == "[DONE]" {
                        await callback(.end)
                        continue
                    }
                    
                    // Parse the JSON chunk
                    do {
                        let chunkData = Data(dataContent.utf8)
                        let chunkResponse = try JSONDecoder().decode(ChatCompletionChunk.self, from: chunkData)
                        
                        if let choice = chunkResponse.choices.first {
                            if let content = choice.delta.content, !content.isEmpty {
                                contentBuffer += content
                                await callback(.content(content))
                            }
                            
                            if let toolCall = choice.delta.toolCalls?.first {
                                // Handle tool call delta
                                if let existingToolCall = toolCalls.first(where: { $0.id == toolCall.id }) {
                                    // Update existing tool call
                                    if let index = toolCalls.firstIndex(where: { $0.id == toolCall.id }) {
                                        var params = existingToolCall.parameters
                                        
                                        if let function = toolCall.function {
                                            if let name = function.name {
                                                toolCalls[index] = ModelResponse.ToolCall(
                                                    id: existingToolCall.id,
                                                    name: name,
                                                    parameters: params
                                                )
                                            }
                                            
                                            if let arguments = function.arguments {
                                                do {
                                                    if let jsonData = arguments.data(using: .utf8),
                                                       let jsonParams = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                                        // Merge with existing parameters
                                                        for (key, value) in jsonParams {
                                                            params[key] = value
                                                        }
                                                        
                                                        toolCalls[index] = ModelResponse.ToolCall(
                                                            id: existingToolCall.id,
                                                            name: existingToolCall.name,
                                                            parameters: params
                                                        )
                                                    }
                                                } catch {
                                                    // Ignore parsing errors for partial JSON
                                                }
                                            }
                                        }
                                    }
                                } else if let id = toolCall.id, let function = toolCall.function, let name = function.name {
                                    // Create new tool call
                                    var params: [String: Any] = [:]
                                    
                                    if let arguments = function.arguments {
                                        do {
                                            if let jsonData = arguments.data(using: .utf8),
                                               let jsonParams = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                                params = jsonParams
                                            }
                                        } catch {
                                            // Ignore parsing errors for partial JSON
                                        }
                                    }
                                    
                                    let newToolCall = ModelResponse.ToolCall(id: id, name: name, parameters: params)
                                    toolCalls.append(newToolCall)
                                    await callback(.toolCall(newToolCall))
                                }
                            }
                        }
                    } catch {
                        // Ignore partial JSON errors
                    }
                }
            }
        }
        
        // Create final response
        return ModelResponse(
            content: contentBuffer,
            toolCalls: toolCalls
        )
    }
    
    /// Creates a URLRequest configured with the appropriate headers
    /// - Parameter url: The URL string for the request
    /// - Returns: A configured URLRequest
    private func createURLRequest(url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600 // 10 minute timeout
        return request
    }
    
    /// Creates a request body for the OpenAI API
    /// - Parameters:
    ///   - messages: The messages to send to the model
    ///   - settings: The settings to use for the model call
    /// - Returns: The request body
    // --- MODIFIED: Added agentTools parameter ---
    private func createRequestBody(
        messages: [Message],
        settings: ModelSettings,
        agentTools: [Tool<Any>] = [] // Added parameter with default
    ) throws -> ChatCompletionRequest {        // Convert messages to OpenAI format
        let openAIMessages = messages.map { message -> ChatMessage in
            let role = message.role.rawValue
            
            switch message.content {
            case .text(let text):
                return ChatMessage(role: role, content: text)
                
            case .toolResults(let toolResult):
                return ChatMessage(
                    role: role,
                    toolCallId: toolResult.toolCallId,
                    content: toolResult.result
                )
            }
        }
        
        // Convert tools to OpenAI format
//        let tools: [OpenAITool]? = nil // Implement tool conversion if needed
        
        // --- MODIFIED SECTION START ---
        // Convert tools to OpenAI format
        let openAITools: [OpenAITool]? = agentTools.isEmpty ? nil : try agentTools.map { swiftTool in
            // Call the helper to generate the JSON Schema dictionary
            let jsonSchemaParameters = try convertParametersToJsonSchema(swiftTool.parameters)

            // Create the FunctionDefinition using the generated schema
            let functionDef = FunctionDefinition(
                name: swiftTool.name,
                description: swiftTool.description,
                parameters: jsonSchemaParameters // Assign the schema dictionary
            )
            // Create the OpenAITool wrapper
            return OpenAITool(type: "function", function: functionDef)
        }
        // Assign the potentially populated array
        let tools = openAITools
        // --- MODIFIED SECTION END ---
        
        // Create request body
        var request = ChatCompletionRequest(
            model: settings.modelName,
            messages: openAIMessages,
            tools: tools
        )
        
        // Add optional parameters from settings
        if let temperature = settings.temperature {
            request.temperature = temperature
        }
        
        if let topP = settings.topP {
            request.top_p = topP
        }
        
        if let maxTokens = settings.maxTokens {
            request.max_tokens = maxTokens
        }
        
        if let responseFormat = settings.responseFormat {
            request.response_format = ["type": responseFormat.jsonValue]
        }
        
        if let seed = settings.seed {
            request.seed = seed
        }
        
        // Add any additional parameters
        for (_, _) in settings.additionalParameters {
            // This is a simplification - in a real implementation, we would need to properly handle adding these params
        }
        
        return request
    }
    
    /// Converts an OpenAI response to a ModelResponse
    /// - Parameter response: The OpenAI response
    /// - Returns: The converted ModelResponse
    private func convertResponse(_ response: ChatCompletionResponse) throws -> ModelResponse {
        guard let choice = response.choices.first else {
            throw OpenAIModelError.emptyResponse
        }
        
        // Get content
        let content = choice.message.content ?? ""
        
        // Get tool calls if any
        var toolCalls: [ModelResponse.ToolCall] = []
        
        if let openAIToolCalls = choice.message.tool_calls {
            for toolCall in openAIToolCalls {
                do {
                    let arguments = toolCall.function.arguments
                    let argsData = arguments.data(using: .utf8) ?? Data()
                    let params = try JSONSerialization.jsonObject(with: argsData) as? [String: Any] ?? [:]
                    
                    toolCalls.append(ModelResponse.ToolCall(
                        id: toolCall.id,
                        name: toolCall.function.name,
                        parameters: params
                    ))
                } catch {
                    throw OpenAIModelError.invalidToolCallArguments(error)
                }
            }
        }
        
        // Get usage statistics
        var usage: ModelResponse.Usage? = nil
        if let responseUsage = response.usage {
            usage = ModelResponse.Usage(
                promptTokens: responseUsage.prompt_tokens,
                completionTokens: responseUsage.completion_tokens,
                totalTokens: responseUsage.total_tokens
            )
        }
        
        return ModelResponse(
            content: content,
            toolCalls: toolCalls,
            usage: usage
        )
    }
    
    /// Errors that can occur when using the OpenAI model
    public enum OpenAIModelError: Error {
        case requestFailed(statusCode: Int, message: String)
        case emptyResponse
        case invalidToolCallArguments(Error)
    }
    
    // OpenAI API Types
    
    /// Request for the OpenAI chat completions API
    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let tools: [OpenAITool]?
        var temperature: Double?
        var top_p: Double?
        var max_tokens: Int?
        var response_format: [String: String]?
        var seed: Int?
        var stream: Bool = false
    }
    
    /// Tool for the OpenAI chat completions API
    private struct OpenAITool: Encodable {
        let type: String
        let function: FunctionDefinition
    }
    
    /// Message for the OpenAI chat completions API
    private struct ChatMessage: Encodable {
        let role: String
        var content: String?
        var tool_call_id: String?
        
        init(role: String, content: String) {
            self.role = role
            self.content = content
        }
        
        init(role: String, toolCallId: String, content: String) {
            self.role = role
            self.tool_call_id = toolCallId
            self.content = content
        }
    }
    
    /// Function definition for the OpenAI chat completions API
    // --- MODIFIED: FunctionDefinition with CORRECT Encodable conformance ---
    private struct FunctionDefinition: Encodable {
        let name: String
        let description: String
        let parameters: [String: Any] // The JSON Schema dictionary

        // Provide custom encode(to:) to handle [String: Any]
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)

            // Manually encode the parameters dictionary
            // We need to wrap it in a structure that JSONEncoder understands
            // or encode it element by element. Let's use a wrapper struct.
            try container.encode(JsonSchemaWrapper(parameters), forKey: .parameters)
        }
         // Keep CodingKeys if manually encoding specific keys
         enum CodingKeys: String, CodingKey {
             case name, description, parameters
         }
    }
    // --- End Modification ---


    // --- Helper for encoding [String: Any] JSON Schema ---
    private struct JsonSchemaWrapper: Encodable {
        let schema: [String: Any]

        init(_ schema: [String: Any]) {
            self.schema = schema
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(AnyCodable(schema)) // Use AnyCodable or similar technique
        }
    }
    // --- We need an AnyCodable implementation or similar ---
    // Add this struct (or use a library providing it)
    private struct AnyCodable: Encodable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch value {
            case let string as String: try container.encode(string)
            case let int as Int: try container.encode(int)
            case let double as Double: try container.encode(double)
            case let bool as Bool: try container.encode(bool)
            case let array as [Any]: try container.encode(array.map { AnyCodable($0) }) // Recursive call for array elements
            case let dictionary as [String: Any]: try container.encode(dictionary.mapValues { AnyCodable($0) }) // Recursive call for dictionary values
            case is NSNull: try container.encodeNil()
            default:
                let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value \(value) is not JSON encodable")
                throw EncodingError.invalidValue(value, context)
            }
        }
    }
    // --- End AnyCodable ---



    
    /// Response from the OpenAI chat completions API
    private struct ChatCompletionResponse: Decodable {
        let id: String
        let object: String
        let created: Int
        let model: String
        let choices: [Choice]
        let usage: Usage?
        
        struct Choice: Decodable {
            let index: Int
            let message: Message
            let finish_reason: String
        }
        
        struct Message: Decodable {
            let role: String
            let content: String?
            let tool_calls: [ToolCall]?
        }
        
        struct ToolCall: Decodable {
            let id: String
            let type: String
            let function: Function
        }
        
        struct Function: Decodable {
            let name: String
            let arguments: String
        }
        
        struct Usage: Decodable {
            let prompt_tokens: Int
            let completion_tokens: Int
            let total_tokens: Int
        }
    }
    
    /// Chunk response from the OpenAI chat completions API when streaming
    private struct ChatCompletionChunk: Decodable {
        let id: String
        let object: String
        let created: Int
        let model: String
        let choices: [Choice]
        
        struct Choice: Decodable {
            let index: Int
            let delta: Delta
            let finish_reason: String?
        }
        
        struct Delta: Decodable {
            let role: String?
            let content: String?
            let toolCalls: [ToolCall]?
            
            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }
        
        struct ToolCall: Decodable {
            let id: String?
            let type: String?
            let function: Function?
            
            enum CodingKeys: String, CodingKey {
                case id, type, function
            }
        }
        
        struct Function: Decodable {
            let name: String?
            let arguments: String?
            
            enum CodingKeys: String, CodingKey {
                case name, arguments
            }
        }
    }
    
    
    /// Converts the SDK's Tool.Parameter array into a JSON Schema dictionary.
    private func convertParametersToJsonSchema(_ params: [Tool<Any>.Parameter]) throws -> [String: Any] { // Use Any for Context placeholder if needed generically
        // Basic JSON Schema structure
        var schema: [String: Any] = [
            "type": "object", // Root is always object for function params
            "properties": [String: Any](),
            "required": [String]()
        ]
        var properties = [String: Any]()
        var requiredParams = [String]()

        for param in params {
            let paramSchema: [String: Any] = [
                "type": param.type.jsonType, // Use the existing .jsonType mapping
                "description": param.description
            ]
            // TODO: Add handling for other JSON Schema properties if needed
            // (e.g., 'enum' based on ParameterType details, 'items' for arrays)
            properties[param.name] = paramSchema
            if param.required {
                requiredParams.append(param.name)
            }
        }

        if !properties.isEmpty {
            schema["properties"] = properties
        }
        if !requiredParams.isEmpty {
            schema["required"] = requiredParams
        } else {
            // OpenAPI requires 'required' to be present, even if empty, if properties exist
            if !properties.isEmpty {
                 schema["required"] = []
            } else {
                 // If no properties, remove 'required' entirely
                 schema.removeValue(forKey: "required")
            }
        }
        // If no properties, OpenAI expects an empty object for parameters, but
        // our schema generation should handle this via the properties check.
        // However, if the function truly takes NO arguments, the API might expect {} or omitting parameters entirely.
        // Let's assume for now functions will have parameters if tools are defined with them.

        return schema
    }
}

/// Extension to register OpenAI models with the model provider
public extension ModelProvider {
    /// Registers OpenAI models with the model provider
    /// - Parameter apiKey: The API key for OpenAI
    func registerOpenAIModels(apiKey: String) {
        // Register default OpenAI models
        register(modelName: "gpt-4-turbo") {
            OpenAIModel(apiKey: apiKey)
        }
        
        register(modelName: "gpt-4") {
            OpenAIModel(apiKey: apiKey)
        }
        
        register(modelName: "gpt-3.5-turbo") {
            OpenAIModel(apiKey: apiKey)
        }
    }
}
