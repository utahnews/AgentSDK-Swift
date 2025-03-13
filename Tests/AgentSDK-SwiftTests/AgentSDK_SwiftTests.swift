import Testing
@testable import AgentSDK_Swift

@Test func testAgentCreation() async throws {
    // Create a simple agent
    let agent = Agent<Void>(
        name: "TestAgent",
        instructions: "You are a helpful assistant."
    )
    
    #expect(agent.name == "TestAgent")
    #expect(agent.instructions == "You are a helpful assistant.")
    #expect(agent.tools.isEmpty)
    #expect(agent.guardrails.isEmpty)
    #expect(agent.handoffs.isEmpty)
}

@Test func testToolCreation() async throws {
    // Create a simple tool
    let tool = Tool<Void>(
        name: "echo",
        description: "Echoes the input",
        parameters: [
            Tool.Parameter(
                name: "text",
                description: "The text to echo",
                type: .string
            )
        ],
        execute: { params, _ in
            return params["text"] as? String ?? "No text provided"
        }
    )
    
    #expect(tool.name == "echo")
    #expect(tool.description == "Echoes the input")
    #expect(tool.parameters.count == 1)
    #expect(tool.parameters[0].name == "text")
}

@Test func testAddingToolToAgent() async throws {
    // Create a simple agent
    let agent = Agent<Void>(
        name: "TestAgent",
        instructions: "You are a helpful assistant."
    )
    
    // Create a simple tool
    let tool = Tool<Void>(
        name: "echo",
        description: "Echoes the input",
        execute: { params, _ in
            return params["text"] as? String ?? "No text provided"
        }
    )
    
    // Add tool to agent
    let updatedAgent = agent.addTool(tool)
    
    #expect(updatedAgent.tools.count == 1)
    #expect(updatedAgent.tools[0].name == "echo")
}

@Test func testGuardrailValidation() async throws {
    // Create a simple input length guardrail
    let guardrail = InputLengthGuardrail(maxLength: 10)
    
    // Test valid input
    let validInput = "Hello"
    let _ = try guardrail.validateInput(validInput)
    
    // Test invalid input
    let invalidInput = "This is a very long input that exceeds the maximum length"
    do {
        let _ = try guardrail.validateInput(invalidInput)
        #expect(Bool(false), "Should have thrown an error")
    } catch {
        #expect(error is GuardrailError)
    }
}
