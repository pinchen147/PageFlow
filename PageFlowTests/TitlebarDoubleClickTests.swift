//
//  TitlebarDoubleClickTests.swift
//  PageFlowTests
//
//  The titlebar double-click decision: System Settings preference string
//  to action, including the absent-key default and unknown future values.
//

import Testing
@testable import PageFlow

struct TitlebarDoubleClickTests {
    @Test
    func absentKeyMeansTheMacDefaultZoom() {
        #expect(TitlebarDoubleClick.action(for: nil) == .zoom)
    }

    @Test
    func maximizeIsTheRawValueForZoom() {
        #expect(TitlebarDoubleClick.action(for: "Maximize") == .zoom)
    }

    @Test
    func minimizeAndFillAndNoneMapDirectly() {
        #expect(TitlebarDoubleClick.action(for: "Minimize") == .minimize)
        #expect(TitlebarDoubleClick.action(for: "Fill") == .fill)
        #expect(TitlebarDoubleClick.action(for: "None") == .none)
    }

    /// A future macOS value must do nothing rather than guess.
    @Test
    func unknownValuesResolveToNone() {
        #expect(TitlebarDoubleClick.action(for: "SomeFutureAction") == .none)
        #expect(TitlebarDoubleClick.action(for: "") == .none)
    }
}
