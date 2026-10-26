//
//  LatexCompatibilityTests.swift
//  MarkdownEngineLatexTests
//
//  Known compatibility rewrites and the owner's formulas remain renderable.
//  Unsupported semantic commands use source fallback instead of approximation.
//

import AppKit
import Testing
import SwiftMath
@testable import MarkdownEngineLatex
import MarkdownEngine

@Suite("LaTeX compatibility layer")
struct LatexCompatibilityTests {

    /// Formulas SwiftMath rejects or mangles on its own.
    private static let rewritten = [
        #"R_d(r) \;=\; \frac{\alpha'}{4\pi}\Big[ z_r(1+\sigma_{tr} d_r)\frac{e^{-\sigma_{tr} d_r}}{d_r^3} + z_v(1+\sigma_{tr} d_v)\frac{e^{-\sigma_{tr} d_v}}{d_v^3}\Big], \qquad \sigma_{tr}=\sqrt{3\sigma_a \sigma_t'}"#,
        #"\hat F_d \;=\; F_d + (\alpha \odot F_d + \beta)\cdot w, \qquad \alpha,\beta = P_\theta\!\big(c(F_d, F_e)\big), \qquad w\in[0,1]"#,
        #"\bigl( x \bigr) \Bigl\{ y \Bigr\} \biggl[ z \biggr] \Big| w \Big| \big\langle v \big\rangle"#,
        #"f = c f^*,\; c \approx \tfrac14 \quad \dfrac{a}{b} \quad \cfrac{1}{1+\cfrac{1}{x}}"#,
        #"\boxed{\,f^*=\frac{bp-q}{b}=\frac{\text{edge}}{\text{odds}}\,}"#,
        #"\operatorname{softmax}(z)_i = \frac{e^{z_i}}{\sum_j e^{z_j}} \quad \operatorname*{argmax}_x f(x)"#,
        #"\underbrace{a+b}_{\text{sum}} + \overbrace{c \cdot d}^{\text{product}}"#,
        #"x \equiv y \pmod{n} \qquad a \bmod b"#,
        #"\begin{cases} x & x>0 \\ 0 & \text{otherwise} \end{cases}"#,
        #"\begin{align} a &= b \\ c &= d \end{align}"#,
        #"\begin{align*} a &= b + c \\ &= d \end{align*}"#,
        #"\begin{equation} E = mc^2 \end{equation}"#,
        #"\begin{alignat}{2} a &= b & c &= d \end{alignat}"#,
        #"\begin{array}{c|c} a & b \\ \hline c & d \end{array}"#,
        #"\begin{smallmatrix} 1 & 2 \\ 3 & 4 \end{smallmatrix} \begin{pmatrix*}[r] -1 \end{pmatrix*}"#,
        #"\begin{aligned} a &= b & c &= d \\ e &= f \end{aligned}"#,
        #"\begin{split} a &= b \\[4pt] &= c \end{split}"#,
        #"\begin{dcases} 1 & x \ge 0 \\ 0 & x < 0 \end{dcases}"#,
        #"\stackrel{\text{def}}{=} \quad \overset{!}{=} \quad \underset{x\to 0}{\lim}"#,
        #"A \xrightarrow{f} B \xleftarrow[g]{h} C \xRightarrow{\;} D"#,
        #"\sum_{\substack{i<n \\ j<m}} a_{ij}"#,
        #"a \implies b \impliedby c \iff d \quad \therefore e \quad \because f"#,
        #"x_1, \dots, x_n \quad \varnothing \quad \lvert x \rvert \quad \lVert y \rVert \quad \left\lvert z \right\rvert"#,
        #"\mathscr{L} \mathbbm{1} \boldsymbol{\beta} \mathds{R} \pmb{x}"#,
        #"\text{rate} \hspace{1em} x \phantom{yy} z \vphantom{Q} \label{eq:1} \tag{3} \nonumber"#,
        #"\left. \frac{df}{dx} \right|_{x=0} \quad \left( \frac{a}{b} \middle| c \right)"#,
        #"a \not= b \quad c \not\in D"#,
        #"\R^n \to \E[X] \quad \N \subset \Z \subset \Q"#,
        #"α ≤ β → ∞, \; x − y ≈ π · 2, \; “quoted” – dash — em ÷ ×"#,
        #"90° \quad a′ + b″ \quad ℝ^2 \quad 5 ≠ 6"#,
        #"\max\limits_{x} f \quad \sum\nolimits_{i} a_i \quad \sqrt[3]{x} \quad \sqrt[]{y}"#,
        ##"100\% \quad \$5 \quad a\_b \quad \#1 \quad \{x\} \quad \text{A \& B} \quad \colon"##,
        #"a\:b \quad c\,d \quad e\;f \quad g\!h \quad i\ j \quad \mkern-2mu k \quad \kern 3pt"#,
        #"\lim_{n\to\infty} \left(1+\frac{1}{n}\right)^n = e \qquad \int_0^\infty e^{-x}\,dx = 1"#,
        #"\mathbb{E}[X] = \sum_i p_i x_i \quad \Pr(A \mid B) = \frac{\Pr(A \cap B)}{\Pr(B)}"#,
        #"\nabla \cdot \vec{E} = \frac{\rho}{\varepsilon_0} \quad \hat{y} = \bar{x} + \tilde{z} + \dot{w} + \ddot{u}"#,
        #"\color{red}{x} + \textcolor{blue}{y} \quad \mathcal{O}(n \log n) \quad \mathfrak{g} \quad \mathsf{T} \quad \mathtt{id}"#,
        #"\sin^2\theta + \cos^2\theta = 1 \quad \arctan x \quad \ln \det A \quad \gcd(a,b) \quad \deg p"#,
        #"\forall \epsilon > 0\ \exists \delta > 0 \quad \neg p \land q \lor r \quad A \setminus B \quad \emptyset"#,
        #"\ldots \cdots \vdots \ddots \quad \hbar \ell \Re \Im \aleph \wp \top \bot \vdash \models \dagger"#,
        #"\begin{Bmatrix} 1 & 2 \\ 3 & 4 \end{Bmatrix} \begin{vmatrix} a & b \\ c & d \end{vmatrix} \begin{Vmatrix} x \end{Vmatrix}"#,
        #"\href{https://x.y}{link text} \quad \url{x.y}"#,
        #"\left( unbalanced"#,
        #"\frac{a}{b"#,
        #"\big( x \big) + \Big[ y"#,
    ]

