//
//  TabBarView.swift
//  PageFlow
//
//  Chrome-style tabs integrated into the title bar area with glassmorphism
//

import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    @Bindable var tabManager: TabManager
    @Binding var isHovering: Bool

    var body: some View {
        HStack(spacing: DesignTokens.tabSpacing) {
            // Tab strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.tabSpacing) {
                    ForEach(tabManager.tabs) { tab in
                        let isDirty = tabManager.isTabDirty(tab.id)
                        TabItemView(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            isDirty: isDirty,
                            onSelect: { tabManager.selectTab(tab.id) },
                            onClose: { tabManager.closeTab(tab.id) }
                        )
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let sourceIDString = items.first,
                                  let sourceID = UUID(uuidString: sourceIDString),
                                  let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == sourceID }),
                                  let targetIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }),
                                  sourceIndex != targetIndex else {
                                return false
                            }
                            tabManager.moveTab(fromIndex: sourceIndex, toIndex: targetIndex)
                            return true
                        }
                    }

                    // New tab button with glassmorphism
                    Button {
                        tabManager.createNewTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 24, height: 24)
                            .background(.ultraThinMaterial)
                            .background(DesignTokens.floatingToolbarBase.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.white.opacity(0.22))
                            )
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    .onHover { hovering in
                        (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                    }
                }
                .padding(.horizontal, DesignTokens.spacingXS)
            }
        }
        .frame(height: DesignTokens.trafficLightHotspotHeight)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isHovering)
    }
}
