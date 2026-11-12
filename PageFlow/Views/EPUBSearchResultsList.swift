//
//  EPUBSearchResultsList.swift
//  PageFlow
//
//  The EPUB sidebar's Search mode: every Find match with the words around
//  it, grouped by chapter, with its page. Clicking one jumps there (Back
//  returns) and makes it Find's current match.
//

import EPUBKit
import SwiftUI

struct EPUBSearchResultsList: View {
    let book: EPUBBook
    @Bindable var content: EPUBContent

    private var search: EPUBSearchManager { content.searchManager }

    /// A run of matches under one heading: adjacent chapters that share a
    /// title (a chapter split across files) read as one.
    struct Group: Identifiable {
        let title: String
        let firstChapter: Int
        var matches: [(index: Int, result: EPUBSearchResult)]
        var id: Int { firstChapter }
    }

    static func groups(_ results: [EPUBSearchResult], titles: (Int) -> String) -> [Group] {
        var groups: [Group] = []
        for (index, result) in results.enumerated() {
            let title = titles(result.chapterIndex)
            if let last = groups.last, last.title == title,
               let lastChapter = last.matches.last?.result.chapterIndex,
               result.chapterIndex - lastChapter <= 1 {
                groups[groups.count - 1].matches.append((index, result))
            } else {
                groups.append(Group(title: title, firstChapter: result.chapterIndex, matches: [(index, result)]))
            }
        }
        return groups
    }

    var body: some View {
        if search.query.isEmpty {
            let shortcut = ShortcutModel.current(for: "search")
            GlassSidebarEmptyState(text: shortcut.isNone ? "Search the book with Find."
                : "Search the book with Find (\(shortcut.displayString)).")
        } else if search.results.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GlassSidebarEmptyState(text: search.isSearching ? "Searching…" : "No Results")
                coverageNote
            }
        } else {
            resultsList
        }
    }

    /// Said plainly when some chapters could not be read: the list may miss matches there.
    @ViewBuilder
    private var coverageNote: some View {
        let missing = search.unsearchedChapters.count
        if missing > 0, !search.isSearching {
            Label(missing == 1 ? "1 chapter couldn’t be searched" : "\(missing) chapters couldn’t be searched",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.bottom, DesignTokens.spacingXS)
                .help("These chapters failed to render, so results may be incomplete.")
        }
    }

    private var resultsList: some View {
        let groups = Self.groups(search.results) { book.chapters[$0].title }
        let current = search.results.indices.contains(search.currentIndex) ? search.results[search.currentIndex] : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(search.resultCount == 1 ? "1 match" : "\(search.resultCount) matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, DesignTokens.spacingXS)
                    coverageNote
                    ForEach(groups) { group in
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, DesignTokens.spacingSM)
                            .padding(.bottom, 2)
                        ForEach(group.matches, id: \.result) { match in
                            row(match.index, match.result, isCurrent: match.result == current)
                                .id(match.result)
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.spacingMD + DesignTokens.spacingSM)
                .padding(.bottom, DesignTokens.spacingMD)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .scrollContentBackground(.hidden)
            // A refresh of the same query keeps the rows visible while it runs.
            .disabled(search.isSearching)
            .onChange(of: current, initial: true) {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    private func row(_ index: Int, _ result: EPUBSearchResult, isCurrent: Bool) -> some View {
        // About 40 characters of context, most of it after the match, so a
        // narrow row never truncates the match itself away.
        let excerpt = book.searchExcerpt(for: result, before: 14, after: 30)
        let page = content.searchResultPageLabel(result)
        return Button {
            content.jump(toMatch: index)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Self.excerptText(excerpt)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                Spacer(minLength: DesignTokens.spacingXS)
                Text(page)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, DesignTokens.spacingXS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pageFlowClickCursor()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(excerpt.map { $0.before + $0.match + $0.after } ?? "Match")
        .accessibilityValue("Page \(page)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    static func excerptText(_ excerpt: EPUBSearchExcerpt?) -> Text {
        guard let excerpt else { return Text("Match") }
        return Text("\(excerpt.before)\(Text(excerpt.match).bold())\(excerpt.after)")
    }
}
