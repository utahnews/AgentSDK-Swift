import Foundation

/// Settings for configuring model behavior
public struct ModelSettings {
    /// The name of the model to use
    public var modelName: String
    
    /// Temperature controls randomness (0.0 to 1.0)
    public var temperature: Double?
    
    /// Top-p controls diversity of output (0.0 to 1.0)
    public var topP: Double?
    
    /// Maximum number of tokens to generate
    public var maxTokens: Int?
    
    /// Response formats to use (e.g., JSON)
    public var responseFormat: ResponseFormat?
    
    /// Seeds for deterministic generation
    public var seed: Int?
    
    /// Additional model-specific parameters
    public var additionalParameters: [String: Any]
    
    /// Creates a new model settings configuration
    /// - Parameters:
    ///   - modelName: The name of the model to use
    ///   - temperature: Optional temperature value
    ///   - topP: Optional top-p value
    ///   - maxTokens: Optional maximum tokens to generate
    ///   - responseFormat: Optional response format
    ///   - seed: Optional seed for deterministic generation
    ///   - additionalParameters: Additional model-specific parameters
    public init(
        modelName: String = "gpt-4-turbo",
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        responseFormat: ResponseFormat? = nil,
        seed: Int? = nil,
        additionalParameters: [String: Any] = [:]
    ) {
        self.modelName = modelName
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.responseFormat = responseFormat
        self.seed = seed
        self.additionalParameters = additionalParameters
    }
    
    /// Creates a copy of these settings with optional overrides
    /// - Parameters:
    ///   - modelName: Optional override for model name
    ///   - temperature: Optional override for temperature
    ///   - topP: Optional override for top-p
    ///   - maxTokens: Optional override for max tokens
    ///   - responseFormat: Optional override for response format
    ///   - seed: Optional override for seed
    ///   - additionalParameters: Optional override for additional parameters
    /// - Returns: A new settings object with the specified overrides
    public func with(
        modelName: String? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        responseFormat: ResponseFormat? = nil,
        seed: Int? = nil,
        additionalParameters: [String: Any]? = nil
    ) -> ModelSettings {
        var settings = self
        
        if let modelName = modelName {
            settings.modelName = modelName
        }
        
        if let temperature = temperature {
            settings.temperature = temperature
        }
        
        if let topP = topP {
            settings.topP = topP
        }
        
        if let maxTokens = maxTokens {
            settings.maxTokens = maxTokens
        }
        
        if let responseFormat = responseFormat {
            settings.responseFormat = responseFormat
        }
        
        if let seed = seed {
            settings.seed = seed
        }
        
        if let additionalParameters = additionalParameters {
            settings.additionalParameters = additionalParameters
        }
        
        return settings
    }
    
    /// Represents the response format for the model
    public enum ResponseFormat {
        case json
        case text
        
        /// Returns the string representation of the format for OpenAI
        public var jsonValue: String {
            switch self {
            case .json: return "json_object"
            case .text: return "text"
            }
        }
    }
}