    @MainActor
    @Test("supported compatibility formulas render as images")
    func everythingRenders() {
        _ = NSApplication.shared
        let bridge = SwiftMathBridge()
        for formula in Self.rewritten {
            let result = bridge.render(latex: formula, fontSize: 17, theme: .default)
            #expect(result != nil, "no render for \(formula)")
            #expect((result?.size.width ?? 0) > 0 && (result?.size.height ?? 0) > 0, "empty render for \(formula)")
        }
    }

    @Test("sizing commands pair into left/right by suffix or delimiter, and alternate for bars")
    func sizingPairs() {
        #expect(LatexCompatibility.resolveSizing(in: #"\Big[ x \Big]"#, pairing: true) == #"\left[ x \right]"#)
        #expect(LatexCompatibility.resolveSizing(in: #"\bigl( x \bigr)"#, pairing: true) == #"\left( x \right)"#)
        #expect(LatexCompatibility.resolveSizing(in: #"\Big| x \Big|"#, pairing: true) == #"\left| x \right|"#)
        #expect(LatexCompatibility.resolveSizing(in: #"\big\{ x \big\}"#, pairing: true) == #"\left\{ x \right\}"#)
        #expect(LatexCompatibility.resolveSizing(in: #"\Big< x \Big>"#, pairing: true) == #"\left\langle  x \right\rangle "#)
        // Unpaired sizing never becomes a lone \left: the bare delimiter is used.
        #expect(LatexCompatibility.resolveSizing(in: #"\Big[ x"#, pairing: true) == #"[ x"#)
        #expect(LatexCompatibility.resolveSizing(in: #"\Big[ x \Big]"#, pairing: false) == #"[ x ]"#)
        // `\bigcup` is an operator, not sizing.
        #expect(LatexCompatibility.resolveSizing(in: #"\bigcup_i A_i"#, pairing: true) == #"\bigcup_i A_i"#)
    }

    @Test("rewrites keep the author's meaning in SwiftMath's dialect")
    func rewrites() {
        #expect(LatexCompatibility.rewrite(#"\tfrac{a}{b}"#) == #"\frac{a}{b}"#)
        #expect(LatexCompatibility.rewrite(#"\boxed{x+1}"#) == #"{x+1}"#)
        #expect(LatexCompatibility.rewrite(#"\operatorname*{argmax}_x"#) == #"\mathrm{argmax}_x"#)
        #expect(LatexCompatibility.rewrite(#"\overset{a}{b}"#) == #"{b}^{a}"#)
        #expect(LatexCompatibility.rewrite(#"\underset{a}{b}"#) == #"{b}_{a}"#)
        #expect(LatexCompatibility.rewrite(#"\xrightarrow[u]{o}"#) == #"{\rightarrow}^{o}_{u}"#)
        #expect(LatexCompatibility.rewrite(#"\substack{a \\ b}"#) == #"\begin{matrix}a \\ b\end{matrix}"#)
        #expect(LatexCompatibility.rewrite(#"x \pmod{n}"#) == #"x \;(\mathrm{mod}\;n)"#)
        #expect(LatexCompatibility.rewrite(#"\begin{align*} a &= b \end{align*}"#) == #"\begin{aligned} a &= b \end{aligned}"#)
        #expect(LatexCompatibility.rewrite(#"\begin{array}{cc} a & b \\ \hline c & d \end{array}"#) == #"\begin{matrix} a & b \\  c & d \end{matrix}"#)
        #expect(LatexCompatibility.rewrite(#"\begin{aligned} a &= b & c &= d \end{aligned}"#) == #"\begin{aligned} a &= b \quad  c \quad = d \end{aligned}"#)
        #expect(LatexCompatibility.rewrite(#"a \\[6pt] b"#) == #"a \\ b"#)
        #expect(LatexCompatibility.rewrite("α − β") == #"\alpha  - \beta "#)
        #expect(LatexCompatibility.rewrite(#"\label{eq} x \tag{2}"#) == #" x "#)
        #expect(LatexCompatibility.rewrite(#"\href{u}{t}"#) == #"\text{t}"#)
        #expect(LatexCompatibility.rewrite(#"\text{A \& B}"#) == #"\text{A  and  B}"#)
        #expect(LatexCompatibility.rewrite(#"\begin{equation} E = mc^2 \end{equation}"#) == #" E = mc^2 "#)
        #expect(LatexCompatibility.rewrite(#"\begin{align} a &= b \\ + c \end{align}"#) == #"\begin{aligned} a &= b \\& + c \end{aligned}"#)
    }

