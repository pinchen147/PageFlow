//
//  LatexCompatibility.swift
//  MarkdownEngineLatex
//
//  Rewrites the LaTeX that MathJax and KaTeX accept in notes into the dialect
//  SwiftMath parses. SwiftMath covers TeX's core (fractions, radicals, scripts,
//  \left…\right, the matrix/aligned/cases families, ~300 symbols) but has no
//  \big… sizing, \tfrac, \boxed, \operatorname, \underbrace, \bmod, \overset,
//  \xrightarrow, the AMS environment names (align, equation, array…), and it
//  drops any non-ASCII glyph silently. Compatibility rewrites cover a known
//  subset; unsupported commands stay intact so the bridge can show the source
//  instead of inventing or removing their meaning.
//

import Foundation
import SwiftMath

enum LatexCompatibility {

    // MARK: - Public

    /// The formula rewritten for SwiftMath. Pure and deterministic; the bridge
    /// caches renders by the ORIGINAL string, so this runs once per formula.
    /// `pairingSizing` turns `\Big( … \Big)` into `\left( … \right)`, which
    /// reads best but can't span the rows of an aligned block.
    static func rewrite(_ latex: String, pairingSizing: Bool = true) -> String {
        var text = latex
        text = replaceUnicode(in: text)
        text = rewriteNegations(in: text)
        text = replaceLineBreakSpacing(in: text)
        text = rewriteEnvironments(in: text)
        text = rewriteCommands(in: text)
        text = resolveSizing(in: text, pairing: pairingSizing)
        return text
    }

