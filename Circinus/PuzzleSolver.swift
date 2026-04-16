import Foundation

// MARK: - GridCoord

struct GridCoord: Hashable {
    let col: Int
    let row: Int

    func neighbour(in direction: ConnectionSide) -> GridCoord {
        switch direction {
        case .top:    return GridCoord(col: col, row: row - 1)
        case .bottom: return GridCoord(col: col, row: row + 1)
        case .left:   return GridCoord(col: col - 1, row: row)
        case .right:  return GridCoord(col: col + 1, row: row)
        }
    }
}

// MARK: - SolveResult
//
// Extended to surface the state each new mechanic needs:
//   * `energy`              — the colour the solver believes is flowing in
//                             each tile; GameScene uses this to paint pipes.
//   * `satisfiedSinks`      — sinks receiving the correct colour.
//   * `unsatisfiedSinks`    — sinks that are dark, leaking, or wrong-coloured.
//   * `brokenTiles`         — tiles shattered by the Overload mechanic (§4).
//   * `shortedTiles`        — non-mixer tiles where two different colours
//                             collided, which is an explicit fail state the
//                             UI flags in red.
//   * `blockedDiodes`       — §5 pedagogical signal: diode tiles where energy
//                             arrived at the outFace (backwards) and was
//                             silently dropped in Pass 2. GameScene uses this
//                             to fire a one-shot rejection pulse, converting
//                             the silent-drop state into a legible constraint.
//   * `superposedChoices`   — §6 per-solve record of which uncollapsed
//                             superposed tiles were placed in state B to reach
//                             this solution. Empty when no superposed tiles
//                             exist or when the solve failed. NOT persisted to
//                             save files — it is a per-solve property only.

struct SolveResult {
    let isSolved: Bool
    let connectedTiles: Set<GridCoord>
    let leakyTiles: Set<GridCoord>
    let energy: [GridCoord: EnergyColor]
    let satisfiedSinks: Set<GridCoord>
    let unsatisfiedSinks: Set<GridCoord>
    let brokenTiles: Set<GridCoord>
    let shortedTiles: Set<GridCoord>
    let blockedDiodes: Set<GridCoord>
    /// Which uncollapsed superposed tiles were placed in state B to achieve
    /// this solution. `true` = state B chosen; `false` = state A chosen.
    /// Empty when the board has no superposed tiles, or when every branch
    /// failed (in which case `isSolved` is also `false`).
    let superposedChoices: [GridCoord: Bool]
}

// MARK: - PuzzleSolver
//
// The solver now runs three passes:
//
//   Pass 1 — Topology.  Build a set of valid adjacency edges: two tiles
//            are edge-linked iff they are in-bounds, neither is broken,
//            and they both expose the connecting face via
//            `effectiveConnections`. Tiles with any dangling face are
//            marked leaky (legacy behaviour).
//
//   Pass 2 — Flow.     Fixed-point colour propagation. Seed every source
//            with its colour, then relax along the adjacency graph.
//            Mixers combine every incoming colour and re-emit the result.
//            Non-mixer collisions between different colours flag a short.
//
//   Pass 3 — Goal.     If the level defines any sinks, the win condition
//            is "every sink receives its required colour and no leaks or
//            shorts remain." If it defines none, fall back to the legacy
//            single-closed-loop rule for full backward compatibility.
//
// §6 Superposition branching (milestone 1.5):
//
//   When the board contains uncollapsed superposed tiles the solver
//   enumerates all 2^N configurations (N ≤ 4, enforced by precondition).
//   Each configuration is tried by `solveSingle`, which respects a
//   `choices` dict that temporarily pins each superposed tile to a single
//   state instead of the default union.  The first successful branch is
//   returned together with its `superposedChoices` record.
//
//   Enumeration order is 0 … 2^N−1 (non-recursive bitmask), so the
//   all-state-A combination (mask 0) is always tried first — giving the
//   lexicographic preference for state A described in the spec.

final class PuzzleSolver {

    // MARK: - Public entry point

