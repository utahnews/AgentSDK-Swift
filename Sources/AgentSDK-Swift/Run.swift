// /Sources/AgentSDK-Swift/Run.swift

import Foundation

// Assume necessary imports and definitions exist for:
// Agent, Tool, Message, ModelInterface, ModelSettings, ModelResponse,
// ModelProvider, Guardrail, GuardrailError, Handoff, HandoffFilter, AppLogger,
// OpenAIModel.OpenAIModelError (or a generic ModelError)

/// Represents a single run of an agent, handling the conversation flow including tool calls.
public final class Run<Context> {
    public let agent: Agent<Context>
    public let input: String
    public let context: Context
    public private(set) var messages: [Message] = []
    public private(set) var state: State = .notStarted
    private let model: ModelInterface

    public init(agent: Agent<Context>, input: String, context: Context, model: ModelInterface) {
        self.agent = agent
        self.input = input
        self.context = context
        self.model = model
        self.messages.append(.system(agent.instructions))
    }

    public func execute() async throws -> Result {
        guard state == .notStarted else { throw RunError.invalidState("Run has already been started or completed.") }
        state = .running
        AppLogger.log("Run[\(agent.name)] state: running")

        var validatedInput = input
        // --- Input Guardrails ---
        AppLogger.log("Run[\(agent.name)] validating input...")
        for guardrail in agent.guardrails { // Iterate through all guardrails
            do {
                // Call validateInput directly - it's synchronous according to Guardrail.swift source
                validatedInput = try guardrail.validateInput(validatedInput)
                AppLogger.log("Run[\(agent.name)] input passed guardrail: \(type(of: guardrail))")
            } catch let error as GuardrailError { // Catch specific GuardrailError
                state = .failed
                AppLogger.error("Run[\(agent.name)] input failed guardrail: \(type(of: guardrail))", error: error)
                throw RunError.guardrailError(error) // Wrap in RunError.guardrailError
            } catch { // Catch other potential errors
                state = .failed
                AppLogger.error("Run[\(agent.name)] unexpected error during input guardrail: \(type(of: guardrail))", error: error)
                throw RunError.executionError(error) // Wrap in generic RunError
            }
        }
        AppLogger.log("Run[\(agent.name)] input validation complete.")


        // --- Handoff Check ---
        AppLogger.log("Run[\(agent.name)] checking for handoffs...")
        for handoff in agent.handoffs {
            // Assuming Handoff filter exists and context passing is correct
            if handoff.filter.shouldHandoff(input: validatedInput, context: context) {
                AppLogger.log("Run[\(agent.name)] handing off to Agent[\(handoff.agent.name)]")
                // Create and execute a new run with the handoff agent
                guard let handoffModel = try? await ModelProvider.shared.getModel(modelName: handoff.agent.modelSettings.modelName) else {
                     AppLogger.error("Run[\(agent.name)] failed to get model for handoff agent [\(handoff.agent.name)]")
                    throw RunError.executionError(ModelProvider.ModelProviderError.modelNotFound(modelName: handoff.agent.modelSettings.modelName))
                }
                let handoffRun = Run(
                    agent: handoff.agent,
                    input: validatedInput,
                    context: context, // Pass same context
                    model: handoffModel
                )
                // Tail call execution - return the result of the handoff run directly
                return try await handoffRun.execute()
            }
        }
        AppLogger.log("Run[\(agent.name)] no applicable handoffs found.")


        messages.append(.user(validatedInput))
        AppLogger.log("Run[\(agent.name)] added user message.")

        // --- Prepare tools with type erasure ---
        let agentToolsErased: [Tool<Any>] = agent.tools.map { $0.eraseToAnyContext() } // Use corrected method
        AppLogger.log("Run[\(agent.name)] prepared \(agentToolsErased.count) type-erased tools.")


        var finalOutput: String = ""
        do {
            AppLogger.log("Run[\(agent.name)] making first call to model...")
            // --- First call to model ---
            let response = try await model.getResponse(
                messages: messages,
                settings: agent.modelSettings,
                agentTools: agentToolsErased // <<< Pass ERASED tools
            )
            AppLogger.log("Run[\(agent.name)] first model call completed. ToolCalls: \(response.toolCalls.count)")
            if !response.content.isEmpty { AppLogger.log("Run[\(agent.name)] first model call content (prefix): \(response.content.prefix(100))...") }


            // --- Process Tool Calls (if any) ---
            if !response.toolCalls.isEmpty {
                AppLogger.log("Run[\(agent.name)] processing \(response.toolCalls.count) tool calls...")
                // Add the initial assistant message (which might just contain the tool calls)
                 if !response.content.isEmpty {
                      messages.append(.assistant(response.content))
                      AppLogger.log("Run[\(agent.name)] added assistant message (contains tool calls).")
                 }

                // Execute the tools and get results
                let toolResults = try await processToolCalls(response.toolCalls)

                // Add tool results to messages for the next API call
                for result in toolResults { messages.append(Message(role: .tool, content: .toolResults(result))) }
                AppLogger.log("Run[\(agent.name)] added \(toolResults.count) tool result messages.")

                AppLogger.log("Run[\(agent.name)] making second call to model (after tool results)...")
                // --- Second call to model ---
                let finalResponse = try await model.getResponse(
                    messages: messages, // History now includes tool results
                    settings: agent.modelSettings,
                    agentTools: agentToolsErased // <<< Pass ERASED tools again
                )
                AppLogger.log("Run[\(agent.name)] second model call completed.")
                if !finalResponse.content.isEmpty { AppLogger.log("Run[\(agent.name)] second model call content (prefix): \(finalResponse.content.prefix(100))...") }

                finalOutput = finalResponse.content // Final text output after tool execution

                // Add final assistant message if not empty and not duplicate
                 var shouldAddFinalMessage = true
                 if let lastMessage = messages.last, lastMessage.role == .assistant {
                     if case .text(let lastText) = lastMessage.content {
                         if lastText == finalOutput { shouldAddFinalMessage = false; /* log duplicate */ }
                     }
                 }
                 if shouldAddFinalMessage && !finalOutput.isEmpty {
                     messages.append(.assistant(finalOutput))
                     AppLogger.log("Run[\(agent.name)] added final assistant message (after tools).")
                 } else if finalOutput.isEmpty { AppLogger.log("Run[\(agent.name)] final response content after tools was empty.") }

            } else { // No tool calls
                 AppLogger.log("Run[\(agent.name)] no tool calls received from first model response.")
                 finalOutput = response.content // First response is final
                 if !finalOutput.isEmpty {
                    messages.append(.assistant(finalOutput))
                    AppLogger.log("Run[\(agent.name)] added assistant message (no tools called).")
                 } else { AppLogger.log("Run[\(agent.name)] initial response content was empty (no tools called).") }
            }

            // --- Output Guardrails ---
            AppLogger.log("Run[\(agent.name)] validating final output...")
            var validatedOutput = finalOutput
            for guardrail in agent.guardrails { // Iterate through all guardrails
                do {
                    // Call validateOutput directly - it's synchronous
                    validatedOutput = try guardrail.validateOutput(validatedOutput)
                    AppLogger.log("Run[\(agent.name)] output passed guardrail: \(type(of: guardrail))")
                } catch let error as GuardrailError { // Catch specific GuardrailError
                    state = .failed
                    AppLogger.error("Run[\(agent.name)] output failed guardrail: \(type(of: guardrail))", error: error)
                    throw RunError.guardrailError(error) // Wrap in RunError.guardrailError
                } catch { // Catch other potential errors
                     state = .failed
                     AppLogger.error("Run[\(agent.name)] unexpected error during output guardrail: \(type(of: guardrail))", error: error)
                     throw RunError.executionError(error) // Wrap in generic RunError
                }
            }
            finalOutput = validatedOutput // Use the validated output
            AppLogger.log("Run[\(agent.name)] output validation complete.")

            // Final state update and return
            state = .completed
            AppLogger.log("Run[\(agent.name)] state: completed.")
            return Result(finalOutput: finalOutput, messages: messages)

        } catch {
            state = .failed
            AppLogger.error("Run[\(agent.name)] state: failed during main execution block.", error: error)
            // Check actual error instance type
            if error is RunError || error is OpenAIModel.OpenAIModelError || error is GuardrailError {
                 throw error // Re-throw known specific errors
            } else {
                throw RunError.executionError(error) // Wrap others
            }
        }
    } // End execute()

