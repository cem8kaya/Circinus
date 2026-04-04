import SpriteKit
import UIKit

// MARK: - GameSceneDelegate

protocol GameSceneDelegate: AnyObject {
    func gameScene(_ scene: GameScene, didCompleteLevel levelID: Int,
                   moves: Int, stars: Int)
}

// MARK: - GameScene

final class GameScene: SKScene {

    weak var gameDelegate: GameSceneDelegate?

    private var levelData: LevelData!
    private var tileGrid: [[TileNode]] = []
    private var gridContainer: SKNode!
    private var cols: Int = 0
    private var rows: Int = 0
    private var isSolved: Bool = false
    private var par: Int = 0

    private var movesLabel: SKLabelNode!
    private var levelLabel: SKLabelNode!

    private var moveCount: Int = 0 {
        didSet {
            movesLabel?.text = "Moves: \(moveCount)"
        }
    }

    private var solverWorkItem: DispatchWorkItem?

    // MARK: - Scene setup

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        setupHUD()
    }

    private func setupHUD() {
        movesLabel = SKLabelNode(fontNamed: "AvenirNext-Medium")
        movesLabel.fontSize = 18
        movesLabel.fontColor = .white
        movesLabel.horizontalAlignmentMode = .left
        movesLabel.verticalAlignmentMode = .top
        movesLabel.position = CGPoint(x: 20, y: size.height - 50)
        movesLabel.zPosition = 90
        movesLabel.text = "Moves: 0"
        addChild(movesLabel)

        levelLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        levelLabel.fontSize = 20
        levelLabel.fontColor = .white
        levelLabel.horizontalAlignmentMode = .center
        levelLabel.verticalAlignmentMode = .top
        levelLabel.position = CGPoint(x: size.width / 2, y: size.height - 50)
        levelLabel.zPosition = 90
        addChild(levelLabel)
    }

    // MARK: - Load level

    func loadLevel(_ levelData: LevelData) {
        self.levelData = levelData
        self.cols = levelData.gridCols
        self.rows = levelData.gridRows
        self.par = levelData.par
        self.moveCount = 0
        self.isSolved = false

        // Clear previous grid
        gridContainer?.removeFromParent()
        gridContainer = SKNode()
        gridContainer.zPosition = 10
        addChild(gridContainer)

        levelLabel?.text = levelData.name

        let tileSize = CGFloat(levelData.tileSize)
        let totalW = CGFloat(cols) * tileSize
        let totalH = CGFloat(rows) * tileSize
        let gridOriginX = (size.width - totalW) / 2
        let gridOriginY = (size.height - totalH) / 2 + 40

        tileGrid = []

        for row in 0..<rows {
            var rowNodes: [TileNode] = []
            for col in 0..<cols {
                let td = levelData.tiles[row][col]
                guard let tileType = TileType(rawValue: td.type) else { continue }

                let tile = TileNode(type: tileType, size: tileSize, initialRotation: td.rotation)

                // SpriteKit Y-up: row 0 (top) maps to high Y
                let x = gridOriginX + CGFloat(col) * tileSize + tileSize / 2
                let y = size.height - (gridOriginY + CGFloat(row) * tileSize + tileSize / 2)
                tile.position = CGPoint(x: x, y: y)

                // Locked tiles
                if td.locked == true {
                    tile.isUserInteractionEnabled = false
                    let badge = SKShapeNode(circleOfRadius: tileSize * 0.10)
                    badge.fillColor = UIColor(red: 1.0, green: 0.78, blue: 0.20, alpha: 1)
                    badge.strokeColor = .clear
                    badge.zPosition = 6
                    badge.position = CGPoint(x: tileSize / 2 - tileSize * 0.18,
                                             y: tileSize / 2 - tileSize * 0.18)
                    tile.addChild(badge)
                }

                gridContainer.addChild(tile)
                rowNodes.append(tile)
            }
            tileGrid.append(rowNodes)
        }

        animateGridEntrance()
    }

    // MARK: - Grid entrance animation

    private func animateGridEntrance() {
        for row in 0..<tileGrid.count {
            for col in 0..<tileGrid[row].count {
                let tile = tileGrid[row][col]
                tile.alpha = 0
                tile.setScale(0.6)
                tile.run(SKAction.sequence([
                    SKAction.wait(forDuration: Double(row + col) * 0.04),
                    SKAction.group([
                        SKAction.fadeIn(withDuration: 0.25),
                        SKAction.scale(to: 1.0, duration: 0.25)
                    ])
                ]))
            }
        }
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isSolved, let touch = touches.first else { return }
        let loc = touch.location(in: gridContainer)

        for child in gridContainer.children {
            guard let tile = child as? TileNode else { continue }
            guard tile.isUserInteractionEnabled else { continue }

            let tileFrame = tile.calculateAccumulatedFrame()
            if tileFrame.contains(loc) {
                tile.rotate { [weak self] in
                    self?.moveCount += 1
                    self?.scheduleCompletionCheck()
                }
                return // Only rotate one tile per touch
            }
        }
    }

    // MARK: - Completion check

    private func scheduleCompletionCheck() {
        solverWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.checkCompletion()
        }
        solverWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func checkCompletion() {
        let result = PuzzleSolver.solve(grid: tileGrid, cols: cols, rows: rows)

        for row in 0..<tileGrid.count {
            for col in 0..<tileGrid[row].count {
                let coord = GridCoord(col: col, row: row)
                tileGrid[row][col].isConnected = result.connectedTiles.contains(coord)
            }
        }

        if result.isSolved && !isSolved {
            isSolved = true
            let stars = calculateStars()
            triggerWinSequence(stars: stars)
            gameDelegate?.gameScene(self, didCompleteLevel: levelData.id,
                                    moves: moveCount, stars: stars)
        }
    }

    private func calculateStars() -> Int {
        if moveCount <= par     { return 3 }
        if moveCount <= par * 2 { return 2 }
        return 1
    }

    // MARK: - Win sequence

    private func triggerWinSequence(stars: Int) {
        // 1. Grid container scale pulse
        let pulseUp   = SKAction.scale(to: 1.06, duration: 0.12)
        let pulseDown = SKAction.scale(to: 1.0, duration: 0.12)
        gridContainer.run(SKAction.sequence([pulseUp, pulseDown]))

        // 2. Particle burst from each tile
        let burstColors: [UIColor] = [
            UIColor(red: 0.20, green: 0.82, blue: 0.56, alpha: 1),
            UIColor(red: 0.40, green: 0.70, blue: 1.00, alpha: 1),
            UIColor(red: 1.00, green: 0.78, blue: 0.20, alpha: 1)
        ]

        for row in tileGrid {
            for tile in row {
                let worldPos = tile.position
                for _ in 0..<6 {
                    let dot = SKShapeNode(circleOfRadius: 3)
                    dot.fillColor = burstColors.randomElement() ?? burstColors[0]
                    dot.strokeColor = .clear
                    dot.position = worldPos
                    dot.zPosition = 50
                    gridContainer.addChild(dot)

                    let angle = CGFloat.random(in: 0...(.pi * 2))
                    let speed = CGFloat.random(in: 40...110)
                    let dx = cos(angle) * speed
                    let dy = sin(angle) * speed

                    let move = SKAction.moveBy(x: dx, y: dy, duration: 0.5)
                    move.timingMode = .easeOut
                    let scaleDown = SKAction.scale(to: 0.1, duration: 0.5)
                    let fadeOut = SKAction.fadeOut(withDuration: 0.5)
                    let group = SKAction.group([move, scaleDown, fadeOut])

                    dot.run(group) {
                        dot.removeFromParent()
                    }
                }
            }
        }

        // 3. Show completion banner after particles
        run(SKAction.sequence([
            SKAction.wait(forDuration: 0.5),
            SKAction.run { [weak self] in
                self?.showCompletionBanner(stars: stars)
            }
        ]))

        // 4. Success haptic
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    // MARK: - Completion banner

    private func showCompletionBanner(stars: Int) {
        let banner = SKNode()
        banner.zPosition = 100
        banner.position = CGPoint(x: size.width / 2, y: size.height / 2)
        banner.setScale(0.1)
        banner.alpha = 0

        // Card background
        let card = SKShapeNode(rectOf: CGSize(width: 300, height: 180), cornerRadius: 18)
        card.fillColor = UIColor(white: 0.10, alpha: 0.95)
        card.strokeColor = TileNode.colorConnected
        card.lineWidth = 2
        banner.addChild(card)

        // Title
        let title = SKLabelNode(fontNamed: "AvenirNext-Bold")
        title.text = "Circuit Sealed!"
        title.fontSize = 28
        title.fontColor = TileNode.colorConnected
        title.position = CGPoint(x: 0, y: 40)
        title.verticalAlignmentMode = .center
        banner.addChild(title)

        // Move count
        let subtitle = SKLabelNode(fontNamed: "AvenirNext-Regular")
        subtitle.text = "Completed in \(moveCount) moves"
        subtitle.fontSize = 18
        subtitle.fontColor = .white
        subtitle.position = CGPoint(x: 0, y: 8)
        subtitle.verticalAlignmentMode = .center
        banner.addChild(subtitle)

        // Stars
        let starString: String
        switch stars {
        case 3:  starString = "\u{2605}\u{2605}\u{2605}"
        case 2:  starString = "\u{2605}\u{2605}\u{2606}"
        default: starString = "\u{2605}\u{2606}\u{2606}"
        }

        let starLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        starLabel.text = starString
        starLabel.fontSize = 38
        starLabel.fontColor = UIColor(red: 1.0, green: 0.78, blue: 0.20, alpha: 1)
        starLabel.position = CGPoint(x: 0, y: -40)
        starLabel.verticalAlignmentMode = .center
        banner.addChild(starLabel)

        addChild(banner)

        // Animate in
        let fadeIn = SKAction.fadeIn(withDuration: 0.3)
        let scaleUp = SKAction.scale(to: 1.0, duration: 0.3)
        scaleUp.timingMode = .easeOut
        banner.run(SKAction.group([fadeIn, scaleUp]))
    }
}
