import Foundation

/// An explicit native zoom command that executes once per document generation.
public struct MarkdownZoomRequest: Equatable, Sendable {
    /// Width Fit follows the configured reading row; Actual Size restores 100%.
    public enum Action: Equatable, Sendable {
        /// Fit the reading row, effective gutters and visible comment lane.
        case fitWidth
        /// Leave width Fit and restore native magnification to 100%.
        case actualSize
    }
    /// The requested native zoom action.
    public let action: Action
    /// Identifies this invocation even when its resulting scale is unchanged.
    public let token: UUID
    /// Creates a command with a fresh token unless the caller supplies one.
    public init(_ action: Action, token: UUID = UUID()) {
        self.action = action
        self.token = token
    }
}