    /// A further rewrite that addresses ONE parse error SwiftMath reported for
    /// `latex` (already rewritten), or nil when nothing sensible remains to try.
    /// The bridge loops this a few times: an unbalanced `\left` gets its
    /// invisible `\right.`, sizing that could not be paired is dropped, a
    /// missing `}` is appended. Unknown commands require source fallback.
    static func repair(_ latex: String, error: NSError) -> String? {
        let message = error.localizedDescription
        switch error.code {
        case ParseError.invalidCommand:
            return nil
        case ParseError.missingRight:
            return latex + " \\right."
        case ParseError.missingLeft:
            return "\\left. " + latex
        case ParseError.invalidDelimiter, ParseError.missingDelimiter:
            let stripped = resolveSizing(in: latex, pairing: false)
            return stripped == latex ? nil : stripped
        case ParseError.mismatchBraces, ParseError.characterNotFound:
            if message.hasSuffix("}") || error.code == ParseError.mismatchBraces { return latex + "}" }
            if message.hasSuffix("]") { return latex + "]" }
            return nil
        case ParseError.invalidLimits:
            let stripped = latex.replacingOccurrences(of: #"\\(no)?limits\b"#, with: "", options: .regularExpression)
            return stripped == latex ? nil : stripped
        default:
            return nil
        }
    }

    /// SwiftMath's parse error codes (`MTParseErrors`, not public), by value.
    enum ParseError {
        static let mismatchBraces = 1
        static let invalidCommand = 2
        static let characterNotFound = 3
        static let missingDelimiter = 4
        static let invalidDelimiter = 5
        static let missingRight = 6
        static let missingLeft = 7
        static let invalidEnv = 8
        static let missingEnv = 9
        static let invalidNumColumns = 12
        static let invalidLimits = 13
    }

    // MARK: - Symbols SwiftMath's table lacks

    /// Registered once into SwiftMath's symbol table: names MathJax knows that
    /// SwiftMath does not, each with the glyph it stands for.
    static let registerMissingSymbols: Void = {
        let symbols: [(String, MTMathAtomType, String)] = [
            ("therefore", .ordinary, "\u{2234}"), ("because", .ordinary, "\u{2235}"),
            ("nexists", .ordinary, "\u{2204}"), ("varnothing", .ordinary, "\u{2205}"),
            ("implies", .relation, "\u{27F9}"), ("impliedby", .relation, "\u{27F8}"),
            ("lesssim", .relation, "\u{2272}"), ("gtrsim", .relation, "\u{2273}"),
            ("nsubseteq", .relation, "\u{2288}"), ("nsupseteq", .relation, "\u{2289}"),
            ("nmid", .relation, "\u{2224}"), ("nparallel", .relation, "\u{2226}"),
            ("nleq", .relation, "\u{2270}"), ("ngeq", .relation, "\u{2271}"),
            ("nsim", .relation, "\u{2241}"), ("ncong", .relation, "\u{2247}"),
            ("lhd", .binaryOperator, "\u{22B2}"), ("rhd", .binaryOperator, "\u{22B3}"),
            ("unlhd", .relation, "\u{22B4}"), ("unrhd", .relation, "\u{22B5}"),
            ("circledast", .binaryOperator, "\u{229B}"), ("boxplus", .binaryOperator, "\u{229E}"),
            ("boxtimes", .binaryOperator, "\u{22A0}"), ("boxdot", .binaryOperator, "\u{22A1}"),
            ("blacksquare", .ordinary, "\u{25A0}"), ("blacktriangle", .ordinary, "\u{25B2}"),
            ("bigstar", .ordinary, "\u{2605}"), ("checkmark", .ordinary, "\u{2713}"),
            ("mathsterling", .ordinary, "\u{00A3}"), ("euro", .ordinary, "\u{20AC}"),
            ("yen", .ordinary, "\u{00A5}"), ("copyright", .ordinary, "\u{00A9}"),
            ("mathring", .ordinary, "\u{02DA}"), ("dotsc", .ordinary, "\u{2026}"),
            ("dotsb", .ordinary, "\u{22EF}"), ("dotsm", .ordinary, "\u{22EF}"),
            ("dotsi", .ordinary, "\u{22EF}"), ("dotso", .ordinary, "\u{2026}"),
            ("dots", .ordinary, "\u{2026}"), ("colon", .punctuation, ":"),
            ("textdegree", .ordinary, "\u{00B0}"), ("degree", .ordinary, "\u{00B0}"),
            ("varDelta", .variable, "\u{0394}"), ("varOmega", .variable, "\u{03A9}"),
            ("varTheta", .variable, "\u{0398}"), ("varSigma", .variable, "\u{03A3}"),
            ("hslash", .ordinary, "\u{210F}"), ("mho", .ordinary, "\u{2127}"),
            ("eth", .ordinary, "\u{00F0}"), ("Finv", .ordinary, "\u{2132}"),
            ("Game", .ordinary, "\u{2141}"), ("Bbbk", .ordinary, "\u{1D55C}"),
            ("leadsto", .relation, "\u{21DD}"), ("rightsquigarrow", .relation, "\u{21DD}"),
            ("hookrightarrow", .relation, "\u{21AA}"), ("hookleftarrow", .relation, "\u{21A9}"),
            ("twoheadrightarrow", .relation, "\u{21A0}"), ("rightarrowtail", .relation, "\u{21A3}"),
            ("curvearrowright", .relation, "\u{21B7}"), ("circlearrowright", .relation, "\u{21BB}"),
            ("upharpoonright", .relation, "\u{21BE}"), ("leftrightarrows", .relation, "\u{21C6}"),
            ("rightleftarrows", .relation, "\u{21C4}"), ("Lleftarrow", .relation, "\u{21DA}"),
            ("Rrightarrow", .relation, "\u{21DB}"), ("dashrightarrow", .relation, "\u{21E2}"),
            ("dashleftarrow", .relation, "\u{21E0}"), ("multimap", .relation, "\u{22B8}"),
            ("intercal", .binaryOperator, "\u{22BA}"), ("veebar", .binaryOperator, "\u{22BB}"),
            ("barwedge", .binaryOperator, "\u{22BC}"), ("doublebarwedge", .binaryOperator, "\u{2A5E}"),
            ("sqsubset", .relation, "\u{228F}"), ("sqsupset", .relation, "\u{2290}"),
            ("between", .relation, "\u{226C}"), ("pitchfork", .relation, "\u{22D4}"),
            ("vartriangleleft", .relation, "\u{22B2}"), ("vartriangleright", .relation, "\u{22B3}"),
            ("trianglelefteq", .relation, "\u{22B4}"), ("trianglerighteq", .relation, "\u{22B5}"),
            ("triangleq", .relation, "\u{225C}"), ("doteq", .relation, "\u{2250}"),
            ("coloneqq", .relation, "\u{2254}"), ("eqqcolon", .relation, "\u{2255}"),
            ("coloneq", .relation, "\u{2254}"), ("Coloneqq", .relation, "\u{2A74}"),
            ("precsim", .relation, "\u{227E}"), ("succsim", .relation, "\u{227F}"),
            ("preccurlyeq", .relation, "\u{227C}"), ("succcurlyeq", .relation, "\u{227D}"),
            ("curlyeqprec", .relation, "\u{22DE}"), ("curlyeqsucc", .relation, "\u{22DF}"),
            ("lessdot", .relation, "\u{22D6}"), ("gtrdot", .relation, "\u{22D7}"),
            ("lll", .relation, "\u{22D8}"), ("ggg", .relation, "\u{22D9}"),
            ("lesseqgtr", .relation, "\u{22DA}"), ("gtreqless", .relation, "\u{22DB}"),
            ("lessgtr", .relation, "\u{2276}"), ("gtrless", .relation, "\u{2277}"),
            ("eqcirc", .relation, "\u{2256}"), ("circeq", .relation, "\u{2257}"),
            ("thicksim", .relation, "\u{223C}"), ("thickapprox", .relation, "\u{2248}"),
            ("approxeq", .relation, "\u{224A}"), ("backsim", .relation, "\u{223D}"),
            ("backsimeq", .relation, "\u{22CD}"), ("bumpeq", .relation, "\u{224F}"),
            ("Bumpeq", .relation, "\u{224E}"), ("fallingdotseq", .relation, "\u{2252}"),
            ("risingdotseq", .relation, "\u{2253}"), ("shortparallel", .relation, "\u{2225}"),
            ("smallsmile", .relation, "\u{2323}"), ("smallfrown", .relation, "\u{2322}"),
            ("vdash", .relation, "\u{22A2}"),
            ("vDash", .relation, "\u{22A8}"), ("Vdash", .relation, "\u{22A9}"),
            ("Vvdash", .relation, "\u{22AA}"), ("nvdash", .relation, "\u{22AC}"),
            ("nvDash", .relation, "\u{22AD}"), ("nVdash", .relation, "\u{22AE}"),
            ("nVDash", .relation, "\u{22AF}"), ("dashv", .relation, "\u{22A3}"),
            ("Subset", .relation, "\u{22D0}"), ("Supset", .relation, "\u{22D1}"),
            ("subsetneq", .relation, "\u{228A}"), ("supsetneq", .relation, "\u{228B}"),
            ("varsubsetneq", .relation, "\u{228A}"), ("varsupsetneq", .relation, "\u{228B}"),
            ("sqsubseteq", .relation, "\u{2291}"), ("sqsupseteq", .relation, "\u{2292}"),
            ("sqcap", .binaryOperator, "\u{2293}"), ("sqcup", .binaryOperator, "\u{2294}"),
            ("curlyvee", .binaryOperator, "\u{22CE}"), ("curlywedge", .binaryOperator, "\u{22CF}"),
            ("divideontimes", .binaryOperator, "\u{22C7}"), ("ltimes", .binaryOperator, "\u{22C9}"),
            ("rtimes", .binaryOperator, "\u{22CA}"), ("leftthreetimes", .binaryOperator, "\u{22CB}"),
            ("rightthreetimes", .binaryOperator, "\u{22CC}"), ("dotplus", .binaryOperator, "\u{2214}"),
            ("smallsetminus", .binaryOperator, "\u{2216}"), ("centerdot", .binaryOperator, "\u{22C5}"),
            ("circledcirc", .binaryOperator, "\u{229A}"), ("circleddash", .binaryOperator, "\u{229D}"),
            ("boxminus", .binaryOperator, "\u{229F}"), ("ominus", .binaryOperator, "\u{2296}"),
            ("oslash", .binaryOperator, "\u{2298}"), ("bigcirc", .binaryOperator, "\u{25EF}"),
            ("diamond", .binaryOperator, "\u{22C4}"), ("Diamond", .ordinary, "\u{25C7}"),
            ("lozenge", .ordinary, "\u{25CA}"), ("blacklozenge", .ordinary, "\u{29EB}"),
            ("triangledown", .ordinary, "\u{25BD}"), ("blacktriangledown", .ordinary, "\u{25BC}"),
            ("blacktriangleleft", .ordinary, "\u{25C0}"), ("blacktriangleright", .ordinary, "\u{25B6}"),
            ("measuredangle", .ordinary, "\u{2221}"), ("sphericalangle", .ordinary, "\u{2222}"),
            ("complement", .ordinary, "\u{2201}"), ("backprime", .ordinary, "\u{2035}"),
            ("diagup", .ordinary, "\u{2571}"), ("diagdown", .ordinary, "\u{2572}"),
            ("digamma", .variable, "\u{03DD}"), ("varkappa", .variable, "\u{03F0}"),
            ("beth", .ordinary, "\u{2136}"), ("daleth", .ordinary, "\u{2138}"), ("gimel", .ordinary, "\u{2137}"),
            ("maltese", .ordinary, "\u{2720}"), ("ulcorner", .open, "\u{231C}"), ("urcorner", .close, "\u{231D}"),
            ("llcorner", .open, "\u{231E}"), ("lrcorner", .close, "\u{231F}"),
            ("lgroup", .open, "\u{27EE}"), ("rgroup", .close, "\u{27EF}"),
            ("lmoustache", .open, "\u{23B0}"), ("rmoustache", .close, "\u{23B1}"),
        ]
        for (name, type, value) in symbols where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            // The atom initializer is not public; a factory atom copied and retyped is.
            let atom = MTMathAtomFactory.times()
            atom.type = type
            atom.nucleus = value
            MTMathAtomFactory.add(latexSymbol: name, value: atom)
        }
    }()

