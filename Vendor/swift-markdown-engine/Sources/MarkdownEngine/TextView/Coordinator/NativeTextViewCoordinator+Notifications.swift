//
//  NativeTextViewCoordinator+Notifications.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Bus-notification handlers wired up by `subscribeToBusNotifications`.
//  These translate embedder-posted requests (apply bold / italic / heading
//  level) into the corresponding ContextMenu actions, and refresh styling
//  when the syntax highlighter signals an appearance change.
//

import AppKit

extension NativeTextViewCoordinator {
    /// True iff this notification is for THIS coordinator. When the bus is
    /// `scopeByObject`, the host posts the tab's `documentId` as `object`;
    /// a notification for another tab is dropped. When scoping is off the
    /// notification is always accepted (legacy broadcast behavior).
    func busNotificationIsForThisInstance(_ notification: Notification) -> Bool {
        // The scope convention (scopeByObject + nil-id/nil-object broadcast) is
        // owned by `MarkdownEditorBus.accepts(_:forDocument:)`, the symmetric
        // partner of the `scopeObject(for:)` used on the post side.
        configuration.services.bus.accepts(notification, forDocument: documentId)
    }

    @objc func handleBoldNotification(_ notification: Notification) {
        guard busNotificationIsForThisInstance(notification) else { return }
        didMarkdownBold(nil)
    }

    @objc func handleItalicNotification(_ notification: Notification) {
        guard busNotificationIsForThisInstance(notification) else { return }
        didMarkdownItalic(nil)
    }

    @objc func handleUnderlineNotification(_ notification: Notification) {
        guard busNotificationIsForThisInstance(notification) else { return }
        didMarkdownUnderline(nil)
    }

    @objc func handleHeadingNotification(_ notification: Notification) {
        guard busNotificationIsForThisInstance(notification) else { return }
        guard let level = notification.userInfo?["level"] as? Int else { return }
        let item = NSMenuItem()
        item.tag = level
        didMarkdownHeading(item)
    }

    @objc func handleAppearanceChange(_ notification: Notification) {
        guard let tv = textView else { return }
        // Only react if the notification came from our own text view or from nil (system-wide)
        if let sender = notification.object as? NSTextView, sender !== tv {
            return
        }
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
        restyleTextView(tv, paragraphCandidates: [fullRange])
    }
}
