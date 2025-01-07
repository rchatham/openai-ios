import Foundation


public extension OpenAI {
    struct Message: Codable, CustomStringConvertible {
        public let role: Role
        public let content: Content
        public let name: String?
        public let tool_calls: [ToolCall]?
        public let tool_call_id: String?

        public var description: String {
            let tools: String? = tool_calls?.reduce("") {
                let name = $1.function.name ?? ""
                return $0.isEmpty ? (name) : ($0 + "," + name)
            }
            return """
                message info:
                  role: \(role)
                  content: \(content)
                  name: \(name ?? "")
                  tool_calls: \(tools ?? "")
                  tool_call_id: \(tool_call_id ?? "")
                """
        }
        
        public init(role: Role, content: String) {
            self.role = role
            self.content = .string(content)
            self.name = nil
            self.tool_calls = nil
            self.tool_call_id = nil
        }
        
        public init(role: Role, content: Content, name: String? = nil, tool_calls: [ToolCall]? = nil, tool_call_id: String? = nil) throws {
            switch role {
            case .user: if case .null = content { throw MessageError.missingContent }
            case .tool: guard tool_call_id != nil else { throw MessageError.missingContent }; fallthrough
            case .system, .assistant: guard content.description == "null" || content.description.hasPrefix("string: ") else { throw MessageError.invalidContent }
            }

            if role != .assistant, let tool_calls = tool_calls {
                print("\(role.rawValue.capitalized) is not able to use tool calls: \(tool_calls.description). Please check your configuration, only assistant messages are allowed to contain tool calls")
            }
            if role != .tool, let tool_call_id = tool_call_id {
                print("\(role.rawValue.capitalized) can not have tool_call_id: \(tool_call_id). Please check your configuration, only tool meesages may have a tool_call_id.")
            }

            self.role = role
            self.content = content
            self.name = name
            self.tool_calls = role == .assistant ? tool_calls : nil
            self.tool_call_id = role == .tool ? tool_call_id : nil
        }
        
        public enum Role: String, Codable {
            case system, user, assistant, tool
        }
        
        public enum Content: Codable, CustomStringConvertible {
            case null
            case string(String)
            case array([ContentType])

            public var description: String {
                switch self {
                case .null: return "null"
                case .string(let str): return "string: \(str)"
                case .array(let arr): return "array: \(arr)"
                }
            }

            public var string: String? {
                if case .string(let str) = self { return str } else { return nil }
            }

            public enum ContentType: Codable, CustomStringConvertible {
                case text(TextContent)
                case image(ImageContent)

                public var description: String {
                    switch self {
                    case .text(let txt): return "text: \(txt.text)"
                    case .image(let img): return "image: \(img.image_url)"
                    }
                }
                
                public var type: String {
                    switch self {
                    case .image(let img): return img.type
                    case .text(let txt): return txt.type
                    }
                }
                
                public init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let text = try? container.decode(TextContent.self) { self = .text(text) }
                    else if let img = try? container.decode(ImageContent.self) { self = .image(img) }
                    else { throw DecodingError.typeMismatch(ContentType.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown content type")) }
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.singleValueContainer()
                    switch self {
                    case .text(let txt): try container.encode(txt)
                    case .image(let img): try container.encode(img)
                    }
                }
            }
            
            public struct TextContent: Codable {
                var type: String = "text"
                public let text: String
                public init(text: String) {
                    self.text = text
                }
            }

            public struct ImageContent: Codable {
                var type: String = "image_url"
                public let image_url: ImageURL
                public init(image_url: ImageURL) {
                    self.image_url = image_url
                }
                
                public struct ImageURL: Codable {
                    public let url: String
                    public let detail: Detail?
                    public init(url: String, detail: Detail? = nil) {
                        self.url = url
                        self.detail = detail
                    }
                }
                public enum Detail: String, Codable {
                    case auto, high, low
                }
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let str = try? container.decode(String.self) { self = .string(str) }
                else if let arr = try? container.decode([ContentType].self) { self = .array(arr) }
                else if container.decodeNil() { self = .null }
                else { throw DecodingError.typeMismatch(Content.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown content type")) }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .string(let txt): try container.encode(txt)
                case .array(let array): try container.encode(array)
                case .null: try container.encodeNil()
                }
            }
        }

        public enum MessageError: Error {
            case invalidRole, missingContent, invalidContent
        }

        public struct Delta: Codable {
            public let role: Role?
            public let content: String?
            public let tool_calls: [ToolCall]?
        }

        public struct ToolCall: Codable, CustomStringConvertible {
            public let index: Int?
            public let id: String?
            public let type: ToolType?
            public let function: Function

            public var description: String {
                return """
                tool call:
                  index:    \(index != nil ? "\(index!)" : "no index")
                  id:       \(id ?? "no idea")
                  type:     \(type?.rawValue ?? "no type")
                  function: \(function.name ?? "name missing"): \(function.arguments)
                """
            }

            public init(index: Int, id: String, type: ToolType, function: Function) {
                self.index = index
                self.id = id
                self.type = type
                self.function = function
            }

            public enum ToolType: String, Codable {
                case function
            }

            public struct Function: Codable {
                public let name: String?
                public let arguments: String
                public init(name: String, arguments: String) {
                    self.name = name
                    self.arguments = arguments
                }
            }
        }
    }
}