    // MARK: - Unicode

    /// Characters SwiftMath drops (anything outside printable ASCII), mapped to
    /// the command or ASCII that means the same. Note text is full of these:
    /// dashes and quotes from prose editors, operators pasted from a browser.
    private static let unicodeReplacements: [Character: String] = [
        "\u{2212}": "-", "\u{2013}": "-", "\u{2014}": "-", "\u{2010}": "-", "\u{2011}": "-",
        "\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{2032}": "'", "\u{2033}": "''",
        "\u{00A0}": " ", "\u{2009}": "\\,", "\u{2026}": "\\ldots ", "\u{00B7}": "\\cdot ",
        "\u{00D7}": "\\times ", "\u{00F7}": "\\div ", "\u{00B1}": "\\pm ", "\u{2213}": "\\mp ",
        "\u{2264}": "\\le ", "\u{2265}": "\\ge ", "\u{2260}": "\\neq ", "\u{2248}": "\\approx ",
        "\u{2261}": "\\equiv ", "\u{223C}": "\\sim ", "\u{2245}": "\\cong ", "\u{221D}": "\\propto ",
        "\u{226A}": "\\ll ", "\u{226B}": "\\gg ", "\u{2192}": "\\to ", "\u{2190}": "\\leftarrow ",
        "\u{2194}": "\\leftrightarrow ", "\u{21D2}": "\\Rightarrow ", "\u{21D0}": "\\Leftarrow ",
        "\u{21D4}": "\\Leftrightarrow ", "\u{21A6}": "\\mapsto ", "\u{2191}": "\\uparrow ", "\u{2193}": "\\downarrow ",
        "\u{221E}": "\\infty ", "\u{2202}": "\\partial ", "\u{2207}": "\\nabla ", "\u{2211}": "\\sum ",
        "\u{220F}": "\\prod ", "\u{222B}": "\\int ", "\u{222E}": "\\oint ", "\u{221A}": "\\sqrt ",
        "\u{2208}": "\\in ", "\u{2209}": "\\notin ", "\u{220B}": "\\ni ", "\u{2282}": "\\subset ",
        "\u{2283}": "\\supset ", "\u{2286}": "\\subseteq ", "\u{2287}": "\\supseteq ", "\u{222A}": "\\cup ",
        "\u{2229}": "\\cap ", "\u{2205}": "\\emptyset ", "\u{2200}": "\\forall ", "\u{2203}": "\\exists ",
        "\u{2204}": "\\nexists ", "\u{00AC}": "\\neg ", "\u{2227}": "\\wedge ", "\u{2228}": "\\vee ",
        "\u{2295}": "\\oplus ", "\u{2297}": "\\otimes ", "\u{2299}": "\\odot ", "\u{2218}": "\\circ ",
        "\u{2219}": "\\bullet ", "\u{22C5}": "\\cdot ", "\u{22C6}": "\\star ", "\u{2234}": "\\therefore ",
        "\u{2235}": "\\because ", "\u{2225}": "\\parallel ", "\u{22A5}": "\\perp ", "\u{2220}": "\\angle ",
        "\u{00B0}": "^{\\circ}", "\u{210F}": "\\hbar ", "\u{2113}": "\\ell ",
        "\u{2115}": "\\mathbb{N}", "\u{2124}": "\\mathbb{Z}", "\u{211A}": "\\mathbb{Q}", "\u{211D}": "\\mathbb{R}",
        "\u{2102}": "\\mathbb{C}", "\u{2119}": "\\mathbb{P}", "\u{1D53C}": "\\mathbb{E}",
        "\u{22EF}": "\\cdots ", "\u{22EE}": "\\vdots ", "\u{22F1}": "\\ddots ",
        "\u{03B1}": "\\alpha ", "\u{03B2}": "\\beta ", "\u{03B3}": "\\gamma ", "\u{03B4}": "\\delta ",
        "\u{03B5}": "\\varepsilon ", "\u{03F5}": "\\epsilon ", "\u{03B6}": "\\zeta ", "\u{03B7}": "\\eta ",
        "\u{03B8}": "\\theta ", "\u{03D1}": "\\vartheta ", "\u{03B9}": "\\iota ", "\u{03BA}": "\\kappa ",
        "\u{03BB}": "\\lambda ", "\u{03BC}": "\\mu ", "\u{00B5}": "\\mu ", "\u{03BD}": "\\nu ", "\u{03BE}": "\\xi ",
        "\u{03C0}": "\\pi ", "\u{03C1}": "\\rho ", "\u{03C3}": "\\sigma ", "\u{03C2}": "\\varsigma ",
        "\u{03C4}": "\\tau ", "\u{03C5}": "\\upsilon ", "\u{03C6}": "\\varphi ", "\u{03D5}": "\\phi ",
        "\u{03C7}": "\\chi ", "\u{03C8}": "\\psi ", "\u{03C9}": "\\omega ",
        "\u{0393}": "\\Gamma ", "\u{0394}": "\\Delta ", "\u{0398}": "\\Theta ", "\u{039B}": "\\Lambda ",
        "\u{039E}": "\\Xi ", "\u{03A0}": "\\Pi ", "\u{03A3}": "\\Sigma ", "\u{03A5}": "\\Upsilon ",
        "\u{03A6}": "\\Phi ", "\u{03A8}": "\\Psi ", "\u{03A9}": "\\Omega ",
    ]

