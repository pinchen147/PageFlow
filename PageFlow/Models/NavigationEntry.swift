//
//  NavigationEntry.swift
//  PageFlow
//
//  Navigation history entry for back/forward functionality
//

import Foundation

struct NavigationEntry {
    let pageIndex: Int

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
    }
}
