import Foundation

// MARK: - Level Data Types

struct TileData: Codable {
    let type: String
    let rotation: Int
    let locked: Bool?

    // §1–§5: optional mechanic fields — absent = no special behaviour.
    // Defaults to nil so existing memberwise callers (e.g. fallbackLevels())
    // don't need to pass these arguments, and old JSON without these keys
    // decodes cleanly (Codable treats absent optional keys as nil).
    //
    // role encoding:
    //   "diode"               → TileRole.diode
    //   "mixer"               → TileRole.mixer
    //   "fragile"             → TileRole.fragile(limit: fragileLimit ?? 3)
    //   "source:right:red"    → TileRole.source(side: .right, color: .red)
    //   "sink:left:blue"      → TileRole.sink(side: .left, required: .blue)
    let role: String?         = nil
    let quantumGroup: String? = nil     // §3 — co-rotation tag
    let fragileLimit: Int?    = nil     // §4 — companion to role = "fragile"

    /// Parsed `TileRole` value.  Returns `.normal` for any unknown/absent role
    /// so old levels and hand-edited JSON degrade gracefully.
    var parsedRole: TileRole {
        guard let r = role else { return .normal }
        switch r {
        case "diode":  return .diode
        case "mixer":  return .mixer
        case "fragile":
            return .fragile(limit: fragileLimit ?? 3)
        default:
            // Compound roles: "source:side:color" or "sink:side:required"
            let parts = r.split(separator: ":").map(String.init)
            guard parts.count == 3,
                  let side = ConnectionSide(rawValue: parts[1]) else { return .normal }
            switch parts[0] {
            case "source":
                if let color = EnergyColor(rawValue: parts[2]) {
                    return .source(side: side, color: color)
                }
            case "sink":
                if let req = EnergyColor(rawValue: parts[2]) {
                    return .sink(side: side, required: req)
                }
            default: break
            }
            return .normal
        }
    }
}

struct LevelData: Codable {
    let id: Int
    let name: String
    let gridCols: Int
    let gridRows: Int
    let tileSize: Int
    let tiles: [[TileData]]
    let par: Int
}

struct LevelPack: Codable {
    let version: Int
    let levels: [LevelData]
}

// MARK: - Errors

enum LevelLoaderError: Error {
    case fileNotFound(String)
    case decodingFailed(Error)
}

// MARK: - LevelLoader

final class LevelLoader {

    private static var cache: [String: LevelPack] = [:]

    static func load(packName: String = "levels") throws -> LevelPack {
        if let cached = cache[packName] {
            return cached
        }

        guard let url = Bundle.main.url(forResource: packName, withExtension: "json") else {
            throw LevelLoaderError.fileNotFound(packName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LevelLoaderError.fileNotFound(packName)
        }

        let pack: LevelPack
        do {
            pack = try JSONDecoder().decode(LevelPack.self, from: data)
        } catch {
            throw LevelLoaderError.decodingFailed(error)
        }

        cache[packName] = pack
        return pack
    }

    static func level(_ index: Int, from packName: String = "levels") throws -> LevelData {
        let pack = try load(packName: packName)
        guard let level = pack.levels.first(where: { $0.id == index }) else {
            throw LevelLoaderError.fileNotFound("Level \(index) not found in \(packName)")
        }
        return level
    }

    static func validate(_ level: LevelData) -> Bool {
        guard level.tiles.count == level.gridRows else { return false }
        for row in level.tiles {
            guard row.count == level.gridCols else { return false }
        }
        return true
    }

    static func fallbackLevels() -> [LevelData] {
        return [
            LevelData(
                id: 1,
                name: "Starter Loop",
                gridCols: 3,
                gridRows: 3,
                tileSize: 95,
                tiles: [
                    [
                        TileData(type: "corner",   rotation: 1, locked: false),
                        TileData(type: "straight", rotation: 1, locked: false),
                        TileData(type: "corner",   rotation: 2, locked: false)
                    ],
                    [
                        TileData(type: "straight", rotation: 0, locked: false),
                        TileData(type: "empty",    rotation: 0, locked: true),
                        TileData(type: "straight", rotation: 0, locked: false)
                    ],
                    [
                        TileData(type: "corner",   rotation: 0, locked: false),
                        TileData(type: "straight", rotation: 1, locked: false),
                        TileData(type: "corner",   rotation: 3, locked: false)
                    ]
                ],
                par: 6
            ),
            LevelData(
                id: 2,
                name: "Junction City",
                gridCols: 4,
                gridRows: 4,
                tileSize: 82,
                tiles: [
                    [
                        TileData(type: "corner", rotation: 1, locked: false),
                        TileData(type: "tee",    rotation: 1, locked: false),
                        TileData(type: "tee",    rotation: 1, locked: false),
                        TileData(type: "corner", rotation: 2, locked: false)
                    ],
                    [
                        TileData(type: "tee",   rotation: 0, locked: false),
                        TileData(type: "cross", rotation: 0, locked: false),
                        TileData(type: "cross", rotation: 0, locked: false),
                        TileData(type: "tee",   rotation: 2, locked: false)
                    ],
                    [
                        TileData(type: "tee",   rotation: 0, locked: false),
                        TileData(type: "cross", rotation: 1, locked: false),
                        TileData(type: "cross", rotation: 3, locked: false),
                        TileData(type: "tee",   rotation: 2, locked: false)
                    ],
                    [
                        TileData(type: "corner", rotation: 0, locked: false),
                        TileData(type: "tee",    rotation: 3, locked: false),
                        TileData(type: "tee",    rotation: 3, locked: false),
                        TileData(type: "corner", rotation: 3, locked: false)
                    ]
                ],
                par: 10
            )
        ]
    }
}
