import SpriteKit
import UIKit

// MARK: - GameSceneDelegate

protocol GameSceneDelegate: AnyObject {
    func gameScene(_ scene: GameScene, didCompleteLevel levelID: Int,
                   moves: Int, stars: Int)
    func gameSceneDidRequestNextLevel(_ scene: GameScene, currentLevelID: Int)
    func gameSceneDidRequestRestart(_ scene: GameScene, levelID: Int)
    func gameSceneDidRequestMenu(_ scene: GameScene)
}

// MARK: - UndoEntry

private struct UndoEntry {
    let row: Int
    let col: Int
    let previousRotation: Int
}

// MARK: - GameScene

final class GameScene: SKScene {

    weak var gameDelegate: GameSceneDelegate?

    private var levelData: LevelData!
    private var tileGrid: [[TileNode]] = []
    private var gridContainer: SKNode!
    private var gridLinesNode: SKNode?
    private var cols: Int = 0
    private var rows: Int = 0
    private var isSolved: Bool = false
    private var par: Int = 0

    private var movesLabel: SKLabelNode!
    private var levelLabel: SKLabelNode!
    private var parLabel: SKLabelNode!
    private var timerLabel: SKLabelNode!
    private var bestLabel: SKLabelNode!

    private var undoButton: SKNode!
    private var undoStack: [UndoEntry] = []
    private var hintButton: SKNode!
    private var hintCountLabel: SKLabelNode!
    private var hintsRemaining: Int = 3

    // Press-state tracking for tactile feedback
    private var pressedTile: TileNode?
    private var pressedRow: Int = -1
    private var pressedCol: Int = -1

    // Solution rotations from JSON (for hint system & shuffle)
    private var solutionRotations: [[Int]] = []

    // Win banner reference for animated dismiss
    private var bannerNode: SKNode?
    private var dimOverlayNode: SKNode?

    // Confirm restart overlay
    private var confirmOverlay: SKNode?

    // Node recycling pool: keyed by "\(tileType.rawValue)_\(tileSize)"
    static var tilePool: [String: [TileNode]] = [:]

    private var elapsedTime: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0
    private var timerActive: Bool = false

    private var moveCount: Int = 0 {
        didSet {
            movesLabel?.text = "\(moveCount)"
            undoButton?.alpha = undoStack.isEmpty ? 0.3 : 1.0
        }
    }

    private var solverWorkItem: DispatchWorkItem?

