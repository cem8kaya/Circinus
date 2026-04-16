import Foundation

// MARK: - PatternHighlight

/// A single detected choreography pattern within a solve trace.
struct PatternHighlight {
    /// Short machine-readable kind tag, e.g. "mirrored-pair", "palindrome".
    let kind: String
    /// 1-based move indices (from MoveEntry.moveIndex) that contribute to this pattern.
    let moveIndices: [Int]
    /// Points awarded for this pattern (capped per-pattern so one trick can't dominate).
    let points: Int
    /// Human-readable description for UI display.
    let description: String
}

// MARK: - ChoreographyScore

/// The full choreography result returned by ChoreographyAnalyzer.analyze().
struct ChoreographyScore {
    /// Total points (0–100, clamped).
    let points: Int
    /// Star rating: 1 = 0–40 pts, 2 = 41–75 pts, 3 = 76+ pts.
    let stars: Int
    /// Every pattern that fired during analysis.
    let highlights: [PatternHighlight]
}

// MARK: - ChoreographyAnalyzer

/// Pure, stateless analyzer. No SpriteKit dependencies. Thread-safe.
///
/// Call `analyze(trace:level:)` after the player wins to get a ChoreographyScore.
/// Each of the four detectors fires at most once per solve; individual move-pairs
/// cannot double-count across detectors.
///
/// Point → star mapping:
///   0–40  → 1★
///   41–75 → 2★
///   76+   → 3★
enum ChoreographyAnalyzer {

    static func analyze(trace: MoveTrace, level: LevelData) -> ChoreographyScore {
        var highlights: [PatternHighlight] = []
        highlights += detectAxialSymmetry(trace, cols: level.gridCols, rows: level.gridRows)
        highlights += detectPalindromes(trace)
        highlights += detectCadence(trace)
        highlights += detectClosure(trace, cols: level.gridCols, rows: level.gridRows)

        let total = min(100, highlights.reduce(0) { $0 + $1.points })
        let stars = total >= 76 ? 3 : total >= 41 ? 2 : 1
        return ChoreographyScore(points: total, stars: stars, highlights: highlights)
    }

    // MARK: - Axial Symmetry

    /// Awards 20 pts when any two rotation entries contain tiles that are
    /// mirror images of each other across the grid centre.
    /// Only the first qualifying pair is counted (per-pattern-fires-once rule).
    private static func detectAxialSymmetry(
        _ trace: MoveTrace,
        cols: Int,
        rows: Int
    ) -> [PatternHighlight] {

        let rotates = trace.entries.filter { $0.kind != .undo }
        guard rotates.count >= 2 else { return [] }

        // Mirror a coordinate through the grid centre.
        func mirror(_ c: GridCoord) -> GridCoord {
            GridCoord(col: cols - 1 - c.col, row: rows - 1 - c.row)
        }

        for i in 0..<rotates.count {
            let ei = rotates[i]
            let mirroredI = Set(ei.coords.map { mirror($0) })

            for j in (i + 1)..<rotates.count {
                let ej = rotates[j]
                let jSet = Set(ej.coords)

                // All mirrored coords of entry i must appear in entry j.
                if mirroredI.isSubset(of: jSet) {
                    return [PatternHighlight(
                        kind: "mirrored-pair",
                        moveIndices: [ei.moveIndex, ej.moveIndex],
                        points: 20,
                        description: "Mirrored pair at moves \(ei.moveIndex) and \(ej.moveIndex)"
                    )]
                }
            }
        }

        return []
    }

    // MARK: - Palindromes

    /// Awards up to 30 pts when a contiguous run of ≥3 rotation entries has
    /// rotationAfter values that form a palindrome (e.g. [1, 2, 3, 2, 1]).
    /// Finds the longest qualifying run; scores 8 pts per entry, capped at 30.
    private static func detectPalindromes(_ trace: MoveTrace) -> [PatternHighlight] {
        let rotates = trace.entries.filter { $0.kind != .undo }
        guard rotates.count >= 3 else { return [] }

        // Use the first coord's rotationAfter value as the representative scalar.
        let values = rotates.map { $0.rotationAfter.first ?? 0 }

        var bestStart = 0
        var bestLen   = 0

        for start in 0..<values.count {
            for len in stride(from: values.count - start, through: 3, by: -1) {
                let sub = Array(values[start ..< (start + len)])
                if sub == sub.reversed() && len > bestLen {
                    bestLen  = len
                    bestStart = start
                    break   // longest found for this start; move to next start
                }
            }
        }

        guard bestLen >= 3 else { return [] }

        let subEntries = Array(rotates[bestStart ..< (bestStart + bestLen)])
        let pts = min(30, bestLen * 8)

        return [PatternHighlight(
            kind: "palindrome",
            moveIndices: subEntries.map { $0.moveIndex },
            points: pts,
            description: "Palindrome across \(bestLen) moves"
        )]
    }

    // MARK: - Cadence

    /// Awards 15–25 pts when inter-move intervals have a coefficient of variation
    /// below 0.30 (rhythmic play). Requires ≥4 rotation entries.
    /// CV < 0.15 → 25 pts; CV 0.15–0.30 → 15 pts.
    private static func detectCadence(_ trace: MoveTrace) -> [PatternHighlight] {
        let rotates = trace.entries.filter { $0.kind != .undo }
        guard rotates.count >= 4 else { return [] }

        let timestamps = rotates.map { $0.timestamp }
        var intervals: [Double] = []
        for i in 1..<timestamps.count {
            let delta = timestamps[i] - timestamps[i - 1]
            // Ignore implausibly long gaps (e.g. app backgrounded).
            if delta > 0 && delta < 10.0 {
                intervals.append(delta)
            }
        }
        guard intervals.count >= 3 else { return [] }

        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0.05 else { return [] }   // sub-50ms mean is noise

        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
            / Double(intervals.count)
        let stdDev = variance.squareRoot()
        let cv     = stdDev / mean

        guard cv < 0.30 else { return [] }

        let pts = cv < 0.15 ? 25 : 15
        return [PatternHighlight(
            kind: "cadence",
            moveIndices: rotates.map { $0.moveIndex },
            points: pts,
            description: "Rhythmic play (CV=\(String(format: "%.2f", cv)))"
        )]
    }

    // MARK: - Closure

    /// Awards 20 pts when the final N moves (up to 5) touch a contiguous path
    /// of adjacent grid cells — left-to-right or in any direction.
    /// Requires ≥3 rotation entries overall.
    private static func detectClosure(
        _ trace: MoveTrace,
        cols: Int,
        rows: Int
    ) -> [PatternHighlight] {

        let rotates = trace.entries.filter { $0.kind != .undo }
        guard rotates.count >= 3 else { return [] }

        let windowSize = min(rotates.count, 5)
        let window     = Array(rotates[(rotates.count - windowSize)...])

        // Flatten all coordinates touched in the window, preserving order.
        let allCoords  = window.flatMap { $0.coords }
        guard allCoords.count >= 2 else { return [] }

        // Verify each consecutive pair is grid-adjacent (no diagonals).
        func adjacent(_ a: GridCoord, _ b: GridCoord) -> Bool {
            (abs(a.col - b.col) == 1 && a.row == b.row) ||
            (abs(a.row - b.row) == 1 && a.col == b.col)
        }

        let contiguous = zip(allCoords, allCoords.dropFirst()).allSatisfy { adjacent($0, $1) }
        guard contiguous else { return [] }

        return [PatternHighlight(
            kind: "closure",
            moveIndices: window.map { $0.moveIndex },
            points: 20,
            description: "Contiguous closing path across last \(windowSize) moves"
        )]
    }
}
