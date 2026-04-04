import Foundation

// MARK: - Level Data Types

struct TileData: Codable {
    let type: String
    let rotation: Int
    let locked: Bool?
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
                        TileData(type: "corner",   rotation: 2, locked: false),
                        TileData(type: "straight", rotation: 1, locked: false),
                        TileData(type: "corner",   rotation: 3, locked: false)
                    ],
                    [
                        TileData(type: "straight", rotation: 0, locked: false),
                        TileData(type: "cross",    rotation: 0, locked: true),
                        TileData(type: "straight", rotation: 0, locked: false)
                    ],
                    [
                        TileData(type: "corner",   rotation: 1, locked: false),
                        TileData(type: "straight", rotation: 1, locked: false),
                        TileData(type: "corner",   rotation: 0, locked: false)
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
                        TileData(type: "corner", rotation: 2, locked: false),
                        TileData(type: "tee",    rotation: 3, locked: false),
                        TileData(type: "tee",    rotation: 3, locked: false),
                        TileData(type: "corner", rotation: 3, locked: false)
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
                        TileData(type: "corner", rotation: 1, locked: false),
                        TileData(type: "tee",    rotation: 1, locked: false),
                        TileData(type: "tee",    rotation: 1, locked: false),
                        TileData(type: "corner", rotation: 0, locked: false)
                    ]
                ],
                par: 10
            )
        ]
    }
}