    // MARK: - Scene setup

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)

        // Ambient particles
        let particles = BackgroundParticles(sceneSize: size)
        particles.zPosition = 1
        particles.name = "bgParticles"
        addChild(particles)

        setupHUD()
    }

    override func update(_ currentTime: TimeInterval) {
        if lastUpdateTime == 0 { lastUpdateTime = currentTime }
        if timerActive && !isSolved {
            elapsedTime += currentTime - lastUpdateTime
            updateTimerDisplay()
        }
        lastUpdateTime = currentTime
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        layoutForCurrentSize()
    }

    private func updateTimerDisplay() {
        let mins = Int(elapsedTime) / 60
        let secs = Int(elapsedTime) % 60
        timerLabel?.text = String(format: "%d:%02d", mins, secs)
    }

    // MARK: - HUD Setup

    private func setupHUD() {
        layoutHUD()
    }

    private func layoutHUD() {
        // Remove old HUD nodes to re-layout
        for name in ["backButton", "restartButton", "movesIcon", "movesLabel",
                     "parIcon", "parLabelNode", "timerIcon", "timerLabelNode",
                     "undoButton", "bestLabelNode", "hintButton"] {
            childNode(withName: name)?.removeFromParent()
        }
        // Also remove detached labels
        movesLabel?.removeFromParent()
        parLabel?.removeFromParent()
        timerLabel?.removeFromParent()
        bestLabel?.removeFromParent()
        undoButton?.removeFromParent()
        hintButton?.removeFromParent()
        levelLabel?.removeFromParent()

        let isLandscape = size.width > size.height
        let hudY = size.height - (isLandscape ? 40 : 55)

        // Back button (top-left)
        let backBtn = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        backBtn.text = "\u{2190}"
        backBtn.fontSize = 28
        backBtn.fontColor = UIColor(white: 0.50, alpha: 1)
        backBtn.position = CGPoint(x: 28, y: hudY)
        backBtn.horizontalAlignmentMode = .center
        backBtn.verticalAlignmentMode = .center
        backBtn.name = "backButton"
        backBtn.zPosition = 90
        backBtn.accessibilityLabel = "Back to menu"
        backBtn.isAccessibilityElement = true
        backBtn.accessibilityTraits = .button
        addChild(backBtn)

        // Level name (center top)
        levelLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        levelLabel.fontSize = 18
        levelLabel.fontColor = .white
        levelLabel.horizontalAlignmentMode = .center
        levelLabel.verticalAlignmentMode = .center
        levelLabel.position = CGPoint(x: size.width / 2, y: hudY)
        levelLabel.zPosition = 90
        levelLabel.text = levelData?.name ?? ""
        addChild(levelLabel)

        // Restart button (top-right area)
        let restartBtn = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        restartBtn.text = "\u{21BB}"
        restartBtn.fontSize = 26
        restartBtn.fontColor = UIColor(white: 0.50, alpha: 1)
        restartBtn.position = CGPoint(x: size.width - 28, y: hudY)
        restartBtn.horizontalAlignmentMode = .center
        restartBtn.verticalAlignmentMode = .center
        restartBtn.name = "restartButton"
        restartBtn.zPosition = 90
        restartBtn.accessibilityLabel = "Restart level"
        restartBtn.isAccessibilityElement = true
        restartBtn.accessibilityTraits = .button
        addChild(restartBtn)

        // Second row: moves, par, timer, undo, hint
        let row2Y = hudY - 32

        // Moves icon + count
        let movesIcon = SKLabelNode(fontNamed: "AvenirNext-Medium")
        movesIcon.text = "Moves"
        movesIcon.fontSize = 11
        movesIcon.fontColor = UIColor(white: 0.40, alpha: 1)
        movesIcon.position = CGPoint(x: 50, y: row2Y + 10)
        movesIcon.horizontalAlignmentMode = .center
        movesIcon.zPosition = 90
        addChild(movesIcon)

        movesLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        movesLabel.fontSize = 20
        movesLabel.fontColor = .white
        movesLabel.horizontalAlignmentMode = .center
        movesLabel.verticalAlignmentMode = .top
        movesLabel.position = CGPoint(x: 50, y: row2Y)
        movesLabel.zPosition = 90
        movesLabel.text = "\(moveCount)"
        addChild(movesLabel)

        // Par display
        let parIcon = SKLabelNode(fontNamed: "AvenirNext-Medium")
        parIcon.text = "Par"
        parIcon.fontSize = 11
        parIcon.fontColor = UIColor(white: 0.40, alpha: 1)
        parIcon.position = CGPoint(x: 120, y: row2Y + 10)
        parIcon.horizontalAlignmentMode = .center
        parIcon.zPosition = 90
        addChild(parIcon)

        parLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        parLabel.fontSize = 20
        parLabel.fontColor = TileNode.colorConnected.withAlphaComponent(0.7)
        parLabel.horizontalAlignmentMode = .center
        parLabel.verticalAlignmentMode = .top
        parLabel.position = CGPoint(x: 120, y: row2Y)
        parLabel.zPosition = 90
        parLabel.text = par > 0 ? "\(par)" : ""
        addChild(parLabel)

        // Timer
        let timerIcon = SKLabelNode(fontNamed: "AvenirNext-Medium")
        timerIcon.text = "Time"
        timerIcon.fontSize = 11
        timerIcon.fontColor = UIColor(white: 0.40, alpha: 1)
        timerIcon.position = CGPoint(x: size.width - 120, y: row2Y + 10)
        timerIcon.horizontalAlignmentMode = .center
        timerIcon.zPosition = 90
        addChild(timerIcon)

        timerLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        timerLabel.fontSize = 20
        timerLabel.fontColor = UIColor(white: 0.70, alpha: 1)
        timerLabel.horizontalAlignmentMode = .center
        timerLabel.verticalAlignmentMode = .top
        timerLabel.position = CGPoint(x: size.width - 120, y: row2Y)
        timerLabel.zPosition = 90
        timerLabel.text = "0:00"
        addChild(timerLabel)

        // Undo button
        undoButton = SKNode()
        undoButton.name = "undoButton"
        undoButton.position = CGPoint(x: size.width - 45, y: row2Y - 4)
        undoButton.zPosition = 90
        undoButton.alpha = undoStack.isEmpty ? 0.3 : 1.0

        let undoLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        undoLabel.text = "\u{21A9}"
        undoLabel.fontSize = 24
        undoLabel.fontColor = TileNode.colorAccent
        undoLabel.horizontalAlignmentMode = .center
        undoLabel.verticalAlignmentMode = .center
        undoLabel.name = "undoButton"
        undoButton.addChild(undoLabel)

        let undoText = SKLabelNode(fontNamed: "AvenirNext-Medium")
        undoText.text = "Undo"
        undoText.fontSize = 9
        undoText.fontColor = UIColor(white: 0.40, alpha: 1)
        undoText.position = CGPoint(x: 0, y: 14)
        undoText.horizontalAlignmentMode = .center
        undoText.name = "undoButton"
        undoButton.addChild(undoText)

        undoButton.accessibilityLabel = "Undo last move"
        undoButton.isAccessibilityElement = true
        undoButton.accessibilityTraits = .button
        addChild(undoButton)

        // Hint button (lightbulb icon)
        hintButton = SKNode()
        hintButton.name = "hintButton"
        hintButton.position = CGPoint(x: size.width / 2 + 60, y: row2Y - 4)
        hintButton.zPosition = 90

        let hintIcon = SKLabelNode(fontNamed: "AvenirNext-Bold")
        hintIcon.text = "\u{1F4A1}"
        hintIcon.fontSize = 20
        hintIcon.horizontalAlignmentMode = .center
        hintIcon.verticalAlignmentMode = .center
        hintIcon.name = "hintButton"
        hintButton.addChild(hintIcon)

        hintCountLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        hintCountLabel.text = "\(hintsRemaining)"
        hintCountLabel.fontSize = 10
        hintCountLabel.fontColor = TileNode.colorAccent
        hintCountLabel.position = CGPoint(x: 14, y: 8)
        hintCountLabel.horizontalAlignmentMode = .center
        hintCountLabel.verticalAlignmentMode = .center
        hintCountLabel.name = "hintButton"
        hintButton.addChild(hintCountLabel)

        let hintText = SKLabelNode(fontNamed: "AvenirNext-Medium")
        hintText.text = "Hint"
        hintText.fontSize = 9
        hintText.fontColor = UIColor(white: 0.40, alpha: 1)
        hintText.position = CGPoint(x: 0, y: 14)
        hintText.horizontalAlignmentMode = .center
        hintText.name = "hintButton"
        hintButton.addChild(hintText)

        hintButton.accessibilityLabel = "Use hint, \(hintsRemaining) remaining"
        hintButton.isAccessibilityElement = true
        hintButton.accessibilityTraits = .button
        addChild(hintButton)

        // Best score (shown below par after level loads)
        bestLabel = SKLabelNode(fontNamed: "AvenirNext-Regular")
        bestLabel.fontSize = 10
        bestLabel.fontColor = UIColor(white: 0.35, alpha: 1)
        bestLabel.horizontalAlignmentMode = .center
        bestLabel.verticalAlignmentMode = .top
        bestLabel.position = CGPoint(x: 120, y: row2Y - 22)
        bestLabel.zPosition = 90
        if let ld = levelData {
            let best = LevelProgress.bestMoves(for: ld.id)
            bestLabel.text = best > 0 ? "Best: \(best)" : ""
        }
        addChild(bestLabel)
    }

    // MARK: - Load level

    func loadLevel(_ levelData: LevelData) {
        self.levelData = levelData
        self.cols = levelData.gridCols
        self.rows = levelData.gridRows
        self.par = levelData.par
        self.moveCount = 0
        self.isSolved = false
        self.undoStack = []
        self.elapsedTime = 0
        self.lastUpdateTime = 0
        self.timerActive = true
        self.hintsRemaining = 3
        self.pressedTile = nil
        self.bannerNode?.removeFromParent()
        self.bannerNode = nil
        self.dimOverlayNode?.removeFromParent()
        self.dimOverlayNode = nil
        self.confirmOverlay?.removeFromParent()
        self.confirmOverlay = nil

        // Store solution rotations from JSON
        solutionRotations = levelData.tiles.map { row in row.map { $0.rotation } }

        // Recycle previous tiles into pool
        recycleTiles()

        // Clear previous grid
        gridContainer?.removeFromParent()
        gridContainer = SKNode()
        gridContainer.zPosition = 10
        addChild(gridContainer)

        levelLabel?.text = levelData.name
        parLabel?.text = "\(levelData.par)"
        hintCountLabel?.text = "\(hintsRemaining)"

        let best = LevelProgress.bestMoves(for: levelData.id)
        bestLabel?.text = best > 0 ? "Best: \(best)" : ""

        let tileSize = CGFloat(levelData.tileSize)
        let totalW = CGFloat(cols) * tileSize
        let totalH = CGFloat(rows) * tileSize
        let gridOriginX = (size.width - totalW) / 2
        let gridOriginY = (size.height - totalH) / 2 + 20

        // Draw faint grid lines behind tiles
        drawGridLines(cols: cols, rows: rows, tileSize: tileSize,
                      originX: gridOriginX, originY: gridOriginY)

        tileGrid = []

        for row in 0..<rows {
            var rowNodes: [TileNode] = []
            for col in 0..<cols {
                let td = levelData.tiles[row][col]
                guard let tileType = TileType(rawValue: td.type) else { continue }

                let isLocked = td.locked == true

                // Shuffle initial rotations for non-locked tiles
                let solutionRot = td.rotation
                let initialRot: Int
                if isLocked {
                    initialRot = solutionRot
                } else {
                    // Randomize to a rotation different from solution (if possible)
                    var scrambled = Int.random(in: 0...3)
                    // For types with rotational symmetry, just pick random
                    if tileType != .cross {
                        var attempts = 0
                        while scrambled == solutionRot && attempts < 10 {
                            scrambled = Int.random(in: 0...3)
                            attempts += 1
                        }
                    }
                    initialRot = scrambled
                }

                // Try to dequeue a recycled tile of the same type and size
                let tile = dequeueTile(type: tileType, size: tileSize, rotation: initialRot, solutionRotation: solutionRot)

                // SpriteKit Y-up: row 0 (top) maps to high Y
                let x = gridOriginX + CGFloat(col) * tileSize + tileSize / 2
                let y = size.height - (gridOriginY + CGFloat(row) * tileSize + tileSize / 2)
                tile.position = CGPoint(x: x, y: y)
                tile.solutionRotation = solutionRot

                // Locked tiles
                if isLocked {
                    tile.isLocked = true

                    // Only add lock badge if not already present
                    if tile.childNode(withName: "lockBadge") == nil {
                        let badgeSize = tileSize * 0.10
                        let badge = SKShapeNode(circleOfRadius: badgeSize)
                        badge.fillColor = TileNode.colorGold
                        badge.strokeColor = UIColor(red: 0.85, green: 0.65, blue: 0.10, alpha: 1)
                        badge.lineWidth = 1
                        badge.zPosition = 6
                        badge.position = CGPoint(x: tileSize / 2 - tileSize * 0.18,
                                                 y: tileSize / 2 - tileSize * 0.18)
                        badge.name = "lockBadge"
                        tile.addChild(badge)

                        let shimmer = SKAction.sequence([
                            SKAction.fadeAlpha(to: 0.6, duration: 1.2),
                            SKAction.fadeAlpha(to: 1.0, duration: 1.2)
                        ])
                        badge.run(SKAction.repeatForever(shimmer))
                    }
                } else {
                    tile.isLocked = false
                }

                gridContainer.addChild(tile)
                rowNodes.append(tile)
            }
            tileGrid.append(rowNodes)
        }

        animateGridEntrance()
    }

    // MARK: - Grid lines

    private func drawGridLines(cols: Int, rows: Int, tileSize: CGFloat,
                               originX: CGFloat, originY: CGFloat) {
        gridLinesNode?.removeFromParent()
        let container = SKNode()
        container.zPosition = 5

        let lineColor = UIColor(white: 1.0, alpha: 0.03)

        // Vertical lines
        for col in 0...cols {
            let x = originX + CGFloat(col) * tileSize
            let path = CGMutablePath()
            let yTop = size.height - originY
            let yBot = size.height - (originY + CGFloat(rows) * tileSize)
            path.move(to: CGPoint(x: x, y: yTop))
            path.addLine(to: CGPoint(x: x, y: yBot))
            let line = SKShapeNode(path: path)
            line.strokeColor = lineColor
            line.lineWidth = 0.5
            container.addChild(line)
        }

        // Horizontal lines
        for row in 0...rows {
            let y = size.height - (originY + CGFloat(row) * tileSize)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: originX, y: y))
            path.addLine(to: CGPoint(x: originX + CGFloat(cols) * tileSize, y: y))
            let line = SKShapeNode(path: path)
            line.strokeColor = lineColor
            line.lineWidth = 0.5
            container.addChild(line)
        }

        addChild(container)
        gridLinesNode = container
    }

    // MARK: - Node recycling

    private func recycleTiles() {
        for row in tileGrid {
            for tile in row {
                tile.removeFromParent()
                // Remove lock badges for reuse
                tile.childNode(withName: "lockBadge")?.removeFromParent()
                let key = "\(tile.tileType.rawValue)_\(Int(tile.tileSize))"
                GameScene.tilePool[key, default: []].append(tile)
            }
        }
        tileGrid = []
    }

    private func dequeueTile(type: TileType, size: CGFloat, rotation: Int, solutionRotation: Int) -> TileNode {
        let key = "\(type.rawValue)_\(Int(size))"
        if var pool = GameScene.tilePool[key], !pool.isEmpty {
            let tile = pool.removeLast()
            GameScene.tilePool[key] = pool
            tile.resetForRecycling(rotation: rotation, solutionRotation: solutionRotation)
            return tile
        }
        let tile = TileNode(type: type, size: size, initialRotation: rotation)
        tile.solutionRotation = solutionRotation
        return tile
    }

    // MARK: - Grid entrance animation

    private func animateGridEntrance() {
        for row in 0..<tileGrid.count {
            for col in 0..<tileGrid[row].count {
                let tile = tileGrid[row][col]
                tile.alpha = 0
                tile.setScale(0.5)
                let delay = Double(row + col) * 0.035
                tile.run(SKAction.sequence([
                    SKAction.wait(forDuration: delay),
                    SKAction.group([
                        SKAction.fadeIn(withDuration: 0.3),
                        SKAction.scale(to: 1.0, duration: 0.3)
                    ])
                ]))
            }
        }
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        // Dismiss confirm overlay if tapped outside
        if confirmOverlay != nil {
            let sceneLoc = touch.location(in: self)
            let tapped = nodes(at: sceneLoc)
            for node in tapped {
                let name = node.name ?? node.parent?.name
                if name == "confirmYes" {
                    SoundManager.shared.playButtonTap()
                    dismissConfirmOverlay()
                    gameDelegate?.gameSceneDidRequestRestart(self, levelID: levelData.id)
                    return
                }
                if name == "confirmNo" {
                    SoundManager.shared.playButtonTap()
                    dismissConfirmOverlay()
                    return
                }
            }
            dismissConfirmOverlay()
            return
        }

        // Check HUD buttons first (in scene coords)
        let sceneLoc = touch.location(in: self)
        let tappedNodes = nodes(at: sceneLoc)
        for node in tappedNodes {
            let name = node.name ?? node.parent?.name
            if name == "backButton" {
                SoundManager.shared.playButtonTap()
                gameDelegate?.gameSceneDidRequestMenu(self)
                return
            }
            if name == "restartButton" {
                SoundManager.shared.playButtonTap()
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                showConfirmRestart()
                return
            }
            if name == "undoButton" {
                performUndo()
                return
            }
            if name == "hintButton" {
                performHint()
                return
            }
            if name == "nextButton" {
                SoundManager.shared.playButtonTap()
                animateBannerDismiss { [weak self] in
                    guard let self = self else { return }
                    self.gameDelegate?.gameSceneDidRequestNextLevel(self, currentLevelID: self.levelData.id)
                }
                return
            }
            if name == "replayButton" {
                SoundManager.shared.playButtonTap()
                animateBannerDismiss { [weak self] in
                    guard let self = self else { return }
                    self.gameDelegate?.gameSceneDidRequestRestart(self, levelID: self.levelData.id)
                }
                return
            }
            if name == "menuButton" {
                SoundManager.shared.playButtonTap()
                animateBannerDismiss { [weak self] in
                    guard let self = self else { return }
                    self.gameDelegate?.gameSceneDidRequestMenu(self)
                }
                return
            }
        }

        // Tile interaction — apply press state
        guard !isSolved else { return }
        let loc = touch.location(in: gridContainer)

        for row in 0..<tileGrid.count {
            for col in 0..<tileGrid[row].count {
                let tile = tileGrid[row][col]
                guard !tile.isLocked else { continue }

                let tileFrame = tile.calculateAccumulatedFrame()
                if tileFrame.contains(loc) {
                    pressedTile = tile
                    pressedRow = row
                    pressedCol = col
                    tile.applyPressState()
                    return
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let tile = pressedTile else { return }
        tile.releasePressState()

        // Verify touch is still on the same tile
        if let touch = touches.first {
            let loc = touch.location(in: gridContainer)
            let tileFrame = tile.calculateAccumulatedFrame()
            if tileFrame.contains(loc) {
                let prevRot = tile.rotationSteps
                undoStack.append(UndoEntry(row: pressedRow, col: pressedCol, previousRotation: prevRot))

                tile.rotate { [weak self] in
                    self?.moveCount += 1
                    self?.scheduleCompletionCheck()
                }
            }
        }

        pressedTile = nil
        pressedRow = -1
        pressedCol = -1
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressedTile?.releasePressState()
        pressedTile = nil
        pressedRow = -1
        pressedCol = -1
    }

    // MARK: - Hint system

    private func performHint() {
        guard !isSolved, hintsRemaining > 0 else {
            // Shake the hint button to indicate no hints
            let shake = SKAction.sequence([
                SKAction.moveBy(x: -4, y: 0, duration: 0.04),
                SKAction.moveBy(x: 8, y: 0, duration: 0.04),
                SKAction.moveBy(x: -8, y: 0, duration: 0.04),
                SKAction.moveBy(x: 4, y: 0, duration: 0.04)
            ])
            hintButton.run(shake)
            return
        }

        // Find incorrectly rotated, non-locked tiles
        var candidates: [(Int, Int)] = []
        for row in 0..<tileGrid.count {
            for col in 0..<tileGrid[row].count {
                let tile = tileGrid[row][col]
                guard !tile.isLocked else { continue }
                if !tile.isCorrectlyRotated {
                    candidates.append((row, col))
                }
            }
        }

        guard let (row, col) = candidates.randomElement() else { return }

        SoundManager.shared.playButtonTap()
        hintsRemaining -= 1
        hintCountLabel?.text = "\(hintsRemaining)"
        hintButton.accessibilityLabel = "Use hint, \(hintsRemaining) remaining"

        // Cost: +2 moves
        moveCount += 2

        // Pulse the tile
        tileGrid[row][col].showHintPulse()

        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    // MARK: - Confirm restart

    private func showConfirmRestart() {
        guard confirmOverlay == nil else { return }

        let overlay = SKNode()
        overlay.zPosition = 110

        // Dim background
        let dim = SKShapeNode(rectOf: CGSize(width: size.width * 2, height: size.height * 2))
        dim.fillColor = UIColor(white: 0.0, alpha: 0.4)
        dim.strokeColor = .clear
        dim.position = CGPoint(x: size.width / 2, y: size.height / 2)
        dim.name = "confirmNo"
        overlay.addChild(dim)

        // Card
        let cardW: CGFloat = 240
        let cardH: CGFloat = 120
        let card = SKShapeNode(rectOf: CGSize(width: cardW, height: cardH), cornerRadius: 16)
        card.fillColor = UIColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 0.98)
        card.strokeColor = UIColor(white: 0.25, alpha: 1)
        card.lineWidth = 1.5
        card.position = CGPoint(x: size.width / 2, y: size.height / 2)
        overlay.addChild(card)

        let titleLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        titleLabel.text = "Restart level?"
        titleLabel.fontSize = 18
        titleLabel.fontColor = .white
        titleLabel.position = CGPoint(x: size.width / 2, y: size.height / 2 + 25)
        titleLabel.horizontalAlignmentMode = .center
        titleLabel.verticalAlignmentMode = .center
        overlay.addChild(titleLabel)

        let yesBtn = makeActionButton(text: "Yes", width: 80, height: 34,
                                       color: TileNode.colorConnected,
                                       textColor: UIColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
                                       name: "confirmYes")
        yesBtn.position = CGPoint(x: size.width / 2 - 50, y: size.height / 2 - 22)
        overlay.addChild(yesBtn)

        let noBtn = makeActionButton(text: "No", width: 80, height: 34,
                                      color: UIColor(white: 0.20, alpha: 1),
                                      textColor: UIColor(white: 0.70, alpha: 1),
                                      name: "confirmNo")
        noBtn.position = CGPoint(x: size.width / 2 + 50, y: size.height / 2 - 22)
        overlay.addChild(noBtn)

        // Animate in
        overlay.alpha = 0
        overlay.setScale(0.8)
        addChild(overlay)
        overlay.run(SKAction.group([
            SKAction.fadeIn(withDuration: 0.15),
            SKAction.scale(to: 1.0, duration: 0.15)
        ]))

        confirmOverlay = overlay
    }

    private func dismissConfirmOverlay() {
        guard let overlay = confirmOverlay else { return }
        overlay.run(SKAction.group([
            SKAction.fadeOut(withDuration: 0.1),
            SKAction.scale(to: 0.8, duration: 0.1)
        ])) {
            overlay.removeFromParent()
        }
        confirmOverlay = nil
    }

    // MARK: - Banner dismiss animation

    private func animateBannerDismiss(completion: @escaping () -> Void) {
        guard let banner = bannerNode else {
            completion()
            return
        }
        let scaleDown = SKAction.scale(to: 0.3, duration: 0.2)
        scaleDown.timingMode = .easeIn
        let fadeOut = SKAction.fadeOut(withDuration: 0.2)
        banner.run(SKAction.group([scaleDown, fadeOut]))
        dimOverlayNode?.run(SKAction.fadeOut(withDuration: 0.2))

        run(SKAction.sequence([
            SKAction.wait(forDuration: 0.2),
            SKAction.run { completion() }
        ]))
    }

    // MARK: - Landscape relayout

    private func layoutForCurrentSize() {
        // Re-layout HUD
        layoutHUD()

        // Re-layout grid if loaded
        guard levelData != nil, !tileGrid.isEmpty else { return }

        let tileSize = CGFloat(levelData.tileSize)
        let totalW = CGFloat(cols) * tileSize
        let totalH = CGFloat(rows) * tileSize
        let gridOriginX = (size.width - totalW) / 2
        let gridOriginY = (size.height - totalH) / 2 + 20

        for row in 0..<tileGrid.count {
            for col in 0..<tileGrid[row].count {
                let tile = tileGrid[row][col]
                let x = gridOriginX + CGFloat(col) * tileSize + tileSize / 2
                let y = size.height - (gridOriginY + CGFloat(row) * tileSize + tileSize / 2)
                tile.position = CGPoint(x: x, y: y)
            }
        }

        // Redraw grid lines
        drawGridLines(cols: cols, rows: rows, tileSize: tileSize,
                      originX: gridOriginX, originY: gridOriginY)
    }

    // MARK: - Undo

    private func performUndo() {
        guard !isSolved, let entry = undoStack.popLast() else { return }

        let tile = tileGrid[entry.row][entry.col]
        tile.setRotation(entry.previousRotation)
        moveCount = max(0, moveCount - 1)

        SoundManager.shared.playUndo()
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        scheduleCompletionCheck()
    }

    // MARK: - Completion check

    private func scheduleCompletionCheck() {
        solverWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.checkCompletion()
        }
        solverWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: item)
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
            timerActive = false
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
        let pulseUp   = SKAction.scale(to: 1.04, duration: 0.15)
        let pulseDown = SKAction.scale(to: 1.0, duration: 0.15)
        pulseUp.timingMode = .easeOut
        pulseDown.timingMode = .easeIn
        gridContainer.run(SKAction.sequence([pulseUp, pulseDown]))

        // 2. Confetti-style particle burst from each tile
        let burstColors: [UIColor] = [
            TileNode.colorConnected,
            TileNode.colorAccent,
            TileNode.colorGold,
            UIColor(red: 0.90, green: 0.35, blue: 0.55, alpha: 1),
            UIColor(red: 0.65, green: 0.45, blue: 1.0, alpha: 1)
        ]

        for row in tileGrid {
            for tile in row {
                let worldPos = tile.position
                for _ in 0..<8 {
                    let isSquare = Bool.random()
                    let dot: SKShapeNode
                    if isSquare {
                        let sz = CGFloat.random(in: 2.5...5.0)
                        dot = SKShapeNode(rectOf: CGSize(width: sz, height: sz), cornerRadius: 1)
                    } else {
                        dot = SKShapeNode(circleOfRadius: CGFloat.random(in: 1.5...3.5))
                    }
                    dot.fillColor = burstColors.randomElement()!
                    dot.strokeColor = .clear
                    dot.position = worldPos
                    dot.zPosition = 50
                    gridContainer.addChild(dot)

                    let angle = CGFloat.random(in: 0...(.pi * 2))
                    let speed = CGFloat.random(in: 50...140)
                    let dx = cos(angle) * speed
                    let dy = sin(angle) * speed

                    let move = SKAction.moveBy(x: dx, y: dy, duration: 0.6)
                    move.timingMode = .easeOut
                    let scaleDown = SKAction.scale(to: 0.05, duration: 0.6)
                    let fadeOut = SKAction.fadeOut(withDuration: 0.6)
                    let spin = SKAction.rotate(byAngle: CGFloat.random(in: -4...4), duration: 0.6)
                    let group = SKAction.group([move, scaleDown, fadeOut, spin])

                    dot.run(group) {
                        dot.removeFromParent()
                    }
                }
            }
        }

        // 3. Show completion banner after particles
        run(SKAction.sequence([
            SKAction.wait(forDuration: 0.6),
            SKAction.run { [weak self] in
                self?.showCompletionBanner(stars: stars)
            }
        ]))

        // 4. Success haptic + sound
        SoundManager.shared.playWin()
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    // MARK: - Completion banner

    private func showCompletionBanner(stars: Int) {
        let banner = SKNode()
        banner.zPosition = 100
        banner.position = CGPoint(x: size.width / 2, y: size.height / 2 + 10)
        banner.setScale(0.1)
        banner.alpha = 0

        // Dim overlay
        let overlay = SKShapeNode(rectOf: CGSize(width: size.width * 2, height: size.height * 2))
        overlay.fillColor = UIColor(white: 0.0, alpha: 0.5)
        overlay.strokeColor = .clear
        overlay.zPosition = 95
        overlay.position = CGPoint(x: size.width / 2, y: size.height / 2)
        overlay.alpha = 0
        overlay.name = "dimOverlay"
        addChild(overlay)
        overlay.run(SKAction.fadeAlpha(to: 1.0, duration: 0.3))
        dimOverlayNode = overlay

        // Card background
        let cardW: CGFloat = 300
        let cardH: CGFloat = 280
        let card = SKShapeNode(rectOf: CGSize(width: cardW, height: cardH), cornerRadius: 22)
        card.fillColor = UIColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 0.98)
        card.strokeColor = TileNode.colorConnected.withAlphaComponent(0.4)
        card.lineWidth = 2
        banner.addChild(card)

        // Subtle inner glow line
        let innerGlow = SKShapeNode(rectOf: CGSize(width: cardW - 6, height: cardH - 6), cornerRadius: 20)
        innerGlow.fillColor = .clear
        innerGlow.strokeColor = UIColor(white: 1.0, alpha: 0.04)
        innerGlow.lineWidth = 1
        banner.addChild(innerGlow)

        // Title
        let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        title.text = "Circuit Sealed!"
        title.fontSize = 30
        title.fontColor = TileNode.colorConnected
        title.position = CGPoint(x: 0, y: 85)
        title.verticalAlignmentMode = .center
        banner.addChild(title)

        // Move count
        let subtitle = SKLabelNode(fontNamed: "AvenirNext-Regular")
        subtitle.text = "Completed in \(moveCount) moves"
        subtitle.fontSize = 16
        subtitle.fontColor = UIColor(white: 0.70, alpha: 1)
        subtitle.position = CGPoint(x: 0, y: 55)
        subtitle.verticalAlignmentMode = .center
        banner.addChild(subtitle)

        // Time
        let mins = Int(elapsedTime) / 60
        let secs = Int(elapsedTime) % 60
        let timeStr = String(format: "Time: %d:%02d", mins, secs)
        let timeLabel = SKLabelNode(fontNamed: "AvenirNext-Regular")
        timeLabel.text = timeStr
        timeLabel.fontSize = 14
        timeLabel.fontColor = UIColor(white: 0.50, alpha: 1)
        timeLabel.position = CGPoint(x: 0, y: 35)
        timeLabel.verticalAlignmentMode = .center
        banner.addChild(timeLabel)

        // Animated stars
        let starPositions: [CGFloat] = [-40, 0, 40]
        for (i, xPos) in starPositions.enumerated() {
            let earned = i < stars
            let starLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
            starLabel.text = earned ? "\u{2605}" : "\u{2606}"
            starLabel.fontSize = 44
            starLabel.fontColor = earned ? TileNode.colorGold : UIColor(white: 0.25, alpha: 1)
            starLabel.position = CGPoint(x: xPos, y: 0)
            starLabel.verticalAlignmentMode = .center
            starLabel.setScale(0.0)
            banner.addChild(starLabel)

            // Pop-in animation for each star
            let delay = 0.3 + Double(i) * 0.15
            starLabel.run(SKAction.sequence([
                SKAction.wait(forDuration: delay),
                SKAction.group([
                    SKAction.scale(to: earned ? 1.2 : 0.9, duration: 0.2),
                ]),
                SKAction.scale(to: 1.0, duration: 0.1)
            ]))

            if earned {
                // Sparkle on earned stars
                starLabel.run(SKAction.sequence([
                    SKAction.wait(forDuration: delay + 0.2),
                    SKAction.run { [weak self] in
                        self?.addStarSparkle(at: starLabel, in: banner)
                    }
                ]))
            }
        }

        // Action buttons
        let buttonY: CGFloat = -55

        // Next Level button
        let isLastLevel = levelData.id >= (try? LevelLoader.load().levels.count) ?? 0
        if !isLastLevel {
            let nextBtn = makeActionButton(text: "Next Level", width: 160, height: 44,
                                            color: TileNode.colorConnected,
                                            textColor: UIColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
                                            name: "nextButton")
            nextBtn.position = CGPoint(x: 0, y: buttonY)
            banner.addChild(nextBtn)
        }

        // Replay button
        let replayBtn = makeActionButton(text: "Replay", width: 120, height: 36,
                                          color: UIColor(white: 0.20, alpha: 1),
                                          textColor: UIColor(white: 0.70, alpha: 1),
                                          name: "replayButton")
        replayBtn.position = CGPoint(x: isLastLevel ? 60 : 0, y: buttonY - (isLastLevel ? 0 : 50))
        banner.addChild(replayBtn)

        // Menu button
        let menuBtn = makeActionButton(text: "Menu", width: 100, height: 36,
                                        color: UIColor(white: 0.20, alpha: 1),
                                        textColor: UIColor(white: 0.70, alpha: 1),
                                        name: "menuButton")
        menuBtn.position = CGPoint(x: isLastLevel ? -60 : 0, y: buttonY - (isLastLevel ? 0 : 90))
        banner.addChild(menuBtn)

        addChild(banner)
        bannerNode = banner

        // Animate banner in
        let fadeIn = SKAction.fadeIn(withDuration: 0.3)
        let scaleUp = SKAction.scale(to: 1.0, duration: 0.3)
        scaleUp.timingMode = .easeOut
        banner.run(SKAction.group([fadeIn, scaleUp]))
    }

    private func addStarSparkle(at star: SKLabelNode, in parent: SKNode) {
        for _ in 0..<4 {
            let sparkle = SKShapeNode(circleOfRadius: 2)
            sparkle.fillColor = TileNode.colorGold
            sparkle.strokeColor = .clear
            sparkle.position = star.position
            sparkle.zPosition = 101
            parent.addChild(sparkle)

            let angle = CGFloat.random(in: 0...(.pi * 2))
            let dist = CGFloat.random(in: 15...30)
            let move = SKAction.moveBy(x: cos(angle) * dist, y: sin(angle) * dist, duration: 0.4)
            move.timingMode = .easeOut
            sparkle.run(SKAction.group([move, SKAction.fadeOut(withDuration: 0.4), SKAction.scale(to: 0.1, duration: 0.4)])) {
                sparkle.removeFromParent()
            }
        }
    }

    private func makeActionButton(text: String, width: CGFloat, height: CGFloat,
                                   color: UIColor, textColor: UIColor, name: String) -> SKNode {
        let node = SKNode()
        node.name = name

        let bg = SKShapeNode(rectOf: CGSize(width: width, height: height), cornerRadius: height / 2)
        bg.fillColor = color
        bg.strokeColor = .clear
        bg.name = name
        node.addChild(bg)

        let label = SKLabelNode(fontNamed: "AvenirNext-Bold")
        label.text = text
        label.fontSize = 15
        label.fontColor = textColor
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.name = name
        node.addChild(label)

        return node
    }
}