    /// Processes tool calls received from the model by executing the corresponding local tools.
    private func processToolCalls(_ toolCalls: [ModelResponse.ToolCall]) async throws -> [MessageContent.ToolResult] {
         var results: [MessageContent.ToolResult] = []
         let toolMap = Dictionary(uniqueKeysWithValues: agent.tools.map { ($0.name, $0) })
         AppLogger.log("Run[\(agent.name)] processing \(toolCalls.count) raw tool calls.")
         for toolCall in toolCalls {
             AppLogger.log("Run[\(agent.name)] looking up tool: \(toolCall.name)")
             guard let tool = toolMap[toolCall.name] else {
                 AppLogger.error("Run[\(agent.name)] Tool not found: \(toolCall.name)")
                 throw RunError.toolNotFound("Tool \(toolCall.name) not found for agent \(agent.name)")
             }
             do {
                 AppLogger.log("Run[\(agent.name)] executing Tool[\(toolCall.name)] with params: \(toolCall.parameters)")
                 let result = try await tool(toolCall.parameters, context: context) // Use callAsFunction via ()
                 AppLogger.log("Run[\(agent.name)] Tool[\(toolCall.name)] executed. Result Type: \(type(of: result))")
                 // Format result robustly
                 let resultString: String
                  if let stringResult = result as? String { resultString = stringResult }
                  else {
                      do {
                          if JSONSerialization.isValidJSONObject(result) {
                              // If it IS a valid JSON object, serialize it
                              let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                              resultString = String(data: data, encoding: .utf8) ?? "Error: Could not encode non-string tool result to UTF8"
                              AppLogger.log("Run[\(agent.name)] Tool[\(toolCall.name)]: Encoded non-string result to JSON.")
                          } else {
                              // If it is NOT a valid JSON object, use its description
                               AppLogger.warning("Run[\(agent.name)] Tool[\(toolCall.name)]: Result is not a valid JSON object, using description.")
                               resultString = String(describing: result)
                          }
                      } catch {
                           AppLogger.warning("Run[\(agent.name)] Tool[\(toolCall.name)]: Failed to JSON encode non-string result (\(error.localizedDescription)). Using description fallback.")
                           resultString = String(describing: result)
                      }
                  }
                 AppLogger.log("Run[\(agent.name)] Tool[\(toolCall.name)]: Formatted result (prefix): \(resultString.prefix(100))...")
                 results.append(MessageContent.ToolResult(toolCallId: toolCall.id, result: resultString))
             } catch {
                  AppLogger.error("Run[\(agent.name)] error executing Tool[\(toolCall.name)]", error: error)
                 if error is RunError { throw error } // Avoid double wrapping RunError
                 else { throw RunError.toolExecutionError(toolName: toolCall.name, error: error) }
             }
         }
         AppLogger.log("Run[\(agent.name)] finished processing \(results.count) tool calls.")
         return results
     } // End processToolCalls

    // MARK: - Nested Types
    /// Represents the final result of a successful agent run.
    public struct Result {
        public let finalOutput: String
        public let messages: [Message]
    }
    /// Represents the possible states of an agent run.
    public enum State { case notStarted, running, completed, failed }
    /// Errors that can occur specifically during an agent run execution.
    public enum RunError: Error, LocalizedError {
        case invalidState(String)
        case guardrailError(GuardrailError)
        case toolNotFound(String)
        case toolExecutionError(toolName: String, error: Error)
        case executionError(Error)

        public var errorDescription: String? {
            switch self {
            case .invalidState(let msg): return "Run Error: Invalid state - \(msg)"
            case .guardrailError(let err): return "Run Error: Guardrail violation - \(String(describing: err))"
            case .toolNotFound(let name): return "Run Error: Tool not found - \(name)"
            case .toolExecutionError(let name, let err): return "Run Error: Failed executing tool '\(name)' - \(err.localizedDescription)"
            case .executionError(let err): return "Run Error: General execution failure - \(err.localizedDescription)"
            }
        }
    }
} // End Run Class

// MARK: - MessageContent Extension (Helper)
extension MessageContent {
    var asText: String? {
        if case .text(let string) = self { return string }
        return nil
    }
}

