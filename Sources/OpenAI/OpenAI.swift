//
//  OpenAI.swift
//  OpenAI
//
//  Created by Reid Chatham on 3/9/23.
//

import Foundation


public class OpenAI {
    let baseURL: URL = URL(string: "https://api.openai.com/v1/")!
    let apiKey: String

    private lazy var session: URLSession = URLSession(configuration: .default, delegate: streamManager, delegateQueue: nil)
    private lazy var streamManager: StreamSessionManager = StreamSessionManager()

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    internal func configure(testURLSessionConfiguration: URLSessionConfiguration) -> Self {
        session = URLSession(configuration: testURLSessionConfiguration, delegate: streamManager, delegateQueue: nil)
        return self
    }

    public func perform<Request: OpenAIRequest>(request: Request, completion: @escaping (Result<Request.Response, Error>) -> Void, didCompleteStreaming: ((Error?) -> Void)? = nil) {
        Task {
            if request.stream { do { for try await response in stream(request: request) { completion(.success(response)) }; didCompleteStreaming?(nil) } catch { didCompleteStreaming?(error) }}
            else { do { completion(.success(try await perform(request: request))) } catch { completion(.failure(error)) }}
        }
    }

    // In order to call the function completion in non-streaming calls, we are unable to return the intermediate call and thus you can not mix responding to functions in your code AND using function closures. If this functionality is needed use streaming. This functionality may be able to be added via a configuration callback on the function or request in the future.
    public func perform<Request: OpenAIRequest>(request: Request, reconfigureCompletionRequest reconfig: @escaping (Request) -> Request? = { return $0 }) async throws -> Request.Response {
        let response: Request.Response = try await perform(request: try configure(request: request, stream: false))
        return try await (request as? ChatCompletionRequest)?.completion(response: response as! OpenAI.ChatCompletionResponse).flatMap { reconfig($0 as! Request) }.flatMap { try await perform(request: $0) } ?? response
    }

    public func stream<Request: OpenAIRequest>(request: Request, reconfigureCompletionRequest reconfig: @escaping (Request) -> Request? = { return $0 }) -> AsyncThrowingStream<Request.Response, Error> {
        if request.stream, request is ChatCompletionRequest, var chatReq: ChatCompletionRequest? = request as? ChatCompletionRequest { // Not allowed when type 'Request' constrained to non-protocol, non-class type 'any OpenAIRequest & StreamableRequest'
            let httpRequest: URLRequest; do { httpRequest = try configure(request: request) } catch { return AsyncThrowingStream { $0.finish(throwing: error) }}
            return streamManager.stream(task: session.dataTask(with: httpRequest)) {
                chatReq = try chatReq?.completion(response: $0).flatMap { reconfig($0 as! Request) } as? ChatCompletionRequest
                return try chatReq.flatMap { self.session.dataTask(with: try self.configure(request: $0)) }
            }
        }
        else { return AsyncThrowingStream { cont in Task { cont.yield(try await perform(request: request)); cont.finish() }}}
    }

    private func perform<Response: Decodable>(request: URLRequest) async -> Result<Response, Error> {
        do { return .success(try await perform(request: request)) } catch { return .failure(error) }
    }

