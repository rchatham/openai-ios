# OpenAI.swift

## Check out [LangTools.swift](https://github.com/rchatham/LangTools.swift) for updated implementations for the OpenAI and Anthropic APIs. 

⚠️_**DEPRECATED:**_⚠️

The smallest OpenAI API implementation written in Swift. 

This package provides a simple Swift interface for interacting with OpenAI's Chat API, with full support for functions.


## Features

- Support for various OpenAI models including GPT-3.5 and GPT-4.
- Handling both regular and streaming API requests.
- Built-in error handling and response parsing.
- Accepts closures for functions.
    - Streaming functions.
    - Multiple/Parrellel functions.

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 5+

## Installation

Include the following dependency in your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/rchatham/OpenAI.swift.git", branch: "main")
]
```

## Usage

The best way to learn how it works is to run the OpenAIDemo in XCode! Take a look at the implementation in [MessageService.swift](https://github.com/rchatham/OpenAI.swift/blob/main/OpenAIDemo/Message/MessageService.swift).

### Initializing the Client

```swift
let openAIClient = OpenAI(apiKey: "your-api-key")
```

### Performing a Chat Completion Request

```swift
let chatRequest = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: [ /* Your messages here */ ],
    /* Other optional parameters */
)

// Using async/await
// Non-streaming - stream is set to false regardless of request config
let response = try await openAIClient.perform(request: request)

// Streaming - returns message as streamed or not depending on request config
for try await response in try openAIClient.stream(request: request) {
    
    // handle non-streaming messages
    if let message = response.choices.first?.message {
        print("message received: \(message)")
    }

    // handle stream messages
    if let delta = response.choices.first?.delta {
        if let chunk = delta.content {
            content += chunk
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
    }
}

// Using completion handler
openAIClient.perform(request: chatRequest) { result in
    switch result {
    case .success(let response):
        print(response)
    case .failure(let err):
        print(err.localizedDescription)
    }
}
```

### Implementation Steps for Using Functions

#### Define the Function Schema

Before using a function in a chat completion request, define its schema. This includes the function name, description, and parameters. Here's an example for a hypothetical `getCurrentWeather` function:

```swift
let getCurrentWeatherFunction = OpenAI.Tool.FunctionSchema(
    name: "getCurrentWeather",
    description: "Get the current weather for a specified location.",
    parameters: .init(
        properties: [
            "location": .init(
                type: "string",
                description: "The city and state, e.g., San Francisco, CA"
            ),
            "format": .init(
                type: "string",
                enumValues: ["celsius", "fahrenheit"],
                description: "The temperature unit to use."
            )
        ],
        required: ["location", "format"]),
    callback: { [weak self] in
        // Run your custom function logic here.
        self?.functionThatReturnsCurrentWeather(location: $0["location"] as! String, format: $0["format"] as! String)
    })
)
```

Now add your functions to the tools array on the ChatCompletionRequest. That's it! This works for streaming, and even works with multiple functions. Don't bother parsing the function parameters, it is handled for you.

### Handling Image Content in Array Messages
When dealing with messages that contain arrays of content, including image content, follow these steps to handle them appropriately in your OpenAI.swift client implementation.

#### Step 1: Create Messages with Image Content
```swift
let imageMessage = OpenAI.Message(
    role: .user, 
    content: .array([
        .image(.init(
            image_url: .init(
                url: "https://example.com/image.jpg",
                detail: .high
            )
        ))
    ])
)
```

#### Step 2: Include Image Messages in the Chat Request
```swift
let chatRequest = OpenAI.ChatCompletionRequest(
    model: .gpt4,
    messages: [imageMessage, /* other messages here */],
    /* Other optional parameters */
)
```

---

## Contributing

Contributions are welcome. Please open an issue or submit a pull request with your changes.

## TODO

- [x] Use async/await
- [x] Pass closures for function calling
    - [ ] Verfiy parameters using JsonSchema
    - [ ] Codable paramter objects
    - [ ] Allow typed parameters?
    - [ ] Allow configuration of subsequent requests after a function call
- [x] Call OpenAI functions without returning intermediate tool message to dev
    - [ ] Optionally return intermediate tool message to devs
- [ ] Implement Assistants endpoint
- [ ] Implement other api endpoints

## License

This project is free to use under the [MIT LICENSE](LICENSE).

The other guys:
- https://github.com/MacPaw/OpenAI
- https://github.com/adamrushy/OpenAISwift
- https://github.com/OpenDive/OpenAIKit
- https://github.com/dylanshine/openai-kit
- https://github.com/SwiftBeta/SwiftOpenAI
