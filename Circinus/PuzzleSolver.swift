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

struct SolveResult {
    let isSolved: Bool
    let connectedTiles: Set<GridCoord>
    let leakyTiles: Set<GridCoord>
}

// MARK: - PuzzleSolver

final class PuzzleSolver {

    static func solve(grid: [[TileNode]], cols: Int, rows: Int) -> SolveResult {
        // Pass 1: Leak detection
        var leaky = Set<GridCoord>()
        var paired = Set<GridCoord>()

        for row in 0..<rows {
            for col in 0..<cols {
                let coord = GridCoord(col: col, row: row)
                let tile = grid[row][col]
                var tileIsLeaky = false

                for side in tile.activeConnections {
                    let nCoord = coord.neighbour(in: side)

                    // Check bounds
                    guard nCoord.col >= 0, nCoord.col < cols,
                          nCoord.row >= 0, nCoord.row < rows else {
                        tileIsLeaky = true
                        continue
                    }

                    // Check reciprocal connection
                    let neighbour = grid[nCoord.row][nCoord.col]
                    if !neighbour.activeConnections.contains(side.opposite) {
                        tileIsLeaky = true
                    }
                }

                if tileIsLeaky {
                    leaky.insert(coord)
                } else {
                    paired.insert(coord)
                }
            }
        }

        // Pass 2: Connectivity BFS
        guard let start = paired.first else {
            return SolveResult(isSolved: false, connectedTiles: [], leakyTiles: leaky)
        }

        var visited = Set<GridCoord>()
        var queue = [start]
        visited.insert(start)

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let tile = grid[current.row][current.col]

            for side in tile.activeConnections {
                let next = current.neighbour(in: side)
                if paired.contains(next), !visited.contains(next) {
                    visited.insert(next)
                    queue.append(next)
                }
            }
        }

        let isSolved = leaky.isEmpty && visited.count == cols * rows
        return SolveResult(isSolved: isSolved, connectedTiles: visited, leakyTiles: leaky)
    }
}
