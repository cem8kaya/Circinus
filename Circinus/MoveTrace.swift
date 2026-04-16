import Foundation
import QuartzCore

// MARK: - MoveEntry

/// A single record in the append-only move history.
/// Created for every rotation (single or quantum) and every undo action.
struct MoveEntry {
    enum Kind {
        /// A normal single-tile rotation triggered by the player.
        case rotate
        /// An undo action. The original .rotate entry is preserved; this is appended alongside it.
        case undo
        /// A quantum-group rotation (multiple tiles rotated atomically).
        case quantumRotate
        /// A superposition collapse — player chose one of the two quantum states.
        case collapseSuper
    }

    /// Whether this entry is a rotation, undo, or quantum rotation.
    let kind: Kind
    /// Grid coordinates of the affected tile(s). Multiple elements for quantum groups.
    let coords: [GridCoord]
    /// Rotation state of each tile before the action. Parallel to `coords`.
    let rotationBefore: [Int]
    /// Rotation state of each tile after the action. Parallel to `coords`.
    let rotationAfter: [Int]
    /// Monotonic timestamp from CACurrentMediaTime() — not wall-clock.
    let timestamp: TimeInterval
    /// 1-based visible move counter at the time of this entry.
    let moveIndex: Int
}

// MARK: - MoveTrace

/// An append-only record of all player actions during a single level attempt.
///
/// Rules:
/// - Append-only during play. Reset wholesale on level start.
/// - Undo appends an `.undo` entry; it never removes existing entries.
/// - Every entry carries a monotonic timestamp for cadence analysis.
final class MoveTrace {
    private(set) var entries: [MoveEntry] = []

    /// Append a new entry. Called after every rotation and after every undo.
    func append(_ entry: MoveEntry) {
        entries.append(entry)
    }

    /// Clear all entries (called on level load/reset).
    func reset() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Number of entries that are not undos — i.e., actual rotation actions.
    var rotationCount: Int {
        entries.filter { $0.kind != .undo }.count
    }
}
