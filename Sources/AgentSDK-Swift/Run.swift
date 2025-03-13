import Foundation

/// Represents a single run of an agent
public final class Run<Context> {
    /// The agent being run
    public let agent: Agent<Context>
    
    /// The input for the run
    public let input: String
    
    /// The context for the run
    public let context: Context
    
    /// The history of messages for the run
    public private(set) var messages: [Message] = []
    
    /// The current state of the run
    public private(set) var state: State = .notStarted
    
    /// The model used for the run
    private let model: ModelInterface
    
    /// Creates a new run
    /// - Parameters:
    ///   - agent: The agent to run
    ///   - input: The input for the run
    ///   - context: The context for the run
    ///   - model: The model to use for the run
    public init(agent: Agent<Context>, input: String, context: Context, model: ModelInterface) {
        self.agent = agent
        self.input = input
        self.context = context
        self.model = model
        
        // Initialize with system message
        self.messages.append(.system(agent.instructions))
    }
    
    /// Executes the run
    /// - Returns: The result of the run
    /// - Throws: RunError if there is a problem during execution
    public func execute() async throws -> Result {
        guard state == .notStarted else {
            throw RunError.invalidState("Run has already been started")
        }
        
        state = .running
        
        // Validate input with guardrails
        var validatedInput = input
        for guardrail in agent.guardrails {
            do {
                validatedInput = try guardrail.validateInput(validatedInput)
            } catch let error as GuardrailError {
                state = .failed
                throw RunError.guardrailError(error)
            }
        }
        
        // Check for handoffs
        for handoff in agent.handoffs {
            if handoff.filter.shouldHandoff(input: validatedInput, context: context) {
                // Create and execute a new run with the handoff agent
                let handoffRun = Run(
                    agent: handoff.agent,
                    input: validatedInput,
                    context: context,
                    model: model
                )
                
                return try await handoffRun.execute()
            }
        }
        
        // Add validated user input to messages
        messages.append(.user(validatedInput))
        
        // Run the agent
        var finalOutput: String = ""
        
        do {
            let response = try await model.getResponse(
                messages: messages,
                settings: agent.modelSettings
            )
            
            // Process tool calls if any
            if !response.toolCalls.isEmpty {
                let toolResults = try await processToolCalls(response.toolCalls)
                
                // Add assistant message with tool calls
                messages.append(.assistant(response.content))
                
                // Add tool results to messages
                for result in toolResults {
                    messages.append(Message(
                        role: .tool,
                        content: .toolResults(result)
                    ))
                }
                
                // Get final response after tool calls
                let finalResponse = try await model.getResponse(
                    messages: messages,
                    settings: agent.modelSettings
                )
                
                finalOutput = finalResponse.content
            } else {
                finalOutput = response.content
            }
            
            // Validate output with guardrails
            for guardrail in agent.guardrails {
                do {
                    finalOutput = try guardrail.validateOutput(finalOutput)
                } catch let error as GuardrailError {
                    state = .failed
                    throw RunError.guardrailError(error)
                }
            }
            
            // Add final assistant message
            messages.append(.assistant(finalOutput))
            
            state = .completed
            return Result(
                finalOutput: finalOutput,
                messages: messages
            )
        } catch {
            state = .failed
            throw RunError.executionError(error)
        }
    }
    
    /// Processes tool calls from the model
    /// - Parameter toolCalls: The tool calls to process
    /// - Returns: The results of the tool calls
    /// - Throws: RunError if there is a problem processing the tool calls
    private func processToolCalls(_ toolCalls: [ModelResponse.ToolCall]) async throws -> [MessageContent.ToolResult] {
        var results: [MessageContent.ToolResult] = []
        
        // Create a map of tool names to tools for easy lookup
        let toolMap = Dictionary(uniqueKeysWithValues: agent.tools.map { ($0.name, $0) })
        
        for toolCall in toolCalls {
            guard let tool = toolMap[toolCall.name] else {
                throw RunError.toolNotFound("Tool \(toolCall.name) not found")
            }
            
            do {
                let result = try await tool(toolCall.parameters, context: context)
                let resultString: String
                
                if let stringResult = result as? String {
                    resultString = stringResult
                } else {
                    // Convert result to JSON string
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
                    resultString = String(data: data, encoding: .utf8) ?? "Invalid result"
                }
                
                results.append(MessageContent.ToolResult(
                    toolCallId: toolCall.id,
                    result: resultString
                ))
            } catch {
                throw RunError.toolExecutionError(toolName: toolCall.name, error: error)
            }
        }
        
        return results
    }
    
    /// Represents the result of a run
    public struct Result {
        /// The final output from the agent
        public let finalOutput: String
        
        /// The complete message history for the run
        public let messages: [Message]
    }
    
    /// Represents the state of a run
    public enum State {
        case notStarted
        case running
        case completed
        case failed
    }
    
    /// Errors that can occur during a run
    public enum RunError: Error {
        case invalidState(String)
        case guardrailError(GuardrailError)
        case toolNotFound(String)
        case toolExecutionError(toolName: String, error: Error)
        case executionError(Error)
    }
}