    @Test("a brace group after an environment is content unless it is a column spec")
    func environmentGroupsStayContent() {
        #expect(LatexCompatibility.rewrite(#"\begin{equation}{x}^2 = y\end{equation}"#) == #"{x}^2 = y"#)
        #expect(LatexCompatibility.rewrite(#"\begin{pmatrix} a \end{pmatrix}{x}"#).hasSuffix(#"\end{pmatrix}{x}"#))
        #expect(!LatexCompatibility.rewrite(#"\begin{array}{cc} a & b \end{array}"#).contains("{cc}"))
    }

    @Test("a left arrow accent is never drawn as a right arrow")
    func leftArrowIsNotAliasedToVec() {
        #expect(!LatexCompatibility.rewrite(#"\overleftarrow{AB}"#).contains(#"\vec"#))
    }

    @Test("sizing pairs that span aligned rows still render, unpaired")
    func sizingAcrossRowsRenders() {
        #expect(SwiftMathBridge.parse(#"\begin{aligned} a &= \Big( b \\ &+ c \Big)\end{aligned}"#) != nil)
        #expect(SwiftMathBridge.parse(#"\Big( x \Big)"#) != nil)
    }

    @Test("alignment folding leaves nested matrices, brace groups and literal ampersands alone")
    func alignmentFoldingSkipsNestedConstructs() {
        let matrix = LatexCompatibility.rewrite(#"\begin{aligned} A &= \begin{bmatrix} 1 & 2 \\ 3 & 4 \end{bmatrix}\end{aligned}"#)
        #expect(matrix.contains(#"1 & 2 \\ 3 & 4"#))
        #expect(!matrix.contains(#"\quad"#))
        let column = LatexCompatibility.rewrite(#"\begin{align} A &= \begin{pmatrix} a \\ b \end{pmatrix}\end{align}"#)
        #expect(column.contains(#"a \\ b"#))
        #expect(!column.contains(#"\\ &"#) && !column.contains(#"\\&"#))
        #expect(LatexCompatibility.rewrite(#"\begin{aligned} x &= \frac{a}{b} \\ &= c \end{aligned}"#)
                == #"\begin{aligned} x &= \frac{a}{b} \\ &= c \end{aligned}"#)
    }

    @Test("repairs answer the parser's own complaint")
    func repairs() {
        func error(_ code: Int, _ message: String) -> NSError {
            NSError(domain: "MTParseError", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        #expect(LatexCompatibility.repair(#"\foo x"#, error: error(2, #"Invalid command \foo"#)) == nil)
        #expect(LatexCompatibility.repair(#"\left( x"#, error: error(6, "Missing \\right")) == #"\left( x \right."#)
        #expect(LatexCompatibility.repair(#"x \right)"#, error: error(7, "Missing \\left")) == #"\left. x \right)"#)
        #expect(LatexCompatibility.repair(#"\frac{a}{b"#, error: error(1, "Mismatched braces")) == #"\frac{a}{b}"#)
        #expect(LatexCompatibility.repair(#"x"#, error: error(8, "Invalid environment")) == nil)
    }

    @Test("the math disk cache drops old versions and stays under its limit")
    func diskCacheIsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("math-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("math-v9")
        let old = root.appendingPathComponent("math-v1")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for index in 0..<8 {
            let file = current.appendingPathComponent("\(index).png")
            try Data(repeating: 1, count: 64 * 1024).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                                                  ofItemAtPath: file.path)
        }

        SwiftMathBridge.pruneDiskCache(root: root, current: current, limit: 256 * 1024)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: current.path)
        #expect(kept.count < 8)
        #expect(kept.contains("7.png"), "the newest renders stay")
        #expect(!kept.contains("0.png"), "the oldest renders go first")
    }
}
