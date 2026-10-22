//
//  MarkdownFormatAvailabilityTests.swift
//  PageFlowTests
//
//  The toolbar's and Format menu's block commands show disabled where they
//  can't apply, instead of doing nothing when clicked.
//

import Foundation
import MarkdownEngine
import Testing
@testable import PageFlow

@MainActor
struct MarkdownFormatAvailabilityTests {
    @Test
    func blockCommandsAreDisabledInATableCellAndInCode() {
        let content = MarkdownContent(documentId: UUID().uuidString)
        #expect(MarkdownFormatCommand.allCases.allSatisfy { content.isFormatEnabled($0) }, "in text, everything applies")
        content.formatState.inTableCell = true
        #expect(!content.isFormatEnabled(.checklist) && !content.isFormatEnabled(.table) && !content.isFormatEnabled(.heading))
        #expect(content.isFormatEnabled(.bold) && content.isFormatEnabled(.link), "marks still apply to a cell's text")
        content.formatState = MarkdownFormatState()
        content.formatState.context = .codeBlock
        #expect(!content.isFormatEnabled(.checklist) && !content.isFormatEnabled(.bulletedList))
        #expect(content.isFormatEnabled(.codeBlock), "leaving the code block stays possible")
    }
}
