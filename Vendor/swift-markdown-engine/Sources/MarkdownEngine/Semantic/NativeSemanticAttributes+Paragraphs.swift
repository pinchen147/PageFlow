import AppKit

extension NativeSemanticAttributes {
    static func paragraphStyle(for role: NativeSemanticParagraphRole, font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch role {
        case .listItem(let ordered, let indent, let checked):
            let marker: NSTextList.MarkerFormat
            if let checked { marker = .init(rawValue: checked ? "☑" : "☐") }
            else { marker = ordered == nil ? .disc : .init(rawValue: "{decimal}.") }
            let list = NSTextList(markerFormat: marker, options: 0)
            if let ordered { list.startingItemNumber = max(1, ordered) }
            style.textLists = [list]
            style.firstLineHeadIndent = CGFloat(indent) * font.pointSize * 0.5
            style.headIndent = style.firstLineHeadIndent + font.pointSize * 1.7
        case .quote(let depth):
            style.firstLineHeadIndent = CGFloat(max(1, depth)) * font.pointSize * 1.5
            style.headIndent = style.firstLineHeadIndent
        default: break
        }
        return style
    }
}
