//
//  OpenAI+ChatCompletion.swift
//  openai-swift
//
//  Created by Reid Chatham on 12/7/23.
//

import Foundation

public extension OpenAI {
    func performChatCompletionRequest(messages: [Message], model: Model, stream: Bool = false, completion: @escaping (Result<OpenAI.ChatCompletionResponse, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        perform(request: OpenAI.ChatCompletionRequest(model: model, messages: messages, stream: stream), completion: completion, didCompleteStreaming: didCompleteStreaming)
    }
}

public extension OpenAI {
    struct ChatCompletionRequest: Codable, OpenAIRequest, StreamableRequest, CompletableRequest {
        public typealias Response = ChatCompletionResponse
        public static var path: String { "chat/completions" }
        let model: Model
        let messages: [Message]
        let temperature: Double?
        let top_p: Double?
        let n: Int? // how many chat completions to generate for each request
        var stream: Bool?
        let stream_options: StreamOptions?
        let stop: Stop?
        let max_tokens: Int?
        let presence_penalty: Double?
        let frequency_penalty: Double?
        let logit_bias: [String: Double]?
        let logprobs: Bool?
        let top_logprobs: Int?
        let user: String?
        let response_format: ResponseFormat?
        let seed: Int?
        let tools: [Tool]?
        let tool_choice: ToolChoice?
        let parallel_tool_calls: Bool?
        @CodableIgnored var toolCallHandler: (([OpenAI.Message.ToolCall]) -> [String])?

        public init(model: Model, messages: [Message], temperature: Double? = nil, top_p: Double? = nil, n: Int? = nil, stream: Bool? = nil, stream_options: StreamOptions? = nil, stop: Stop? = nil, max_tokens: Int? = nil, presence_penalty: Double? = nil, frequency_penalty: Double? = nil, logit_bias: [String: Double]? = nil, logprobs: Bool? = nil, top_logprobs: Int? = nil, user: String? = nil, response_type: ResponseType? = nil, seed: Int? = nil, tools: [Tool]? = nil, tool_choice: ToolChoice? = nil, parallel_tool_calls: Bool? = nil, toolCallHandler: @escaping ([OpenAI.Message.ToolCall]) -> [String] = { _ in [] }) {
            self.model = model
            self.messages = messages
            self.temperature = temperature
            self.top_p = top_p
            self.n = n
            self.stream = stream
            self.stream_options = stream_options
            self.stop = stop
            self.max_tokens = max_tokens
            self.presence_penalty = presence_penalty
            self.frequency_penalty = frequency_penalty
            self.logit_bias = logit_bias
            self.logprobs = logprobs
            self.top_logprobs = top_logprobs
            self.user = user
            self.response_format = response_type.flatMap { ResponseFormat(type: $0) }
            self.seed = seed
            self.tools = tools
            self.tool_choice = tool_choice
            self.parallel_tool_calls = parallel_tool_calls
            self.toolCallHandler = toolCallHandler
        }

        public func completion(response: OpenAI.ChatCompletionResponse) throws -> ChatCompletionRequest? { // This needs tests badly
            for choice in response.choices { // This only returns requests for the first choice - TODO: Add handling of multiple choices
                guard let tool_calls = choice.message?.tool_calls ?? choice.delta?.tool_calls, !tool_calls.isEmpty else { continue }
                var toolMessages: [Message] = []
                var unhandledToolCalls: [Message.ToolCall] = []
                for tool_call in tool_calls {
                    if case .function(let function) = tools?.first(where: { $0.name == tool_call.function.name }) {
                        guard let args = tool_call.function.arguments.dictionary else { throw ChatCompletionError.failedToDecodeFunctionArguments }
                        guard function.parameters.required?.filter({ !args.keys.contains($0) }).isEmpty ?? true else { throw ChatCompletionError.missingRequiredFunctionArguments }
                        guard let str = function.callback?(args) else { unhandledToolCalls.append(tool_call); continue }
                        toolMessages.append(try Message(role: .tool, content: .string(str), name: nil, tool_call_id: tool_call.id))
                    } else { unhandledToolCalls.append(tool_call) }
                }
                toolMessages.append(contentsOf: try zip(unhandledToolCalls,toolCallHandler?(unhandledToolCalls) ?? []).map { try Message(role: .tool, content: .string($0.1), name: nil, tool_call_id: $0.0.id) })
                if toolMessages.isEmpty { continue } // user did not use the framework to handle their function calls
                guard toolMessages.count == tool_calls.count else { throw ChatCompletionError.missingToolCallResponse } // OpenAI will return an error for this already and is a developer configuration issue.
                let assistant = try Message(role: .assistant, content: .null, name: nil, tool_calls: tool_calls) // if wanting to use names for assistant message, need to insert here
                return ChatCompletionRequest(model: model, messages: messages + [assistant] + toolMessages, temperature: temperature, top_p: top_p, n: n, stream: stream, stop: stop, max_tokens: max_tokens, presence_penalty: presence_penalty, frequency_penalty: frequency_penalty, logit_bias: logit_bias, user: user, response_type: response_format?.type, seed: seed, tools: tools, tool_choice: tool_choice)
            }
            return nil
        }

        public struct StreamOptions: Codable {
            let include_usage: Bool
        }

        public enum ToolChoice: Codable {
            case none, auto, required
            case tool(ToolWrapper)

