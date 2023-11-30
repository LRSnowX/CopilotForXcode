import Foundation
import Logger
import Preferences
import TokenEncoder

/// A memory that automatically manages the history according to max tokens and max message count.
public actor AutoManagedChatGPTMemory: ChatGPTMemory {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var remainingTokens: Int?

    public var systemPrompt: String
    public var contextSystemPrompt: String
    public var retrievedContent: [String] = []
    public var history: [ChatMessage] = [] {
        didSet { onHistoryChange() }
    }

    public var configuration: ChatGPTConfiguration
    public var functionProvider: ChatGPTFunctionProvider

    static let encoder: TokenEncoder = TiktokenCl100kBaseTokenEncoder()

    var onHistoryChange: () -> Void = {}

    public init(
        systemPrompt: String,
        configuration: ChatGPTConfiguration,
        functionProvider: ChatGPTFunctionProvider
    ) {
        self.systemPrompt = systemPrompt
        contextSystemPrompt = ""
        self.configuration = configuration
        self.functionProvider = functionProvider
        _ = Self.encoder // force pre-initialize
    }

    public func mutateHistory(_ update: (inout [ChatMessage]) -> Void) {
        update(&history)
    }

    public func mutateSystemPrompt(_ newPrompt: String) {
        systemPrompt = newPrompt
    }

    public func mutateContextSystemPrompt(_ newPrompt: String) {
        contextSystemPrompt = newPrompt
    }

    public func mutateRetrievedContent(_ newContent: [String]) {
        retrievedContent = newContent
    }

    public nonisolated
    func observeHistoryChange(_ onChange: @escaping () -> Void) {
        Task {
            await setOnHistoryChangeBlock(onChange)
        }
    }

    public func refresh() async {
        messages = generateSendingHistory()
        remainingTokens = generateRemainingTokens()
    }

    /// https://github.com/openai/openai-cookbook/blob/main/examples/How_to_count_tokens_with_tiktoken.ipynb
    ///
    /// Format:
    /// ```
    /// [System Prompt] priority: high
    /// [Functions] priority: high
    /// [Retrieved Content] priority: low
    ///     [Retrieved Content A]
    ///     <separator>
    ///     [Retrieved Content B]
    /// [Message History] priority: medium
    /// [Context System Prompt] priority: high
    /// [Latest Message] priority: high
    /// ```
    func generateSendingHistory(
        maxNumberOfMessages: Int = UserDefaults.shared.value(for: \.chatGPTMaxMessageCount),
        encoder: TokenEncoder = AutoManagedChatGPTMemory.encoder
    ) -> [ChatMessage] {
        let (
            systemPromptMessage,
            contextSystemPromptMessage,
            availableTokenCountForMessages,
            mandatoryUsage
        ) = generateMandatoryMessages(encoder: encoder)

        let (
            historyMessage,
            newMessage,
            availableTokenCountForRetrievedContent,
            messageUsage
        ) = generateMessageHistory(
            maxNumberOfMessages: maxNumberOfMessages,
            maxTokenCount: availableTokenCountForMessages,
            encoder: encoder
        )

        let (
            retrievedContentMessage,
            _,
            retrievedContentUsage,
            _
        ) = generateRetrievedContentMessage(
            maxTokenCount: availableTokenCountForRetrievedContent,
            encoder: encoder
        )

        let allMessages: [ChatMessage] = (
            [systemPromptMessage] +
                historyMessage +
                [retrievedContentMessage, contextSystemPromptMessage, newMessage]
        ).filter {
            !($0.content?.isEmpty ?? false)
        }

        #if DEBUG
        Logger.service.info("""
        Sending tokens count
        - system prompt: \(mandatoryUsage.systemPrompt)
        - context system prompt: \(mandatoryUsage.contextSystemPrompt)
        - functions: \(mandatoryUsage.functions)
        - messages: \(messageUsage)
        - retrieved content: \(retrievedContentUsage)
        - total: \(
            mandatoryUsage.systemPrompt
                + mandatoryUsage.contextSystemPrompt
                + mandatoryUsage.functions
                + messageUsage
                + retrievedContentUsage
        )
        """)
        #endif

        return allMessages
    }

    func generateRemainingTokens(
        maxNumberOfMessages: Int = UserDefaults.shared.value(for: \.chatGPTMaxMessageCount),
        encoder: TokenEncoder = AutoManagedChatGPTMemory.encoder
    ) -> Int? {
        // It should be fine to just let OpenAI decide.
        return nil
    }

    func setOnHistoryChangeBlock(_ onChange: @escaping () -> Void) {
        onHistoryChange = onChange
    }
}