    /// Solve the board, branching over uncollapsed superposed tiles (§6).
    ///
    /// The level-design contract caps uncollapsed superposed tiles at 4
    /// (16 branches maximum).  Exceeding this trips a `precondition`.
    ///
    /// If multiple branches solve, the one with the fewest state-B choices
    /// is returned (the all-state-A branch, mask 0, is tried first).
    static func solve(grid: [[TileNode]], cols: Int, rows: Int) -> SolveResult {
        let superposed = collectUncollapsedSuperposed(grid: grid, cols: cols, rows: rows)

        // Level-design contract: max 4 uncollapsed superposed tiles per level.
        // Document in the level JSON schema: more than 4 is undefined behaviour.
        precondition(
            superposed.count <= 4,
            "Level has \(superposed.count) uncollapsed superposed tiles; max is 4. " +
            "Reduce in the level JSON or collapse tiles before play begins."
        )

        // Fast path: no superposed tiles — no branching overhead.
        if superposed.isEmpty {
            return solveSingle(grid: grid, cols: cols, rows: rows, choices: [:])
        }

        // Enumerate all 2^N combinations via bitmask (non-recursive).
        // bit-i of `mask` == 1  →  superposed[i] is placed in state B.
        // mask == 0             →  all tiles in state A (tried first).
        for mask in 0 ..< (1 << superposed.count) {
            var choices: [GridCoord: Bool] = [:]
            for (i, coord) in superposed.enumerated() {
                choices[coord] = (mask >> i) & 1 == 1
            }
            let result = solveSingle(grid: grid, cols: cols, rows: rows, choices: choices)
            if result.isSolved { return result }
        }

        // No branch solved.  Return the all-state-A configuration for its
        // diagnostic info (leaky tiles, blocked diodes, etc.).  `isSolved`
        // will be false, and `superposedChoices` will record all tiles as A.
        var allAChoices: [GridCoord: Bool] = [:]
        for coord in superposed { allAChoices[coord] = false }
        return solveSingle(grid: grid, cols: cols, rows: rows, choices: allAChoices)
    }

    // MARK: - Private helpers

    /// Collect the coords of every tile whose role is `.superposed` with
    /// `collapsed == false`.  These form the branching set for `solve`.
    private static func collectUncollapsedSuperposed(
        grid: [[TileNode]],
        cols: Int,
        rows: Int
    ) -> [GridCoord] {
        var result: [GridCoord] = []
        for row in 0..<rows {
            for col in 0..<cols {
                if case .superposed(_, _, false, _) = grid[row][col].role {
                    result.append(GridCoord(col: col, row: row))
                }
            }
        }
        return result
    }

    /// Returns the effective connections for `tile` at `coord`, honouring
    /// the per-branch `choices` override.
    ///
    /// If `coord` appears in `choices`, the tile is treated as already
    /// collapsed to the indicated state (false = A, true = B) rather than
    /// using the union of both states that `tile.effectiveConnections` would
    /// return for an uncollapsed superposed tile.  All other tiles delegate
    /// directly to `tile.effectiveConnections`.
    private static func effectiveConnections(
        for tile: TileNode,
        at coord: GridCoord,
        choices: [GridCoord: Bool]
    ) -> Set<ConnectionSide> {
        if let useB = choices[coord],
           case .superposed(let a, let b, _, _) = tile.role {
            let offset = useB ? b : a
            return tile.connectionsAt(rotation: offset + tile.rotationSteps)
        }
        return tile.effectiveConnections
    }

