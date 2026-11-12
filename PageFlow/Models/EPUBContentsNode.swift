//
//  EPUBContentsNode.swift
//  PageFlow
//
//  A book's contents as the sidebar lists them: its flat, depth-marked entries
//  nested into sections that collapse, the shape PDF's outline already has.
//

import EPUBKit

nonisolated struct EPUBContentsNode: Identifiable, Sendable {
    /// The entry's place in the list: two entries may share a title and target.
    let id: Int
    let entry: EPUBContentsEntry
    /// Nil on a leaf, so it shows no disclosure triangle.
    var children: [EPUBContentsNode]?

    /// Nests each entry under the nearest one before it that is shallower.
    static func tree(of contents: [EPUBContentsEntry]) -> [EPUBContentsNode] {
        var next = 0
        func siblings(deeperThan parent: Int) -> [EPUBContentsNode] {
            var nodes: [EPUBContentsNode] = []
            while next < contents.count, contents[next].depth > parent {
                var node = EPUBContentsNode(id: next, entry: contents[next])
                next += 1
                let children = siblings(deeperThan: node.entry.depth)
                node.children = children.isEmpty ? nil : children
                nodes.append(node)
            }
            return nodes
        }
        return siblings(deeperThan: -1)
    }

    /// The ids of the entries whose sections hold an entry, outermost first.
    static func sections(holding id: String?, in contents: [EPUBContentsEntry]) -> [String] {
        guard let index = contents.firstIndex(where: { $0.id == id }) else { return [] }
        var depth = contents[index].depth
        var sections: [String] = []
        for entry in contents[..<index].reversed() where entry.depth < depth {
            sections.insert(entry.id, at: 0)
            depth = entry.depth
        }
        return sections
    }
}
