//
//  OpenAI.swift
//  OpenAI
//
//  Created by Reid Chatham on 3/9/23.
//

import Foundation
import LangTools


final public class OpenAI: LangTools {

    public typealias ErrorResponse = OpenAIErrorResponse
    typealias OpenAIError = LangToolError<OpenAIErrorResponse>

    static let baseURL: URL = URL(string: "https://api.openai.com/v1/")!
    private let apiKey: String

    public private(set) lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    public private(set) lazy var streamManager: StreamSessionManager = StreamSessionManager<OpenAI>()

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: streamManager, delegateQueue: nil)
        return self
    }

    public func perform<Request: LangToolRequest>(request: Request, completion: @escaping (Result<Request.Response, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        Task {
            if request.stream, let request = request as? ChatCompletionRequest { do { for try await response in stream(request: request) { completion(.success(response as! Request.Response)) }; didCompleteStreaming?(nil) } catch { didCompleteStreaming?(error) }}
            else { do { completion(.success(try await perform(request: request))) } catch { completion(.failure(error)) }}
        }
    }

    public func completionRequest<Request: LangToolRequest>(request: Request, response: Request.Response) throws -> Request? {
        return try (request as? ChatCompletionRequest)?.completion(response: response as! ChatCompletionResponse) as? Request
    }

    public func prepare<Request: LangToolRequest>(request: Request) throws -> URLRequest {
        var urlRequest = URLRequest(url: Request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do { urlRequest.httpBody = try JSONEncoder().encode(request) } catch { throw LangToolError<ErrorResponse>.invalidData }
        return urlRequest
    }

    public static func processStream(data: Data, completion: @escaping (Data) -> Void) {
        String(data: data, encoding: .utf8)?.split(separator: "\n").filter{ $0.hasPrefix("data:") && !$0.contains("[DONE]") }.forEach { completion(Data(String($0.dropFirst(5)).utf8)) }
    }
}

public struct OpenAIErrorResponse: Error, Codable {
    public let error: APIError

    public struct APIError: Error, Codable {
        public let message: String
        public let type: String
        public let param: String?
        public let code: String?
    }
}

public extension OpenAI {
    enum Model: String, Codable, CaseIterable {
        case gpt35_turbo = "gpt-3.5-turbo"
        case gpt35_turbo_0301 = "gpt-3.5-turbo-0301"
        case gpt35_turbo_1106 = "gpt-3.5-turbo-1106"
        case gpt35_turbo_16k = "gpt-3.5-turbo-16k"
        case gpt35_turbo_instruct = "gpt-3.5-turbo-instruct"
        case gpt4 = "gpt-4"
        case gpt4_0613 = "gpt-4-0613"
        case gpt4_0314 = "gpt-4-0314"
        case gpt4_turbo = "gpt-4-turbo"
        case gpt4_turbo_preview = "gpt-4-turbo-preview"
        case gpt4_turbo_2024_04_09 = "gpt-4-turbo-2024-04-09"
        case gpt4_turbo_0125_preview = "gpt-4-0125-preview"
        case gpt4_turbo_1106_preview = "gpt-4-1106-preview"
        case gpt4_32k = "gpt-4-32k"
        case gpt4_32k_0613 = "gpt-4-32k-0613"
        case gpt4o = "gpt-4o"
        case gpt4o_2024_05_13 = "gpt-4o-2024-05-13"
        case gpt4o_2024_08_06 = "gpt-4o-2024-08-06"
        case chatgpt_4o_latest = "chatgpt-4o-latest"
        case gpt4o_mini = "gpt-4o-mini"
        case gpt4o_mini_2024_07_18 = "gpt-4o-mini-2024-07-18"
        case o1_preview	 = "o1-preview"
        case o1_preview_2024_09_12 = "o1-preview-2024-09-12"
        case o1_mini = "o1-mini"
        case o1_mini_2024_09_12 = "o1-mini-2024-09-12"
    }
}
