//
//  NavigationEntry.swift
//  PageFlow
//
//  Navigation history entry for back/forward functionality
//

import Foundation

struct NavigationEntry {
    let pageIndex: Int
    let scrollPosition: CGPoint?

    init(pageIndex: Int, scrollPosition: CGPoint? = nil) {
        self.pageIndex = pageIndex
        self.scrollPosition = scrollPosition
    }
}
