//
//  MessageService.swift
//  OpenAI
//
//  Created by Reid Chatham on 3/31/23.
//

import Foundation
import OpenAI

class MessageService {
    let networkClient: NetworkClient
    let messageDB: MessageDB
    
    init(networkClient: NetworkClient = NetworkClient(), messageDB: MessageDB) {
        self.networkClient = networkClient
        self.messageDB = messageDB
    }

    var tools: [OpenAI.Tool]? {
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
                    required: ["location", "format"]),
                callback: { [weak self] in
                    self?.getCurrentWeather(location: $0["location"] as! String, format: $0["format"] as! String)
                })),
            .function(.init(
                name: "getAnswerToUniverse",
                description: "The answer to the universe, life, and everything.",
                parameters: .init(),
                callback: { _ in
                    "42"
                })),
            .function(.init(
                name: "getTopMichelinStarredRestaurants",
                description: "Get the top Michelin starred restaurants near a location",
                parameters: .init(
                    properties: [
                        "location": .init(
                            type: "string",
                            description: "The city and state, e.g. San Francisco, CA")
                    ],
                    required: ["location"]),
                callback: { [weak self] in
                    self?.getTopMichelinStarredRestaurants(location: $0["location"] as! String)
                }))
        ]
    }

    func performMessageCompletionRequest(message: String, for conversation: Conversation, stream: Bool = false) async throws {
        await messageDB.createMessage(for: conversation, content: message)
        do {
            try await getChatCompletion(for: conversation, stream: stream)
        } catch let error as OpenAIError {
            switch error {
            case .jsonParsingFailure(let error): print("error: json parsing error: \(error.localizedDescription)")
            case .apiError(let error): print("error: openai api error: \(error.error)")
            case .invalidData: print("error: invalid data")
            case .invalidURL: print("error: invalid url")
            case .requestFailed(let error): print("error: request failed with error: \(error?.localizedDescription ?? "no error")")
            case .responseUnsuccessful(statusCode: let code, let error): print("error: unsuccessful status code: \(code), error: \(error?.localizedDescription ?? "no error")")
            case .streamParsingFailure: print("error: stream parsing failure")
            }
        } catch let error as OpenAI.ChatCompletionError {
            switch error {
            case .failedToDecodeFunctionArguments: print("error: failed to decode function args")
            case .missingRequiredFunctionArguments: print("error: missing args")
            case .missingToolCallResponse: print("error: missing tool call response from developer")
            }
        } catch {
            fatalError("error: " + error.localizedDescription)
        }
    }

    func getChatCompletion(for conversation: Conversation, stream: Bool) async throws {
        var id: UUID?
        var content = ""

        let toolChoice = (tools?.isEmpty ?? true) ? nil : OpenAI.ChatCompletionRequest.ToolChoice.auto

        for try await response in try networkClient.streamChatCompletionRequest(messages: conversation.toOpenAIMessages(), stream: stream, tools: tools, toolChoice: toolChoice) {

            // handle non-streamed messages
            if let message = response.choices.first?.message {
                print("message received: \(message)")
                id = await messageDB.createMessage(for: conversation, from: message)
            }

            // handle stream messages
            if let delta = response.choices.first?.delta {
                if id == nil { id = await messageDB.createMessage(for: conversation, content: "", role: delta.role!) }
                if let chunk = delta.content {
                    content += chunk
                    await messageDB.updateMessage(id: id!, content: content)
                }
            }

            // handle finish reason
            if let finishReason = response.choices.first?.finish_reason {
                switch finishReason {
                case .stop:
                    guard !content.isEmpty else { return }
                    print("message received: \(content)")
                case .tool_calls, .length, .content_filter: break
                }
                id = nil
            }

        }
    }

    func deleteMessage(id: UUID) {
        messageDB.deleteMessage(id: id)
    }

    @objc func getCurrentWeather(location: String, format: String) -> String {
        return "27"
    }

    func getTopMichelinStarredRestaurants(location: String) -> String {
        return "The French Laundry"
    }

}
