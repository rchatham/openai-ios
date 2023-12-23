//
//  MessageService.swift
//  OpenAI
//
//  Created by Reid Chatham on 3/31/23.
//

import Foundation
import OpenAI_Swift

class MessageService {
    let networkClient: NetworkClient
    let messageDB: MessageDB
    
    init(networkClient: NetworkClient = NetworkClient(), messageDB: MessageDB) {
        self.networkClient = networkClient
        self.messageDB = messageDB
    }

    var tools: [OpenAI.ChatCompletionRequest.Tool]? {
        return [
            .function(.init(
                name: "getCurrentWeather",
                description: "Get the current weather",
                parameters: .init(
                    properties: [
                        "location": .init(
                            type: "string",
                            description: "The city and state, e.g. San Francisco, CA"),
                        "format": .init(
                            type: "string",
                            enumValues: ["celsius", "fahrenheit"],
                            description: "The temperature unit to use. Infer this from the users location.")
                    ],
                    required: ["location", "format"]))),
            .function(.init(
                name: "getAnswerToUniverse",
                description: "The answer to the universe, life, and everything.",
                parameters: .init()))
        ]
    }
    
    func sendMessageCompletionRequest(message: String, for conversation: Conversation, stream: Bool = false) {
        messageDB.createMessage(for: conversation, content: message)
        getChatCompletion(for: conversation, stream: stream)
    }

    func getChatCompletion(for conversation: Conversation, stream: Bool) {
        class StreamMessageInfo {
            var id: UUID
            var content = "" // Update to accept OpenAI.Message.Content
            private let messageDB: MessageDB
            init(for conversation: Conversation, using messageDB: MessageDB) {
                id = messageDB.createMessage(for: conversation, content: "", role: .assistant).id! // is it more efficient to hold onto the message?
                self.messageDB = messageDB
            }
            func append(chunk: OpenAI.Message.Content) {
                if case .string(let str) = chunk {
                    print("chunk received: " + str)
                    content += str
                    messageDB.updateMessage(id: id, content: content)
                } else {
                    print("handle other cases")
                }
            }
            func add(toolCalls: [OpenAI.Message.ToolCall]) {
                messageDB.updateMessage(id: id, toolCalls: toolCalls.map { messageDB.createToolCall(from: $0)})
            }
        }
        var streamMessageInfo: StreamMessageInfo?

        class StreamToolInfo {
            var tools: [OpenAI.Message.ToolCall]
            init(toolCallCount: Int) {
                tools = Array(repeating: .init(index: 0, id: "", type: .function, function: .init(name: "", arguments: "")), count: toolCallCount)
            }
        }
        var streamToolInfo: StreamToolInfo?
        let toolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto
        networkClient.sendChatCompletionRequest(messages: conversation.toOpenAIMessages(), stream: stream, tools: tools, toolChoice: toolChoice) { [conversation] (result: Result<OpenAI.ChatCompletionResponse, Error>) in
            switch result {
            case .success(let response):
                if let message = response.choices.first?.message {
                    DispatchQueue.main.async { [weak self] in
                        print("message received: \(message)")
                        self?.messageDB.createMessage(from: message)
                    }
                }
                if let delta = response.choices.first?.delta {
                    DispatchQueue.main.async { [weak self] in
                        if delta.role == .assistant, let messageDB = self?.messageDB
                        { streamMessageInfo = StreamMessageInfo(for: conversation, using: messageDB)}
                        if let chunk = delta.content { streamMessageInfo?.append(chunk: .string(chunk))}
                    }
                }
                if let toolCalls = response.choices.first?.message?.tool_calls ?? response.choices.first?.delta?.tool_calls {
                    DispatchQueue.main.async {
                        if streamToolInfo == nil { streamToolInfo = StreamToolInfo(toolCallCount: toolCalls.count) }
                        guard let toolInfo = streamToolInfo else { fatalError() }
                        for tool in toolCalls {
                            toolInfo.tools[tool.index] = OpenAI.Message.ToolCall(
                                index: tool.index,
                                id: tool.id ?? toolInfo.tools[tool.index].id ?? "",
                                type: .function,
                                function: OpenAI.Message.ToolCall.Function(
                                    name: tool.function.name ?? toolInfo.tools[tool.index].function.name ?? "",
                                    arguments: toolInfo.tools[tool.index].function.arguments + tool.function.arguments))
                            print((toolInfo.tools[tool.index].function.name ?? "") + ": " + toolInfo.tools[tool.index].function.arguments)
                        }
                    }
                }
                if let finishReason = response.choices.first?.finish_reason {
                    DispatchQueue.main.async { [weak self] in
                        switch finishReason {
                        case .tool_calls:
                            guard let toolCalls = streamToolInfo?.tools else { return }
                            streamMessageInfo?.add(toolCalls: toolCalls)
                            for tool in toolCalls {
                                print("utilizing tool: \(tool)")
                                guard let toolText = self?.useTool(tool) else { return }
                                self?.messageDB.createToolMessage(for: conversation, content: toolText, toolCallId: tool.id!, name: tool.function.name!)
                                self?.getChatCompletion(for: conversation, stream: stream)
                            }
                        case .stop:
                            guard let content = streamMessageInfo?.content, !content.isEmpty else { return }
                            print("message received: \(content)")
                        case .length, .content_filter: break
                        }
                    }
                }
            case .failure(let error): print(error.localizedDescription)
            }
        } streamCompletion: { error in
            DispatchQueue.main.async {
                if let error = error {
                    print("error: \(error)")
                } else {
                    print(error ?? streamMessageInfo?.content ?? "No output")
                }
            }
        }
    }

    func deleteMessage(id: UUID) {
        messageDB.deleteMessage(id: id)
    }

    func useTool(_ tool: OpenAI.Message.ToolCall) -> String? {
        print("utilize tools")
        let args = tool.function.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: []) as? [String:String] }

        if tool.function.name == "getCurrentWeather" {
            if let location = args?["location"], let format = args?["format"] {
                return getCurrentWeather(location: location, format: format)
            } else {
                print("failed to decode function parameters")
            }
        }
        if tool.function.name == "getAnswerToUniverse" {
            return "42"
        }
        return nil
    }

    @objc func getCurrentWeather(location: String, format: String) -> String {
        return "27"
    }
}
