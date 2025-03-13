import Foundation

/// Static class for running agents
public struct AgentRunner {
    /// Runs an agent with input and context
    /// - Parameters:
    ///   - agent: The agent to run
    ///   - input: The input for the agent
    ///   - context: The context for the agent
    /// - Returns: The result of the run
    /// - Throws: RunnerError if there is a problem during execution
    public static func run<Context>(
        agent: Agent<Context>,
        input: String,
        context: Context
    ) async throws -> Run<Context>.Result {
        do {
            // Get model from provider
            let model = try await ModelProvider.shared.getModel(modelName: agent.modelSettings.modelName)
            
            // Create and execute run
            let run = Run(agent: agent, input: input, context: context, model: model)
            return try await run.execute()
        } catch let error as ModelProvider.ModelProviderError {
            throw RunnerError.modelError(error)
        } catch let error as Run<Context>.RunError {
            throw RunnerError.runError(error)
        } catch {
            throw RunnerError.unknownError(error)
        }
    }
    
    /// Runs an agent with input and context, streaming the results
    /// - Parameters:
    ///   - agent: The agent to run
    ///   - input: The input for the agent
    ///   - context: The context for the agent
    ///   - streamHandler: Handler for streamed content
    /// - Returns: The final result of the run
    /// - Throws: RunnerError if there is a problem during execution
    public static func runStreamed<Context>(
        agent: Agent<Context>,
        input: String,
        context: Context,
        streamHandler: @escaping (String) async -> Void
    ) async throws -> Run<Context>.Result {
        do {
            // Get model from provider
            let model = try await ModelProvider.shared.getModel(modelName: agent.modelSettings.modelName)
            
            // Create modified model settings for streaming
            let streamSettings = agent.modelSettings
            
            // Create and execute streamed run
            return try await runStreamedInternal(
                agent: agent,
                input: input,
                context: context,
                model: model,
                settings: streamSettings,
                streamHandler: streamHandler
            )
        } catch let error as ModelProvider.ModelProviderError {
            throw RunnerError.modelError(error)
        } catch {
            throw RunnerError.unknownError(error)
        }
    }
    
    /// Internal implementation of streamed run
    /// - Parameters:
    ///   - agent: The agent to run
    ///   - input: The input for the agent
    ///   - context: The context for the agent
    ///   - model: The model to use
    ///   - settings: The model settings
    ///   - streamHandler: Handler for streamed content
    /// - Returns: The final result of the run
    /// - Throws: RunnerError if there is a problem during execution
    private static func runStreamedInternal<Context>(
        agent: Agent<Context>,
        input: String,
        context: Context,
        model: ModelInterface,
        settings: ModelSettings,
        streamHandler: @escaping (String) async -> Void
    ) async throws -> Run<Context>.Result {
        // Validate input with guardrails
        var validatedInput = input
        for guardrail in agent.guardrails {
            do {
                validatedInput = try guardrail.validateInput(validatedInput)
            } catch let error as GuardrailError {
                throw RunnerError.guardrailError(error)
            }
        }
        
        // Check for handoffs
        for handoff in agent.handoffs {
            if handoff.filter.shouldHandoff(input: validatedInput, context: context) {
                // Create and execute a new run with the handoff agent
                return try await runStreamedInternal(
                    agent: handoff.agent,
                    input: validatedInput,
                    context: context,
                    model: model,
                    settings: handoff.agent.modelSettings,
                    streamHandler: streamHandler
                )
            }
        }
        
        // Initialize messages with system message and user input
        var messages: [Message] = [
            .system(agent.instructions),
            .user(validatedInput)
        ]
        
        // Run the agent with streaming
        var contentBuffer = ""
        var toolCalls: [ModelResponse.ToolCall] = []
        
        let response = try await model.getStreamedResponse(
            messages: messages,
            settings: settings
        ) { event in
            switch event {
            case .content(let content):
                contentBuffer += content
                await streamHandler(content)
                
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
                
            case .end:
                break
            }
        }
        
        // Add assistant message
        messages.append(.assistant(response.content))
        
        // Process tool calls if any
        if !toolCalls.isEmpty {
            let toolMap = Dictionary(uniqueKeysWithValues: agent.tools.map { ($0.name, $0) })
            var toolResults: [MessageContent.ToolResult] = []
            
            for toolCall in toolCalls {
                guard let tool = toolMap[toolCall.name] else {
                    throw RunnerError.toolNotFound("Tool \(toolCall.name) not found")
                }
                
                do {
                    // Stream tool name before execution
                    await streamHandler("\nExecuting tool: \(toolCall.name)...\n")
                    
                    let result = try await tool(toolCall.parameters, context: context)
                    let resultString: String
                    
                    if let stringResult = result as? String {
                        resultString = stringResult
                    } else {
                        // Convert result to JSON string
                        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
                        resultString = String(data: data, encoding: .utf8) ?? "Invalid result"
                    }
                    
                    let toolResult = MessageContent.ToolResult(
                        toolCallId: toolCall.id,
                        result: resultString
                    )
                    
                    toolResults.append(toolResult)
                    
                    // Add tool result message
                    messages.append(Message(role: .tool, content: .toolResults(toolResult)))
                    
                    // Stream result
                    await streamHandler("\nTool result: \(resultString)\n")
                } catch {
                    throw RunnerError.toolExecutionError(toolName: toolCall.name, error: error)
                }
            }
            
            // Get final response after tool calls
            contentBuffer = ""
            
            let finalResponse = try await model.getStreamedResponse(
                messages: messages,
                settings: settings
            ) { event in
                switch event {
                case .content(let content):
                    contentBuffer += content
                    await streamHandler(content)
                    
                case .toolCall, .end:
                    break
                }
            }
            
            // Add final assistant message
            messages.append(.assistant(finalResponse.content))
            
            // Validate output with guardrails
            var finalOutput = finalResponse.content
            for guardrail in agent.guardrails {
                do {
                    finalOutput = try guardrail.validateOutput(finalOutput)
                } catch let error as GuardrailError {
                    throw RunnerError.guardrailError(error)
                }
            }
            
            return Run<Context>.Result(
                finalOutput: finalOutput,
                messages: messages
            )
        } else {
            // Validate output with guardrails
            var finalOutput = response.content
            for guardrail in agent.guardrails {
                do {
                    finalOutput = try guardrail.validateOutput(finalOutput)
                } catch let error as GuardrailError {
                    throw RunnerError.guardrailError(error)
                }
            }
            
            return Run<Context>.Result(
                finalOutput: finalOutput,
                messages: messages
            )
        }
    }
    
    /// Errors that can occur during agent execution
    public enum RunnerError: Error {
        case modelError(ModelProvider.ModelProviderError)
        case runError(any Error)
        case guardrailError(GuardrailError)
        case toolNotFound(String)
        case toolExecutionError(toolName: String, error: Error)
        case unknownError(Error)
    }
}