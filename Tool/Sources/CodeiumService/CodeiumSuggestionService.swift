import CopilotForXcodeKit
import Foundation
import SuggestionModel
import Workspace

class CodeiumSuggestionService: SuggestionServiceType {
    var configuration: SuggestionServiceConfiguration {
        .init(
            acceptsRelevantCodeSnippets: true,
            mixRelevantCodeSnippetsInSource: true,
            acceptsRelevantSnippetsFromOpenedFiles: false
        )
    }

    let serviceLocator: ServiceLocator

    init(serviceLocator: ServiceLocator) {
        self.serviceLocator = serviceLocator
    }

    func getSuggestions(
        _ request: SuggestionRequest,
        workspace: WorkspaceInfo
    ) async throws -> [CopilotForXcodeKit.CodeSuggestion] {
        guard let service = await serviceLocator.getService(from: workspace) else { return [] }
        return try await service.getCompletions(
            fileURL: request.fileURL,
            content: request.content,
            cursorPosition: .init(
                line: request.cursorPosition.line,
                character: request.cursorPosition.character
            ),
            tabSize: request.tabSize,
            indentSize: request.indentSize,
            usesTabsForIndentation: request.usesTabsForIndentation
        ).map(Self.convert)
    }

    func notifyAccepted(
        _ suggestion: CopilotForXcodeKit.CodeSuggestion,
        workspace: WorkspaceInfo
    ) async {
        guard let service = await serviceLocator.getService(from: workspace) else { return }
        await service.notifyAccepted(Self.convert(suggestion))
    }

    func notifyRejected(
        _ suggestions: [CopilotForXcodeKit.CodeSuggestion],
        workspace: WorkspaceInfo
    ) async {
        // unimplemented
    }

    func cancelRequest(workspace: WorkspaceInfo) async {
        guard let service = await serviceLocator.getService(from: workspace) else { return }
        await service.cancelRequest()
    }

    static func convert(
        _ suggestion: SuggestionModel.CodeSuggestion
    ) -> CopilotForXcodeKit.CodeSuggestion {
        .init(
            id: suggestion.id,
            text: suggestion.text,
            position: .init(
                line: suggestion.position.line,
                character: suggestion.position.character
            ),
            range: .init(
                start: .init(
                    line: suggestion.range.start.line,
                    character: suggestion.range.start.character
                ),
                end: .init(
                    line: suggestion.range.end.line,
                    character: suggestion.range.end.character
                )
            )
        )
    }

    static func convert(
        _ suggestion: CopilotForXcodeKit.CodeSuggestion
    ) -> SuggestionModel.CodeSuggestion {
        .init(
            id: suggestion.id,
            text: suggestion.text,
            position: .init(
                line: suggestion.position.line,
                character: suggestion.position.character
            ),
            range: .init(
                start: .init(
                    line: suggestion.range.start.line,
                    character: suggestion.range.start.character
                ),
                end: .init(
                    line: suggestion.range.end.line,
                    character: suggestion.range.end.character
                )
            )
        )
    }
}

