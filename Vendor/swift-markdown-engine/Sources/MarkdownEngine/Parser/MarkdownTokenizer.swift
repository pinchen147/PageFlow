//
//  MarkdownTokenizer.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// The token namespace. Tokens are produced by `parseTokensViaAST`
// (`BlockScopedTokenizer`): block structure + block-level tokens come from
// `BlockParser` + `BlockLevelTokenizer` (hand scanners, no regex), inline
// tokens from the AST (`InlineParser` → `InlineASTAdapter`). This file keeps
// only the code-block language helper.
import Foundation

// MARK: - Tokenizer
enum MarkdownTokenizer {

    // MARK: - Code Block Helpers

    static func extractLanguage(from token: MarkdownToken, in text: String) -> String? {
        extractLanguage(from: token, in: text as NSString)
    }

    /// The `NSString` form, for callers holding the live storage (no copy).
    static func extractLanguage(from token: MarkdownToken, in nsText: NSString) -> String? {
        guard token.kind == .codeBlock else { return nil }
        return FencedCode.scan(in: nsText, range: token.range)?.language(in: nsText)
    }
}