    private static func replaceUnicode(in text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value > 0x7E }) else { return text }
        var out = ""
        out.reserveCapacity(text.utf16.count + 16)
        for ch in text {
            if let replacement = unicodeReplacements[ch] {
                out += replacement
            } else if let scalar = ch.unicodeScalars.first, scalar.value > 0x7E, ch.unicodeScalars.count == 1,
                      !(0x0410...0x044F).contains(scalar.value), !ch.isLetter {
                continue   // an unmapped symbol SwiftMath would drop anyway; drop it here, explicitly
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Environments

    /// AMS environment names, mapped to the SwiftMath environment that lays out
    /// the same way. Starred forms (no equation numbers) are the same layout.
    private static let environmentAliases: [String: String] = [
        "align": "aligned", "align*": "aligned", "alignat": "aligned", "alignat*": "aligned",
        "flalign": "aligned", "flalign*": "aligned", "split": "aligned",
        "multline": "gather", "multline*": "gather", "gather*": "gather",
        "gathered": "gather", "eqnarray*": "eqnarray", "smallmatrix": "matrix", "array": "matrix",
        "subarray": "matrix", "tabular": "matrix", "matrix*": "matrix", "pmatrix*": "pmatrix",
        "bmatrix*": "bmatrix", "Bmatrix*": "Bmatrix", "vmatrix*": "vmatrix", "Vmatrix*": "Vmatrix",
        "cases*": "cases", "dcases": "cases", "dcases*": "cases", "rcases": "cases", "drcases": "cases",
        "numcases": "cases", "CD": "matrix", "darray": "matrix",
    ]

    /// Environments whose rows SwiftMath limits to two columns (one `&`).
    private static let twoColumnEnvironments: Set<String> = ["aligned", "eqalign", "split"]

    /// Environments that only number or centre their content: the content stands alone.
    private static let transparentEnvironments: Set<String> = ["equation", "equation*", "displaymath", "math", "center", "flushleft", "flushright"]

    private static let environmentPattern = try! NSRegularExpression(
        pattern: #"\\(begin|end)\{([A-Za-z*]+)\}(\{[^{}]*\})?"#, options: [])

    private static func rewriteEnvironments(in text: String) -> String {
        guard text.contains("\\begin") else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        // Aliased names; `\begin{array}{cc|c}` also loses its column spec, and
        // `\begin{alignat}{2}` its column count.
        for match in environmentPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let keyword = ns.substring(with: match.range(at: 1))
            let name = ns.substring(with: match.range(at: 2))
            // The optional `{…}` after the name is a column spec only for `\begin`
            // of a spec-taking environment; anywhere else it is formula content.
            let group = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
            cursor = NSMaxRange(match.range)
            if transparentEnvironments.contains(name) { out += group; continue }
            let target = environmentAliases[name] ?? name
            let takesSpec = ["array", "tabular", "alignat", "alignat*", "darray", "subarray", "numcases"].contains(name)
            out += "\\\(keyword){\(target)}"
            if !(keyword == "begin" && takesSpec) { out += group }
        }
        out += ns.substring(from: cursor)
        out = out.replacingOccurrences(of: #"\\hline\b"#, with: "", options: .regularExpression)
        return limitAlignmentColumns(in: out)
    }

    /// `align`-family rows need exactly one `&` in SwiftMath: extra alignment
    /// points (`a &= b & c &= d`) fold into spacing, and a row without one (a
    /// continuation line, a single equation) goes into the aligned column.
    private static func limitAlignmentColumns(in text: String) -> String {
        var result = text
        for env in twoColumnEnvironments {
            let open = "\\begin{\(env)}"
            let close = "\\end{\(env)}"
            var searchStart = result.startIndex
            while let openRange = result.range(of: open, range: searchStart..<result.endIndex),
                  let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
                let body = String(result[openRange.upperBound..<closeRange.lowerBound])
                let fixed = foldAlignmentRows(body)
                result.replaceSubrange(openRange.upperBound..<closeRange.lowerBound, with: fixed)
                searchStart = result.index(openRange.upperBound, offsetBy: fixed.count + close.count)
            }
        }
        return result
    }

    /// Folds each top-level row of an `align`-family body to one `&`. Rows and
    /// `&`s inside a nested environment (a matrix) or a brace group belong to
    /// that construct and stay untouched; `\&` is a literal.
    private static func foldAlignmentRows(_ body: String) -> String {
        let chars = Array(body)
        var rows: [String] = []
        var row = ""
        var ampersands = 0
        var environmentDepth = 0
        var braceDepth = 0
        func finishRow() {
            let blank = row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            rows.append(ampersands == 0 && !blank ? "&" + row : row)
            row = ""
            ampersands = 0
        }
        func startsCommand(_ name: String, at index: Int) -> Bool {
            let end = index + name.count
            return end <= chars.count && String(chars[index..<end]) == name
        }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let topLevel = environmentDepth == 0 && braceDepth == 0
            if ch == "\\", i + 1 < chars.count {
                if chars[i + 1] == "\\", topLevel {
                    finishRow()
                    i += 2
                    continue
                }
                if startsCommand("begin{", at: i + 1) { environmentDepth += 1 }
                if startsCommand("end{", at: i + 1) { environmentDepth = max(0, environmentDepth - 1) }
                row.append(ch)
                row.append(chars[i + 1])
                i += 2
                continue
            }
            switch ch {
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "&" where topLevel:
                ampersands += 1
                row += ampersands == 1 ? "&" : "\\quad "
                i += 1
                continue
            default: break
            }
            row.append(ch)
            i += 1
        }
        finishRow()
        return rows.joined(separator: "\\\\")
    }

    // MARK: - Commands

    /// SwiftMath 1.7.3 has `\neq` and `\notin`, but no general `\not`.
    /// Read whole commands so `\notin` and `\\not` row content stay intact.
    /// Run before argument rewrites so nested negations are handled too.
    private static func rewriteNegations(in text: String) -> String {
        guard text.contains("\\not") else { return text }
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(text.utf16.count)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else {
                out.append(chars[i])
                i += 1
                continue
            }
            let start = i
            i += 1
            if !chars[i].isLetter {
                out += String(chars[start...i])
                i += 1
                continue
            }
            let nameStart = i
            while i < chars.count, chars[i].isLetter { i += 1 }
            guard String(chars[nameStart..<i]) == "not" else {
                out += String(chars[start..<i])
                continue
            }
            var relation = i
            while relation < chars.count, chars[relation].isWhitespace { relation += 1 }
            if relation < chars.count, chars[relation] == "=" {
                out += "\\neq "
                i = relation + 1
            } else if relation + 2 < chars.count, chars[relation] == "\\",
                      chars[relation + 1] == "i", chars[relation + 2] == "n",
                      relation + 3 == chars.count || !chars[relation + 3].isLetter {
                out += "\\notin "
                i = relation + 3
            } else {
                out += String(chars[start..<i])
            }
        }
        return out
    }

    /// Command → replacement command with the same argument shape.
    private static let commandAliases: [String: String] = [
        "tfrac": "\\frac", "dfrac": "\\frac", "cfrac": "\\frac", "tbinom": "\\binom", "dbinom": "\\binom",
        "operatorname": "\\mathrm", "operatorname*": "\\mathrm", "mathop": "\\mathrm", "DeclareMathOperator": "\\mathrm",
        "textnormal": "\\text", "mbox": "\\text", "textsc": "\\text", "textup": "\\text", "textmd": "\\text", "hbox": "\\text",
        "mathscr": "\\mathcal", "mathds": "\\mathbb", "mathbbm": "\\mathbb", "boldsymbol": "\\bm", "pmb": "\\bm",
        "bold": "\\mathbf", "mathbold": "\\bm", "textbf": "\\mathbf", "tt": "\\mathtt", "sf": "\\mathsf",
        "underbrace": "\\underline", "overbrace": "\\overline", "underbracket": "\\underline", "overbracket": "\\overline",
        "widecheck": "\\check", "widebar": "\\bar", "overrightarrow": "\\vec",
        "lvert": "\\vert", "rvert": "\\vert", "lVert": "\\Vert", "rVert": "\\Vert", "llbracket": "[", "rrbracket": "]",
        "lbrack": "[", "rbrack": "]", "lparen": "(", "rparen": ")", "argmax": "\\arg\\max", "argmin": "\\arg\\min",
        "sgn": "\\mathrm{sgn}", "tr": "\\mathrm{tr}", "rank": "\\mathrm{rank}", "diag": "\\mathrm{diag}",
        "Var": "\\mathrm{Var}", "Cov": "\\mathrm{Cov}", "E": "\\mathbb{E}", "R": "\\mathbb{R}", "N": "\\mathbb{N}",
        "Z": "\\mathbb{Z}", "Q": "\\mathbb{Q}", "C": "\\mathbb{C}", "P": "\\mathbb{P}",
        "bmod": "\\;\\mathrm{mod}\\;", "textrm": "\\mathrm", "em": "", "it": "\\mathit", "ce": "\\mathrm",
        ":": "\\;", "&": "\\text{ and }", "middle": "", "mathstrut": "", "strut": "", "allowbreak": "",
        "nonumber": "", "notag": "", "relax": "", "noindent": "", "centering": "", "qedhere": "", "displaybreak": "",
        "linebreak": "", "nolinebreak": "", "newline": "\\\\", "cr": "\\\\", "textstyle": "\\textstyle",
        "hfill": "\\quad", "hfil": "\\quad", "medskip": "\\quad", "bigskip": "\\qquad", "smallskip": "\\,",
        "thinspace": "\\,", "negthinspace": "\\!", "enspace": "\\quad", "enskip": "\\quad", "quad": "\\quad",
    ]

    /// Commands whose single brace argument is kept and the command dropped.
    private static let unwrappedCommands: Set<String> = [
        "boxed", "ensuremath", "mathclap", "mathrlap", "mathllap",
        "clap", "rlap", "llap", "smash", "mathbin", "mathrel", "mathord", "mathopen", "mathclose", "mathpunct",
        "mathinner", "vcenter", "raisebox", "fbox", "framebox", "uproot", "leftroot", "url", "href",
    ]

    /// Commands dropped together with their brace argument.
    private static let droppedCommands: Set<String> = [
        "label", "tag", "tag*", "vphantom", "phantom", "hphantom", "vspace", "vspace*", "hspace", "hspace*",
        "rule", "class", "cssId", "style", "html", "require", "newcommand", "renewcommand", "def",
    ]

    private static let dimensionPattern = try! NSRegularExpression(
        pattern: #"\\(m?kern|m?skip|hskip|vskip)\s*-?[0-9.]*\s*(mu|pt|em|ex|cm|mm|in)?"#, options: [])

    private static func rewriteCommands(in text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf16.count + 32)
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else { out.append(chars[i]); i += 1; continue }
            // Command name: letters (with an optional `*`), or one non-letter.
            var j = i + 1
            if chars[j].isLetter {
                while j < chars.count, chars[j].isLetter { j += 1 }
                if j < chars.count, chars[j] == "*" { j += 1 }
            } else {
                j += 1
            }
            let name = String(chars[(i + 1)..<j])

            if let replacement = commandAliases[name] {
                out += replacement
                i = j
            } else if unwrappedCommands.contains(name), let argument = braceArgument(in: chars, from: j) {
                // `\href{url}{text}` keeps its second argument.
                if name == "href", let second = braceArgument(in: chars, from: argument.end) {
                    out += "\\text" + String(chars[second.start..<second.end])
                    i = second.end
                } else {
                    out += String(chars[argument.start..<argument.end])
                    i = argument.end
                }
            } else if droppedCommands.contains(name) {
                i = braceArgument(in: chars, from: j)?.end ?? j
                // `\newcommand{\X}{body}` / `\def\X{body}` drop their body too.
                if ["newcommand", "renewcommand", "def"].contains(name) {
                    if let body = braceArgument(in: chars, from: skipOptionalArgument(in: chars, from: i)) { i = body.end }
                }
            } else if ["stackrel", "overset", "underset"].contains(name),
                      let top = braceArgument(in: chars, from: j),
                      let base = braceArgument(in: chars, from: top.end) {
                // `\overset{a}{b}` → `{b}^{a}`: SwiftMath stacks scripts, not arbitrary atoms.
                let script = name == "underset" ? "_" : "^"
                out += String(chars[base.start..<base.end]) + script + String(chars[top.start..<top.end])
                i = base.end
            } else if name.hasPrefix("x"), let arrow = extensibleArrows[name] {
                // `\xrightarrow[below]{above}` → `{\rightarrow}^{above}_{below}`.
                let below = optionalArgument(in: chars, from: j)
                guard let above = braceArgument(in: chars, from: below?.end ?? j) else { out += "\\" + name; i = j; continue }
                out += "{\\\(arrow)}^" + String(chars[above.start..<above.end])
                if let below { out += "_{" + String(chars[(below.start + 1)..<(below.end - 1)]) + "}" }
                i = above.end
            } else if name == "substack", let body = braceArgument(in: chars, from: j) {
                out += "\\begin{matrix}" + String(chars[(body.start + 1)..<(body.end - 1)]) + "\\end{matrix}"
                i = body.end
            } else if name == "pmod" || name == "pod", let body = braceArgument(in: chars, from: j) {
                let inner = String(chars[(body.start + 1)..<(body.end - 1)])
                out += name == "pmod" ? "\\;(\\mathrm{mod}\\;\(inner))" : "\\;(\(inner))"
                i = body.end
            } else if name == "sqrt", j < chars.count, chars[j] == "[", let degree = optionalArgument(in: chars, from: j),
                      degree.end - degree.start == 2 {
                out += "\\sqrt"   // an empty `[]` degree is a plain root
                i = degree.end
            } else if name == "text" || name == "textbf" || name == "textit" || name == "texttt" || name == "mathrm",
                      let argument = braceArgument(in: chars, from: j) {
                // Text keeps its spacing but must not carry TeX escapes SwiftMath's text mode lacks.
                let inner = String(chars[(argument.start + 1)..<(argument.end - 1)])
                    .replacingOccurrences(of: "\\&", with: " and ").replacingOccurrences(of: "\\%", with: "%")
                    .replacingOccurrences(of: "\\_", with: "_").replacingOccurrences(of: "\\#", with: "#")
                    .replacingOccurrences(of: "\\$", with: "$").replacingOccurrences(of: "~", with: " ")
                out += "\\\(name){\(inner)}"
                i = argument.end
            } else {
                out += "\\" + name
                i = j
            }
        }
        // `\kern-2mu`, `\mskip 3mu`: a dimension SwiftMath can't parse becomes a thin space.
        let ns = out as NSString
        out = dimensionPattern.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length), withTemplate: "\\\\,")
        return out
    }

    private static let extensibleArrows: [String: String] = [
        "xrightarrow": "rightarrow", "xleftarrow": "leftarrow", "xRightarrow": "Rightarrow", "xLeftarrow": "Leftarrow",
        "xleftrightarrow": "leftrightarrow", "xLeftrightarrow": "Leftrightarrow", "xmapsto": "mapsto",
        "xlongequal": "=", "xhookrightarrow": "hookrightarrow", "xhookleftarrow": "hookleftarrow",
        "xtwoheadrightarrow": "twoheadrightarrow", "xrightharpoonup": "rightharpoonup",
    ]

    // MARK: - Sizing (\big … \Bigg)

    private static let sizingPattern = try! NSRegularExpression(
        pattern: #"\\(big|Big|bigg|Bigg)(l|r|m)?(?![A-Za-z])\s*(\\[A-Za-z]+|\\.|[^\s\\])"#, options: [])

    private static let openingDelimiters: Set<String> = ["(", "[", "\\{", "\\langle", "\\lfloor", "\\lceil", "<", "\\lgroup", "\\lbrace", "\\lvert", "\\lVert"]
    private static let closingDelimiters: Set<String> = [")", "]", "\\}", "\\rangle", "\\rfloor", "\\rceil", ">", "\\rgroup", "\\rbrace", "\\rvert", "\\rVert"]

    /// `\Big[ … \Big]` → `\left[ … \right]` when `pairing` (auto-sized, what the
    /// author meant), else the bare delimiters. Direction comes from the
    /// `l`/`r` suffix or the delimiter itself; `|`, `\|` and `.` alternate with
    /// whatever is open. An unpaired result is not produced: the plain form is
    /// returned instead so the parser never sees a lone `\left`.
    static func resolveSizing(in text: String, pairing: Bool) -> String {
        let ns = text as NSString
        let matches = sizingPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var pieces: [(range: NSRange, delimiter: String, isLeft: Bool?)] = []
        var openCount = 0
        for match in matches {
            let suffix = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
            let delimiter = ns.substring(with: match.range(at: 3))
            let isLeft: Bool?
            if suffix == "l" { isLeft = true }
            else if suffix == "r" { isLeft = false }
            else if suffix == "m" { isLeft = nil }
            else if openingDelimiters.contains(delimiter) { isLeft = true }
            else if closingDelimiters.contains(delimiter) { isLeft = false }
            else { isLeft = openCount == 0 }   // `|`, `\|`, `.`, `/`: alternate
            if isLeft == true { openCount += 1 } else if isLeft == false { openCount -= 1 }
            pieces.append((match.range, delimiter, isLeft))
        }
        let balanced = openCount == 0 && pairing

        var out = ""
        var cursor = 0
        for piece in pieces {
            out += ns.substring(with: NSRange(location: cursor, length: piece.range.location - cursor))
            let delimiter = piece.delimiter == "<" ? "\\langle" : piece.delimiter == ">" ? "\\rangle" : piece.delimiter
            // A command delimiter (`\langle`) needs a separator before a following letter.
            let separator = delimiter.count > 2 && delimiter.hasPrefix("\\") ? " " : ""
            if balanced, let isLeft = piece.isLeft {
                out += (isLeft ? "\\left" : "\\right") + delimiter + separator
            } else {
                out += delimiter == "." ? "" : delimiter + separator
            }
            cursor = NSMaxRange(piece.range)
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Helpers

    private static func replaceLineBreakSpacing(in text: String) -> String {
        // `\\[6pt]` (row spacing) is a plain row break to SwiftMath.
        text.replacingOccurrences(of: #"\\\\\[[^\]]*\]"#, with: "\\\\\\\\", options: .regularExpression)
    }

    /// The brace group starting at or after `index` (spaces skipped): its
    /// `[start, end)` character indices, braces included; nil if none.
    private static func braceArgument(in chars: [Character], from index: Int) -> (start: Int, end: Int)? {
        var i = index
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == "{" else { return nil }
        var depth = 0
        var j = i
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "{" { depth += 1 } else if chars[j] == "}" { depth -= 1; if depth == 0 { return (i, j + 1) } }
            j += 1
        }
        return nil
    }

    /// The `[…]` group at `index`, if any.
    private static func optionalArgument(in chars: [Character], from index: Int) -> (start: Int, end: Int)? {
        var i = index
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == "[" else { return nil }
        var j = i
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "]" { return (i, j + 1) }
            j += 1
        }
        return nil
    }

    private static func skipOptionalArgument(in chars: [Character], from index: Int) -> Int {
        optionalArgument(in: chars, from: index)?.end ?? index
    }
}
