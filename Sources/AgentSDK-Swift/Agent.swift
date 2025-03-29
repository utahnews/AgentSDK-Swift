import Foundation

/// Represents an AI agent capable of interacting with tools, handling conversations,
/// and producing outputs based on instructions.
public final class Agent<Context> {
    /// The name of the agent, used for identification
    public let name: AgentName
    
    /// Instructions that guide the agent's behavior
    public let instructions: String
    
    /// Tools available to the agent
    public private(set) var tools: [Tool<Context>]
    
    /// Guardrails that enforce constraints on agent input/output
    public private(set) var guardrails: [Guardrail]
    
    /// Handoffs for delegating work to other agents
    public private(set) var handoffs: [Handoff<Context>]
    
    /// Settings for the model used by this agent
    public var modelSettings: ModelSettings
    
    /// Creates a new agent with the specified configuration
    /// - Parameters:
    ///   - name: The name of the agent
    ///   - instructions: The instructions for guiding agent behavior
    ///   - tools: Optional array of tools available to the agent
    ///   - guardrails: Optional array of guardrails for the agent
    ///   - handoffs: Optional array of handoffs for the agent
    ///   - modelSettings: Optional model settings for the agent
    public init(
        name: AgentName,
        instructions: String,
        tools: [Tool<Context>] = [],
        guardrails: [Guardrail] = [],
        handoffs: [Handoff<Context>] = [],
        modelSettings: ModelSettings = ModelSettings()
    ) {
        self.name = name
        self.instructions = instructions
        self.tools = tools
        self.guardrails = guardrails
        self.handoffs = handoffs
        self.modelSettings = modelSettings
    }
    
    /// Adds a tool to the agent
    /// - Parameter tool: The tool to add
    /// - Returns: Self for method chaining
    @discardableResult
    public func addTool(_ tool: Tool<Context>) -> Self {
        tools.append(tool)
        return self
    }
    
    /// Adds multiple tools to the agent
    /// - Parameter tools: The tools to add
    /// - Returns: Self for method chaining
    @discardableResult
    public func addTools(_ tools: [Tool<Context>]) -> Self {
        self.tools.append(contentsOf: tools)
        return self
    }
    
    /// Adds a guardrail to the agent
    /// - Parameter guardrail: The guardrail to add
    /// - Returns: Self for method chaining
    @discardableResult
    public func addGuardrail(_ guardrail: Guardrail) -> Self {
        guardrails.append(guardrail)
        return self
    }
    
    /// Adds a handoff to the agent
    /// - Parameter handoff: The handoff to add
    /// - Returns: Self for method chaining
    @discardableResult
    public func addHandoff(_ handoff: Handoff<Context>) -> Self {
        handoffs.append(handoff)
        return self
    }
    
    /// Creates a copy of this agent
    /// - Returns: A new agent with the same configuration
    public func clone() -> Agent<Context> {
        Agent(
            name: name,
            instructions: instructions,
            tools: tools,
            guardrails: guardrails,
            handoffs: handoffs,
            modelSettings: modelSettings
        )
    }
}
