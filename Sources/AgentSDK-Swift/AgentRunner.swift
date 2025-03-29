// /Sources/AgentSDK-Swift/AgentRunner.swift

import Foundation

// Assume necessary imports and definitions exist for:
// Run, Agent, ModelProvider, ModelInterface, Tool, Message, ModelSettings, Guardrail, GuardrailError, Handoff, HandoffFilter, AppLogger

/// Static class providing high-level methods for running agents.
public struct AgentRunner {

    /// Runs an agent with input and context (non-streaming).
    public static func run<Context>(
        agent: Agent<Context>,
        input: String,
        context: Context
    ) async throws -> Run<Context>.Result {
        AppLogger.log("AgentRunner: Starting non-streaming run for Agent[\(agent.name)]")
        do {
            let model = try await ModelProvider.shared.getModel(modelName: agent.modelSettings.modelName)
            AppLogger.log("AgentRunner: Obtained model \(agent.modelSettings.modelName) for Agent[\(agent.name)]")
            let runInstance = Run(agent: agent, input: input, context: context, model: model)
            let result = try await runInstance.execute()
            AppLogger.log("AgentRunner: Non-streaming run completed for Agent[\(agent.name)]")
            return result
        } catch let error as ModelProvider.ModelProviderError {
            AppLogger.error("AgentRunner: ModelProvider error for Agent[\(agent.name)]", error: error)
            throw RunnerError.modelError(error)
        } catch let error as Run<Context>.RunError { // Use fully qualified name
            AppLogger.error("AgentRunner: Run error for Agent[\(agent.name)]", error: error)
            throw RunnerError.runError(error) // Wrap RunError in RunnerError
        } catch {
            AppLogger.error("AgentRunner: Unknown error during non-streaming run for Agent[\(agent.name)]", error: error)
            throw RunnerError.unknownError(error)
        }
    }

    /// Runs an agent with input and context, streaming the results.
    public static func runStreamed<Context>(
        agent: Agent<Context>,
        input: String,
        context: Context,
        streamHandler: @escaping (String) async -> Void
    ) async throws -> Run<Context>.Result {
        AppLogger.log("AgentRunner: Starting streaming run for Agent[\(agent.name)]")
        do {
            let model = try await ModelProvider.shared.getModel(modelName: agent.modelSettings.modelName)
            AppLogger.log("AgentRunner: Obtained model \(agent.modelSettings.modelName) for Agent[\(agent.name)]")
            let streamSettings = agent.modelSettings

            // Prepare tools with type erasure using the method on Tool
            let agentToolsErased: [Tool<Any>] = agent.tools.map { $0.eraseToAnyContext() }
            AppLogger.log("AgentRunner: Prepared \(agentToolsErased.count) type-erased tools for Agent[\(agent.name)] streaming.")

            // Pass ERASED tools to runStreamedInternal
            let result = try await runStreamedInternal(
                agent: agent,
                input: input,
                context: context,
                model: model,
                settings: streamSettings,
                agentTools: agentToolsErased, // Pass ERASED tools
                streamHandler: streamHandler
            )
            AppLogger.log("AgentRunner: Streaming run completed for Agent[\(agent.name)]")
            return result
        } catch let error as ModelProvider.ModelProviderError {
            AppLogger.error("AgentRunner: ModelProvider error for Agent[\(agent.name)] streaming", error: error)
            throw RunnerError.modelError(error)
         } catch {
             AppLogger.error("AgentRunner: Error during streaming run for Agent[\(agent.name)]", error: error)
            // Ensure proper error propagation/wrapping
             if let runError = error as? Run<Context>.RunError { throw RunnerError.runError(runError) }
             else if let runnerError = error as? RunnerError { throw runnerError }
             else { throw RunnerError.unknownError(error) }
        }
    }


