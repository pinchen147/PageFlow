import Foundation

/// A quit decision covers exactly the documents and sources shown at admission.
/// Modal alerts and save panels can run recovery, opens, edits or transfers.
@MainActor
struct TerminationApproval {
    private struct Candidate {
        let owner: TabManager
        var snapshot: DocumentCloseSnapshot
    }
    private var candidates: [Candidate]
    private let membership: [ObjectIdentifier: [UUID]]
    private let initiallyPending: Set<UUID>

    init() {
        let groups = WindowRegistry.shared.allOpenTabs()
        membership = Self.membership(of: groups)
        candidates = groups.flatMap { group in
            group.tabs.compactMap { tab in
                group.tabManager.sessions[tab.id].map {
                    Candidate(owner: group.tabManager, snapshot: DocumentCloseSnapshot($0))
                }
            }
        }
        initiallyPending = Set(candidates.filter { $0.snapshot.session.content.document.hasPendingWrites }
            .map { $0.snapshot.session.id })
    }

    /// Other initially admitted saves may publish their URLs while one barrier
    /// waits. Sources, revisions, ownership and membership must still match.
    func matchesInitialWrites() -> Bool { matches(allowingSavedTabs: initiallyPending) }

    mutating func acceptInitialWrites() -> Bool {
        guard matchesInitialWrites(), candidates.allSatisfy({ !$0.snapshot.session.content.document.hasPendingWrites }) else { return false }
        for index in candidates.indices {
            candidates[index].snapshot = DocumentCloseSnapshot(candidates[index].snapshot.session)
        }
        return true
    }

    func matches() -> Bool { matches(allowingSavedTab: nil) }

    /// Accept only the identity change produced by saving this admitted source.
    mutating func acceptSave(of tabID: UUID) -> Bool {
        guard matches(allowingSavedTab: tabID),
              let index = candidates.firstIndex(where: { $0.snapshot.session.id == tabID }) else { return false }
        candidates[index].snapshot = DocumentCloseSnapshot(candidates[index].snapshot.session)
        return true
    }

    /// Only the guarded image-adoption owner calls this after its controlled edit.
    mutating func acceptImageAdoption(of tabID: UUID) -> Bool {
        guard matches(allowingSavedTab: nil, allowingImageAdoption: tabID),
              let index = candidates.firstIndex(where: { $0.snapshot.session.id == tabID }),
              candidates[index].snapshot.session.content.markdown != nil else { return false }
        candidates[index].snapshot = DocumentCloseSnapshot(candidates[index].snapshot.session)
        return true
    }

    private func matches(allowingSavedTab tabID: UUID? = nil, allowingImageAdoption preparedID: UUID? = nil,
                         allowingSavedTabs: Set<UUID> = []) -> Bool {
        guard membership == Self.membership(of: WindowRegistry.shared.allOpenTabs()) else { return false }
        return candidates.allSatisfy {
            $0.snapshot.matches($0.owner, allowingSavedURL: $0.snapshot.session.id == tabID || allowingSavedTabs.contains($0.snapshot.session.id),
                                allowingImageAdoption: $0.snapshot.session.id == preparedID)
        }
    }

    private static func membership(of groups: [WindowTabGroup]) -> [ObjectIdentifier: [UUID]] {
        Dictionary(uniqueKeysWithValues: groups.map { (ObjectIdentifier($0.tabManager), $0.tabs.map(\.id)) })
    }
}