            public enum ToolWrapper: Codable {
                case function(String)

                public struct FunctionDetails: Codable {
                    var name: String
                    public init(name: String) { self.name = name }
                }

                enum CodingKeys: String, CodingKey {
                    case type, function
                }

                public init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let type = try container.decode(String.self, forKey: .type)
                    switch type {
                    case "function":
                        let functionDetails = try container.decode(FunctionDetails.self, forKey: .function)
                        self = .function(functionDetails.name)
                    default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid type value")
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case .function(let name):
                        try container.encode("function", forKey: .type)
                        try container.encode(FunctionDetails(name: name), forKey: .function)
                    }
                }
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let stringValue = try? container.decode(String.self) {
                    switch stringValue {
                    case "none": self = .none
                    case "auto": self = .auto
                    case "required": self = .required
                    default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid string value")
                    }
                } else { self = .tool(try ToolWrapper(from: decoder)) }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .none: try container.encode("none")
                case .auto: try container.encode("auto")
                case .required: try container.encode("required")
                case .tool(let toolWrapper): try container.encode(toolWrapper)
                }
            }
        }

        public enum Stop: Codable {
            case string(String)
            case array([String])

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) { self = .string(string) }
                else if let array = try? container.decode([String].self) { self = .array(array) }
                else { throw DecodingError.typeMismatch(Stop.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid type for Stop")) }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let string): try container.encode(string)
                case .array(let array): try container.encode(array)
                }
            }
        }

        public struct ResponseFormat: Codable {
            let type: ResponseType
            public init(type: ResponseType) {
                self.type = type
            }
        }

        public enum ResponseType: String, Codable {
            case text, json_object
        }
    }

    struct ChatCompletionResponse: StreamableResponse, Codable {
        public let id: String
        public let object: String // chat.completion or chat.completion.chunk
        public let created: Int
        public let model: String? // TODO: make response return typed model response
        public let system_fingerprint: String?
        public let choices: [Choice]
        public let usage: Usage?

        public struct Choice: Codable {
            public let index: Int
            public let message: Message?
            public let finish_reason: FinishReason?
            public let delta: Message.Delta?
            
            public enum FinishReason: String, Codable {
                case stop, length, content_filter, tool_calls
            }

            func combining(with next: Choice) -> Choice {
                return Choice(index: index, message: message, finish_reason: finish_reason ?? next.finish_reason, delta: combining(delta, with: next.delta))
            }

            func combining(_ delta: Message.Delta?, with next: Message.Delta?) -> Message.Delta? {
                guard let delta = delta, let next = next else { return delta ?? next }
                return Message.Delta(role: delta.role ?? next.role, content: delta.content ?? "" + (next.content ?? ""), tool_calls: combining(delta.tool_calls, with: next.tool_calls))
            }

            func combining(_ toolCalls: [Message.ToolCall]?, with next: [Message.ToolCall]?) -> [Message.ToolCall]? {
                guard let toolCalls = toolCalls, let next = next else { return toolCalls ?? next }
                return next.sorted().reduce(into: toolCalls.sorted()) { partialResult, toolCall in
                    if (toolCall.index ?? .max < partialResult.count) {
                        partialResult[toolCall.index!] = combining(partialResult[toolCall.index!], with: toolCall)
                    } else {
                        partialResult.append(toolCall)
                    }
                }
            }

            func combining(_ toolCall: Message.ToolCall, with next: Message.ToolCall) -> Message.ToolCall {
                return Message.ToolCall(index: next.index ?? toolCall.index ?? 0, id:  next.id ?? toolCall.id ?? "", type: toolCall.type ?? next.type ?? .function, function: combining(toolCall.function, with: next.function))
            }

            func combining(_ function: Message.ToolCall.Function, with next: Message.ToolCall.Function) -> Message.ToolCall.Function {
                return Message.ToolCall.Function(name: next.name ?? function.name ?? "", arguments: function.arguments + next.arguments)
            }
        }

        public struct Usage: Codable {
            public let prompt_tokens: Int
            public let completion_tokens: Int
            public let total_tokens: Int
        }

        public func combining(with next: ChatCompletionResponse) -> ChatCompletionResponse {
            return ChatCompletionResponse(id: next.id, object: next.object, created: next.created, model: next.model, system_fingerprint: next.system_fingerprint, choices: combining(choices, with: next.choices), usage: next.usage)
        }

        func combining(_ choices: [Choice], with next: [Choice]) -> [Choice] {
            if choices.isEmpty { return next }
            return zip(choices.sorted(), next.sorted()).map { $0.combining(with: $1) }
        }

        static var empty: ChatCompletionResponse { ChatCompletionResponse(id: "", object: "", created: -1, model: nil, system_fingerprint: nil, choices: [], usage: nil) }
    }

    enum ChatCompletionError: String, Error {
        case failedToDecodeFunctionArguments
        case missingRequiredFunctionArguments
        case missingToolCallResponse
    }
}

extension Array where Element == OpenAI.ChatCompletionResponse.Choice {
    func sorted() -> [Element] {
        return self.sorted(by: { $0.index < $1.index })
    }
}

extension Array where Element == OpenAI.Message.ToolCall {
    func sorted() -> [Element] {
        guard first?.index != nil else { return self }
        return self.sorted(by: { $0.index! < $1.index! }) // assume that if an index exists it exists for all tool calls
    }
}