    /// Internal implementation of the streaming run logic.
    // Accepts type-erased tools [Tool<Any>] from the public methods.
    private static func runStreamedInternal<Context>(
        agent: Agent<Context>,
        input: String,
        context: Context,
        model: ModelInterface,
        settings: ModelSettings,
        agentTools: [Tool<Any>], // Accepts ERASED tools
        streamHandler: @escaping (String) async -> Void
    ) async throws -> Run<Context>.Result {
        AppLogger.log("AgentRunner: runStreamedInternal starting for Agent[\(agent.name)]")

        // --- Input Guardrails ---
        var validatedInput = input
        for guardrail in agent.guardrails { // Iterate all guardrails
            do {
                // Call validateInput directly
                validatedInput = try guardrail.validateInput(validatedInput) // Synchronous
                AppLogger.log("AgentRunner: Input passed guardrail \(type(of: guardrail)) for Agent[\(agent.name)]")
            } catch let error as GuardrailError {
                 AppLogger.error("AgentRunner: Input failed guardrail \(type(of: guardrail)) for Agent[\(agent.name)]", error: error)
                 throw RunnerError.guardrailError(error) // Wrap in RunnerError
            } catch {
                 AppLogger.error("AgentRunner: Unexpected error during input guardrail \(type(of: guardrail)) for Agent[\(agent.name)]", error: error)
                 throw RunnerError.unknownError(error) // Wrap in RunnerError
            }
        }

        // --- Handoff Check ---
        for handoff in agent.handoffs {
            // Assuming Handoff filter exists and works
            if handoff.filter.shouldHandoff(input: validatedInput, context: context) {
                 AppLogger.log("AgentRunner: Handing off from Agent[\(agent.name)] to Agent[\(handoff.agent.name)]")
                 let handoffToolsErased: [Tool<Any>] = handoff.agent.tools.map { $0.eraseToAnyContext() } // Use method
                 guard let handoffModel = try? await ModelProvider.shared.getModel(modelName: handoff.agent.modelSettings.modelName) else {
                      throw RunnerError.modelError(ModelProvider.ModelProviderError.modelNotFound(modelName: handoff.agent.modelSettings.modelName))
                 }
                 // Recursive call with handoff agent and its erased tools
                 return try await runStreamedInternal(
                     agent: handoff.agent, input: validatedInput, context: context,
                     model: handoffModel, settings: handoff.agent.modelSettings,
                     agentTools: handoffToolsErased, // Pass ERASED tools for handoff
                     streamHandler: streamHandler
                 )
             }
        }

        // Initialize messages
        var messages: [Message] = [ .system(agent.instructions), .user(validatedInput) ]
        AppLogger.log("AgentRunner: Initialized messages for Agent[\(agent.name)]")

        // --- First call to model (streaming) ---
        var contentBuffer = ""
        var receivedToolCalls: [ModelResponse.ToolCall] = [] // Aggregate tool calls

        AppLogger.log("AgentRunner: Making first streaming call to model for Agent[\(agent.name)]")
        let response = try await model.getStreamedResponse(
            messages: messages,
            settings: settings,
            agentTools: agentTools, // Pass ERASED tools
            callback: { event in
                // --- Streaming event processing ---
                switch event {
                case .content(let content):
                    contentBuffer += content
                    await streamHandler(content)
                case .toolCall(let partialToolCall):
                    // Aggregate Streaming Tool Calls
                    if let index = receivedToolCalls.firstIndex(where: { $0.id == partialToolCall.id }) {
                        let existingCall = receivedToolCalls[index]
                        var mergedParams = existingCall.parameters
                        for (key, value) in partialToolCall.parameters { mergedParams[key] = value }
                        let updatedName = partialToolCall.name.isEmpty ? existingCall.name : partialToolCall.name
                        receivedToolCalls[index] = ModelResponse.ToolCall(id: existingCall.id, name: updatedName, parameters: mergedParams)
                    } else {
                        receivedToolCalls.append(partialToolCall)
                        await streamHandler("\n[Tool Call Start: \(partialToolCall.name)]\n")
                    }
                case .end:
                    AppLogger.log("AgentRunner: Received stream end event for Agent[\(agent.name)] first call.")
                    break
                }
                // --- End Streaming event processing ---
            }
        )
        AppLogger.log("AgentRunner: First streaming call finished for Agent[\(agent.name)]. Aggregated \(receivedToolCalls.count) tool calls.")

        if !response.content.isEmpty { messages.append(.assistant(response.content)) }

        // --- Process Tool Calls (if any) ---
        if !receivedToolCalls.isEmpty {
             AppLogger.log("AgentRunner: Processing \(receivedToolCalls.count) aggregated tool calls for Agent[\(agent.name)]")
             let toolMap = Dictionary(uniqueKeysWithValues: agent.tools.map { ($0.name, $0) })
             var toolResults: [MessageContent.ToolResult] = []
             for toolCall in receivedToolCalls {
                 guard let tool = toolMap[toolCall.name] else {
                     AppLogger.error("AgentRunner: Tool not found '\(toolCall.name)' for Agent[\(agent.name)] during processing")
                     throw RunnerError.toolNotFound("Tool \(toolCall.name) not found")
                 }
                 do {
                     await streamHandler("\n[Executing Tool: \(toolCall.name)...]\n")
                     let result = try await tool(toolCall.parameters, context: context) // Execute Tool<Context>
                     // Format result robustly
                     let resultString: String
                      if let stringResult = result as? String { resultString = stringResult }
                      else {
                          do {
                              guard JSONSerialization.isValidJSONObject(result) else {
                                  resultString = String(describing: result)
                                  AppLogger.warning("AgentRunner: Tool[\(toolCall.name)] result not valid JSON, using description.")
                                  continue
                              }
                              let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                              resultString = String(data: data, encoding: .utf8) ?? "Error: Could not encode tool result"
                          } catch {
                               resultString = String(describing: result)
                               AppLogger.warning("AgentRunner: Tool[\(toolCall.name)] failed JSON encoding result, using description (\(error)).")
                          }
                      }
                     let toolResult = MessageContent.ToolResult(toolCallId: toolCall.id, result: resultString)
                     toolResults.append(toolResult)
                     messages.append(Message(role: .tool, content: .toolResults(toolResult)))
                     await streamHandler("\n[Tool Result (\(toolCall.name))]\n")
                     await streamHandler(resultString)
                     await streamHandler("\n")
                 } catch {
                     AppLogger.error("AgentRunner: Error executing Tool[\(toolCall.name)]...", error: error)
                     // Use fully qualified name for RunError if needed
                     if error is Run<Context>.RunError { throw RunnerError.runError(error) }
                     else { throw RunnerError.toolExecutionError(toolName: toolCall.name, error: error) }
                 }
             }
             AppLogger.log("AgentRunner: Finished executing tools for Agent[\(agent.name)]")


            // --- Second call to model (streaming) ---
            contentBuffer = ""
            AppLogger.log("AgentRunner: Making second streaming call to model for Agent[\(agent.name)]")
            let finalResponse = try await model.getStreamedResponse(
                messages: messages, settings: settings,
                agentTools: agentTools, // Pass ERASED tools again
                callback: { event in
                     // --- Streaming final content ---
                      switch event {
                      case .content(let content):
                          contentBuffer += content
                          await streamHandler(content) // Stream final text
                      case .toolCall:
                          AppLogger.warning("AgentRunner: Received unexpected toolCall event during second streaming call for Agent[\(agent.name)]")
                      case .end:
                           AppLogger.log("AgentRunner: Received stream end event for Agent[\(agent.name)] second call.")
                           break
                      }
                     // --- End Streaming final content ---
                 }
            )
            AppLogger.log("AgentRunner: Second streaming call finished for Agent[\(agent.name)]")

            if !finalResponse.content.isEmpty { messages.append(.assistant(finalResponse.content)) }
            var finalOutput = finalResponse.content

            // --- Output Guardrails ---
            AppLogger.log("AgentRunner: Validating final output for Agent[\(agent.name)] streaming...")
            for guardrail in agent.guardrails { // Iterate all guardrails
                 do {
                      // Call validateOutput directly
                      finalOutput = try guardrail.validateOutput(finalOutput) // Synchronous
                      AppLogger.log("AgentRunner: Output passed guardrail \(type(of: guardrail)) for Agent[\(agent.name)]")
                 } catch let error as GuardrailError { throw RunnerError.guardrailError(error) }
                   catch { throw RunnerError.unknownError(error) }
            }

            AppLogger.log("AgentRunner: Streaming run internal processing complete (with tools) for Agent[\(agent.name)]")
            return Run<Context>.Result(finalOutput: finalOutput, messages: messages)

        } else { // No tool calls
             AppLogger.log("AgentRunner: No tool calls received in first response for Agent[\(agent.name)]")
            var finalOutput = response.content
            // --- Output Guardrails ---
             AppLogger.log("AgentRunner: Validating final output for Agent[\(agent.name)] streaming (no tools)...")
            for guardrail in agent.guardrails { // Iterate all guardrails
                 do {
                      // Call validateOutput directly
                      finalOutput = try guardrail.validateOutput(finalOutput) // Synchronous
                      AppLogger.log("AgentRunner: Output passed guardrail \(type(of: guardrail)) for Agent[\(agent.name)]")
                 } catch let error as GuardrailError { throw RunnerError.guardrailError(error) }
                   catch { throw RunnerError.unknownError(error) }
            }

            AppLogger.log("AgentRunner: Streaming run internal processing complete (no tools) for Agent[\(agent.name)]")
            // Ensure the assistant message for the final output is present
            if messages.last?.role != .assistant || messages.last?.content.asText != finalOutput {
                 if !finalOutput.isEmpty { messages.append(.assistant(finalOutput)) }
            }
            return Run<Context>.Result(finalOutput: finalOutput, messages: messages)
        }
    } // End runStreamedInternal


    // --- RunnerError Enum ---
    public enum RunnerError: Error, LocalizedError {
        case modelError(ModelProvider.ModelProviderError)
        case runError(any Error) // Use 'any Error' for broader compatibility
        case guardrailError(GuardrailError)
        case toolNotFound(String)
        case toolExecutionError(toolName: String, error: Error)
        case unknownError(Error)

        // Provide localized descriptions for errors
        public var errorDescription: String? {
            switch self {
            case .modelError(let err): return "Runner Error: Model provider failed - \(String(describing: err))"
            case .runError(let err): return "Runner Error: Underlying run execution failed - \(err.localizedDescription)"
            case .guardrailError(let err): return "Runner Error: Guardrail violation - \(String(describing: err))"
            case .toolNotFound(let name): return "Runner Error: Tool not found - \(name)"
            case .toolExecutionError(let name, let err): return "Runner Error: Failed executing tool '\(name)' - \(err.localizedDescription)"
            case .unknownError(let err): return "Runner Error: An unknown error occurred - \(err.localizedDescription)"
            }
        }
    }

} // End AgentRunner