    private func perform<Response: Decodable>(request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw OpenAIError.requestFailed(nil) }
        guard httpResponse.statusCode == 200 else { throw OpenAIError.responseUnsuccessful(statusCode: httpResponse.statusCode, OpenAI.decodeError(data: data)) }
        return try OpenAI.decodeResponse(data: data)
    }

    private func prepareRequest(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func configure<Request: OpenAIRequest>(request: Request, stream: Bool? = nil) throws -> URLRequest {
        var httpRequest = prepareRequest(path: Request.path)
        do { httpRequest.httpBody = try JSONEncoder().encode(request.updating(stream: stream ?? request.stream)) } catch { throw OpenAIError.invalidData }
        return httpRequest
    }

    internal class StreamSessionManager: NSObject, URLSessionDataDelegate {
        private var task: URLSessionDataTask?
        private var didReceiveEvent: ((Data) -> Void)?
        private var didCompleteStream: ((Error?) -> Void)?
        private var completion: (([Data]) throws -> URLSessionDataTask?)?
        private var data: [Data] = []

        func stream<StreamResponse: StreamableResponse, Response: Decodable>(task: URLSessionDataTask, completion: @escaping (StreamResponse) throws -> URLSessionDataTask?) -> AsyncThrowingStream<Response, Error> {
            self.completion = { return try completion(try StreamSessionManager.response(from: $0)) }
            return AsyncThrowingStream { continuation in
                didReceiveEvent = { continuation.yield(with: OpenAI.decode(data: $0)) }
                didCompleteStream = { continuation.finish(throwing: $0) }
                continuation.onTermination = { @Sendable _ in (self.task, self.didReceiveEvent, self.didCompleteStream, self.completion, self.data) = (nil, nil, nil, nil, []) }
                self.task = task; task.resume()
            }
        }

        internal func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if let error = decodeError(data: data) { return didCompleteStream?(error) ?? () }
            guard let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") else { return }
            for line in lines where line.hasPrefix("data:") {
                if !line.contains("[DONE]") {
                    let data = Data(String(line.dropFirst(5)).utf8)
                    self.data.append(data)
                    didReceiveEvent?(data)
                }
            }
        }

        internal func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            var error = error; if error == nil { do {
                if !data.isEmpty, let task = try completion?(data) {
                    data = []; self.task = task; task.resume(); return /* if new task is returned do not call didCompleteStream */
                }
            } catch let err { error = err } }
            didCompleteStream?(error)
        }

        private static func response<Response: StreamableResponse>(from data: [Data]) throws -> Response {
            return try data.compactMap { try OpenAI.decodeResponse(data: $0) }.reduce(Response.empty) { $0.combining(with: $1) }
        }
    }
}

public protocol OpenAIRequest: Encodable {
    associatedtype Response: Decodable
    static var path: String { get }
}

extension OpenAIRequest {
    var stream: Bool {
        get { return (self as? (any StreamableRequest))?.stream ?? false }
    }

    func updating(stream: Bool) -> Self {
        if var streamReq = (self as? (any StreamableRequest)) {
            streamReq.stream = stream
            return (streamReq as! Self)
        }
        return self
    }
}

internal protocol StreamableRequest: Encodable {
    associatedtype Response: StreamableResponse
    var stream: Bool? { get set }
}

internal protocol StreamableResponse: Decodable {
    static var empty: Self { get }
    func combining(with: Self) -> Self
}

internal protocol CompletableRequest: Encodable {
    associatedtype Response: Decodable
    func completion(response: Response) throws -> Self?
}

public enum OpenAIError: Error {
    case invalidData, streamParsingFailure, invalidURL
    case requestFailed(Error?)
    case jsonParsingFailure(Error)
    case responseUnsuccessful(statusCode: Int, Error?)
    case apiError(ErrorResponse)

    public struct ErrorResponse: Error, Codable {
        public let error: APIError
    }

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

// Helpers
public extension OpenAI {
    static func decode<Response: Decodable>(completion: @escaping (Result<Response, Error>) -> Void) -> (Data) -> Void { return { completion(decode(data: $0)) }}
    static func decode<Response: Decodable>(data: Data) -> Result<Response, Error> { let d = JSONDecoder(); do { return .success(try decodeResponse(data: data, decoder: d)) } catch { return .failure(error as! OpenAIError) }}
    static func decodeResponse<Response: Decodable>(data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> Response { do { return try decoder.decode(Response.self, from: data) } catch { throw decodeError(data: data, decoder: decoder) ?? .jsonParsingFailure(error) }}
    static func decodeError(data: Data, decoder: JSONDecoder = JSONDecoder()) -> OpenAIError? { return (try? decoder.decode(OpenAIError.ErrorResponse.self, from: data)).flatMap { .apiError($0) }}
}

extension String {
    var dictionary: [String:Any]? { return data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String:Any] }}
    var stringDictionary: [String:String]? { return data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String:String] }}
}

extension Optional { func flatMap<U>(_ a: (Wrapped) async throws -> U?) async throws -> U? { switch self { case .some(let wrapped): return try await a(wrapped); case .none: return nil }}}