    /// Single-configuration three-pass solve.
    ///
    /// `choices` pins individual superposed tiles to a specific state for
    /// this run; all other tiles use their normal `effectiveConnections`.
    /// When `choices` is empty this is identical to the pre-1.5 behaviour.
    private static func solveSingle(
        grid: [[TileNode]],
        cols: Int,
        rows: Int,
        choices: [GridCoord: Bool]
    ) -> SolveResult {

        // ------------------------------------------------------------------
        // Pass 1: topology + leak detection
        // ------------------------------------------------------------------
        var leaky      = Set<GridCoord>()
        var paired     = Set<GridCoord>()
        var broken     = Set<GridCoord>()
        var emptyNodes = Set<GridCoord>()
        var sources    = [(GridCoord, EnergyColor)]()
        var sinks      = [(GridCoord, ConnectionSide, EnergyColor)]()

        for row in 0..<rows {
            for col in 0..<cols {
                let coord = GridCoord(col: col, row: row)
                let tile  = grid[row][col]

                if tile.tileType == .empty {
                    emptyNodes.insert(coord)
                    continue
                }

                if tile.isBroken {
                    broken.insert(coord)
                    // Broken tiles have no effective connections, so any
                    // neighbour pointing at them will itself become leaky
                    // on its own iteration. Skip the per-side check here.
                    continue
                }

                var tileIsLeaky = false
                for side in effectiveConnections(for: tile, at: coord, choices: choices) {
                    let n = coord.neighbour(in: side)
                    guard n.col >= 0, n.col < cols, n.row >= 0, n.row < rows else {
                        tileIsLeaky = true; continue
                    }
                    let nTile = grid[n.row][n.col]
                    if nTile.isBroken ||
                       !effectiveConnections(for: nTile, at: n, choices: choices).contains(side.opposite) {
                        tileIsLeaky = true
                    }
                }
                if tileIsLeaky { leaky.insert(coord) } else { paired.insert(coord) }

                switch tile.role {
                case .source(_, let c):         sources.append((coord, c))
                case .sink(let s, let req):     sinks.append((coord, s, req))
                default: break
                }
            }
        }

        // ------------------------------------------------------------------
        // Pass 2: directed colour propagation (§1, §2)
        // ------------------------------------------------------------------
        //
        // We use a worklist fixed-point: seed sources, then relax across
        // the paired adjacency graph. A non-mixer tile carries exactly one
        // colour; if a second distinct colour arrives, it is a short.
        // Mixers accumulate inputs and re-emit mix(all).
        //
        // Complexity: O((V + E) · C) where C is the number of distinct
        // colour states (≤ 4). On typical 8×8 boards this is trivial.

        var energy        = [GridCoord: EnergyColor]()
        var shorted       = Set<GridCoord>()
        // §5 Diode rejection: coords where energy arrived at the wrong face.
        // Populated only in Pass 2 — does not affect topology or goal logic.
        var blockedDiodes = Set<GridCoord>()

        // Seed sources (they are their own first energy state).
        for (coord, colour) in sources { energy[coord] = colour }

        var changed = true
        while changed {
            changed = false

            for coord in paired {
                guard let outgoing = energy[coord] else { continue }
                let tile = grid[coord.row][coord.col]

                // Mixers do not forward on the same pass — their output is
                // produced separately below from the union of inputs.
                if tile.role.isMixer { continue }

                // §5 Diode: pre-compute this tile's out-face once per coord
                // so we don't repeat the rotation math for every side below.
                let sourceDiodeFaces = tile.role.isDiode ? tile.diodeFaces : nil

                for side in effectiveConnections(for: tile, at: coord, choices: choices) {
                    // §5 Diode: a diode may only emit energy on its outFace.
                    // Energy cannot exit backward through the inFace.
                    if let df = sourceDiodeFaces, side != df.outFace { continue }

                    let n = coord.neighbour(in: side)
                    guard paired.contains(n) else { continue }
                    let nTile = grid[n.row][n.col]
                    // Must be a reciprocated edge.
                    guard effectiveConnections(for: nTile, at: n, choices: choices).contains(side.opposite) else { continue }

                    // §5 Diode: energy may only *enter* a diode at its inFace.
                    // Arriving at the outFace (backwards) silently drops the
                    // flow — the pipe goes dark rather than flagging a short,
                    // because the diode is topologically valid; it just blocks.
                    // Record the coord so GameScene can fire a rejection pulse
                    // (pedagogical signal — does not alter any flow logic).
                    if nTile.role.isDiode && side.opposite != nTile.diodeFaces.inFace {
                        blockedDiodes.insert(n)
                        continue
                    }

                    if nTile.role.isMixer {
                        // Accumulate into the mixer; mixers are handled
                        // explicitly in the mixer pass below.
                        let combined = EnergyColor.mix(energy[n] ?? .none, outgoing)
                        if energy[n] != combined {
                            energy[n] = combined
                            changed = true
                        }
                    } else {
                        if let existing = energy[n] {
                            if existing != outgoing {
                                // Two different colours meeting on a plain
                                // wire = explicit short. Player must fix.
                                if shorted.insert(n).inserted { changed = true }
                            }
                        } else {
                            energy[n] = outgoing
                            changed = true
                        }
                    }
                }
            }

            // Mixer re-emit pass. A mixer's "outgoing" colour is simply its
            // current accumulated energy — because we defined mix(c, .none)
            // = c and mix is associative/commutative, propagating the
            // mixer's energy[coord] on its faces achieves the spec.
            for coord in paired {
                let tile = grid[coord.row][coord.col]
                guard tile.role.isMixer, let out = energy[coord], out != .none else { continue }
                for side in effectiveConnections(for: tile, at: coord, choices: choices) {
                    let n = coord.neighbour(in: side)
                    guard paired.contains(n) else { continue }
                    let nTile = grid[n.row][n.col]
                    guard effectiveConnections(for: nTile, at: n, choices: choices).contains(side.opposite) else { continue }

                    // §5 Diode: mixer output obeys the same inFace rule.
                    if nTile.role.isDiode && side.opposite != nTile.diodeFaces.inFace {
                        blockedDiodes.insert(n)
                        continue
                    }

                    if nTile.role.isMixer {
                        let combined = EnergyColor.mix(energy[n] ?? .none, out)
                        if energy[n] != combined { energy[n] = combined; changed = true }
                    } else {
                        if let existing = energy[n] {
                            if existing != out, shorted.insert(n).inserted { changed = true }
                        } else {
                            energy[n] = out
                            changed = true
                        }
                    }
                }
            }
        }

        // Also consider "connected" as the union of all tiles reachable
        // from any source. Legacy levels with no sources fall back to
        // BFS-from-first-paired, preserving the old "one loop" semantics.
        var connected = Set<GridCoord>()
        if !sources.isEmpty {
            connected = Set(energy.keys).intersection(paired)
        } else if let start = paired.first {
            var queue = [start]; connected.insert(start)
            while !queue.isEmpty {
                let c = queue.removeFirst()
                let tile = grid[c.row][c.col]
                for side in effectiveConnections(for: tile, at: c, choices: choices) {
                    let n = c.neighbour(in: side)
                    if paired.contains(n), !connected.contains(n) {
                        connected.insert(n); queue.append(n)
                    }
                }
            }
        }

        // ------------------------------------------------------------------
        // Pass 3: goal evaluation
        // ------------------------------------------------------------------
        var satisfied   = Set<GridCoord>()
        var unsatisfied = Set<GridCoord>()

        for (coord, _, required) in sinks {
            // A sink is satisfied iff it is paired (no leak), not shorted,
            // and the colour arriving at it matches `required`.
            if !paired.contains(coord) || shorted.contains(coord) {
                unsatisfied.insert(coord); continue
            }
            if (energy[coord] ?? .none) == required {
                satisfied.insert(coord)
            } else {
                unsatisfied.insert(coord)
            }
        }

        let solved: Bool = {
            guard leaky.isEmpty, shorted.isEmpty else { return false }
            if sinks.isEmpty {
                // Legacy rule: every tile on a single connected loop.
                return connected.count == cols * rows - broken.count - emptyNodes.count
            }
            // New rule: all sinks satisfied.
            return unsatisfied.isEmpty && !sinks.isEmpty
        }()

        return SolveResult(
            isSolved: solved,
            connectedTiles: connected,
            leakyTiles: leaky,
            energy: energy,
            satisfiedSinks: satisfied,
            unsatisfiedSinks: unsatisfied,
            brokenTiles: broken,
            shortedTiles: shorted,
            blockedDiodes: blockedDiodes,
            superposedChoices: choices
        )
    }
}