extension AutoManagedChatGPTMemory {
    func generateMandatoryMessages(encoder: TokenEncoder) -> (
        systemPrompt: ChatMessage,
        contextSystemPrompt: ChatMessage,
        remainingTokenCount: Int,
        usage: (systemPrompt: Int, contextSystemPrompt: Int, functions: Int)
    ) {
        var smallestSystemPromptMessage = ChatMessage(role: .system, content: systemPrompt)
        var contextSystemPromptMessage = ChatMessage(role: .user, content: contextSystemPrompt)
        let smallestSystemMessageTokenCount = encoder.countToken(&smallestSystemPromptMessage)
        let contextSystemPromptTokenCount = !contextSystemPrompt.isEmpty
            ? encoder.countToken(&contextSystemPromptMessage)
            : 0

        let functionTokenCount = functionProvider.functions.reduce(into: 0) { partial, function in
            var count = encoder.countToken(text: function.name)
                + encoder.countToken(text: function.description)
            if let data = try? JSONEncoder().encode(function.argumentSchema),
               let string = String(data: data, encoding: .utf8)
            {
                count += encoder.countToken(text: string)
            }
            partial += count
        }
        let mandatoryContentTokensCount = smallestSystemMessageTokenCount
            + contextSystemPromptTokenCount
            + functionTokenCount
            + 3 // every reply is primed with <|start|>assistant<|message|>

        // build messages

        /// the available tokens count for other messages and retrieved content
        let availableTokenCountForMessages = configuration.maxTokens
            - configuration.minimumReplyTokens
            - mandatoryContentTokensCount

        return (
            smallestSystemPromptMessage,
            contextSystemPromptMessage,
            availableTokenCountForMessages,
            (
                smallestSystemMessageTokenCount,
                contextSystemPromptTokenCount,
                functionTokenCount
            )
        )
    }

    func generateMessageHistory(
        maxNumberOfMessages: Int,
        maxTokenCount: Int,
        encoder: TokenEncoder
    ) -> (
        history: [ChatMessage],
        newMessage: ChatMessage,
        remainingTokenCount: Int,
        usage: Int
    ) {
        var messageTokenCount = 0
        var allMessages: [ChatMessage] = []
        var newMessage: ChatMessage?

        for (index, message) in history.enumerated().reversed() {
            if maxNumberOfMessages > 0, allMessages.count >= maxNumberOfMessages { break }
            if message.isEmpty { continue }
            let tokensCount = encoder.countToken(&history[index])
            if tokensCount + messageTokenCount > maxTokenCount { break }
            messageTokenCount += tokensCount
            if index == history.endIndex - 1 {
                newMessage = message
            } else {
                allMessages.append(message)
            }
        }

        return (
            allMessages.reversed(),
            newMessage ?? .init(role: .user, content: ""),
            maxTokenCount - messageTokenCount,
            messageTokenCount
        )
    }

    func generateRetrievedContentMessage(
        maxTokenCount: Int,
        encoder: TokenEncoder
    ) -> (
        retrievedContent: ChatMessage,
        remainingTokenCount: Int,
        usage: Int,
        includedRetrievedContent: [String]
    ) {
        var retrievedContentTokenCount = 0
        let separator = String(repeating: "=", count: 32) // only 1 token
        var message = ""
        var includedRetrievedContent = [String]()

        func appendToMessage(_ text: String) -> Bool {
            let tokensCount = encoder.countToken(text: text)
            if tokensCount + retrievedContentTokenCount > maxTokenCount { return false }
            retrievedContentTokenCount += tokensCount
            message += text
            includedRetrievedContent.append(text)
            return true
        }

        for (index, content) in retrievedContent.filter({ !$0.isEmpty }).enumerated() {
            if index == 0 {
                if !appendToMessage("""


                ## Relevant Content

                Below are information related to the conversation, separated by \(separator)


                """) { break }
            } else {
                if !appendToMessage("\n\(separator)\n") { break }
            }

            if !appendToMessage(content) { break }
        }

        return (
            .init(role: .user, content: message),
            maxTokenCount - retrievedContentTokenCount,
            retrievedContentTokenCount,
            includedRetrievedContent
        )
    }
}

extension TokenEncoder {
    /// https://github.com/openai/openai-cookbook/blob/main/examples/How_to_count_tokens_with_tiktoken.ipynb
    func countToken(message: ChatMessage) -> Int {
        var total = 3
        if let content = message.content {
            total += encode(text: content).count
        }
        if let name = message.name {
            total += encode(text: name).count
            total += 1
        }
        if let functionCall = message.functionCall {
            total += encode(text: functionCall.name).count
            total += encode(text: functionCall.arguments).count
        }
        return total
    }

    func countToken(_ message: inout ChatMessage) -> Int {
        if let count = message.tokensCount { return count }
        let count = countToken(message: message)
        message.tokensCount = count
        return count
    }
}

