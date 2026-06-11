//
//  MainActorNotification.swift
//  PageFlow
//
//  NotificationCenter observation that hops to the main actor with a Task.
//

import Foundation

extension NotificationCenter {
    /// Adds an observer on `OperationQueue.main` whose body hops to the main
    /// actor via `Task { @MainActor in … }` instead of `MainActor.assumeIsolated`.
    /// The runtime's executor check doesn't reliably treat OperationQueue.main's
    /// context as the MainActor, so `assumeIsolated` can segfault on macOS 26
    /// when a notification fires re-entrantly during AppKit event dispatch.
    /// The one-runloop-turn deferral is part of the contract — use this only
    /// where deferred handling is acceptable.
    func addMainActorObserver(
        forName name: Notification.Name,
        object: Any? = nil,
        perform work: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: name, object: object, queue: .main) { _ in
            Task { @MainActor in work() }
        }
    }
}
