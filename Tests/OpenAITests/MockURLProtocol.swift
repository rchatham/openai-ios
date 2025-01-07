//
//  MockURLProtocol.swift
//  OpenAI-SwiftTests
//
//  Created by Reid Chatham on 12/30/23.
//

import Foundation
import LangTools
@testable import OpenAI

class MockURLProtocol: URLProtocol {
    typealias MockNetworkHandler = (URLRequest) throws -> (result: Result<Data, Error>, statusCode: Int?)
    public static var mockNetworkHandlers: [String: MockNetworkHandler] = [:]

    override class func canInit(with request: URLRequest) -> Bool { mockNetworkHandlers[request.endpoint] != nil }
    override class func canInit(with task: URLSessionTask) -> Bool { mockNetworkHandlers[task.endpoint] != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = try! MockURLProtocol.mockNetworkHandlers.removeValue(forKey: request.endpoint)!(request)

        if let statusCode = response.statusCode {
            let httpURLResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            self.client?.urlProtocol(
                 self,
                 didReceive: httpURLResponse,
                 cacheStoragePolicy: .notAllowed
            )
        }

        switch response.result {
        case let .success(data):
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)

        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}

}

extension URL {
    var endpoint: String { pathComponents[2...].joined(separator: "/") }
}

extension URLRequest {
    var endpoint: String { url!.endpoint }
}

extension URLSessionTask {
    var endpoint: String { currentRequest!.endpoint }
}

struct MockRequest: LangToolRequest, StreamableLangToolRequest, Encodable {
    static var url: URL { URL(filePath: "test") }
    static var path: String { url.endpoint }
    typealias Response = MockResponse
    var stream: Bool?
    init(stream: Bool? = nil) { self.stream = stream }
    func completion(response: MockResponse) throws -> MockRequest? { return nil }
}

struct MockResponse: Codable, StreamableLangToolResponse {
    var status: String
    func combining(with next: MockResponse) -> MockResponse { return next }
    static var empty: MockResponse { MockResponse(status: "") }
    static var success: MockResponse { MockResponse(status: "success") }
}
