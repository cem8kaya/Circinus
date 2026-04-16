import SpriteKit
import UIKit

// MARK: - GameSceneDelegate

protocol GameSceneDelegate: AnyObject {
    func gameScene(_ scene: GameScene, didCompleteLevel levelID: Int,
                   moves: Int, stars: Int, choreoScore: ChoreographyScore, trace: MoveTrace)
    func gameSceneDidRequestNextLevel(_ scene: GameScene, currentLevelID: Int)
    func gameSceneDidRequestRestart(_ scene: GameScene, levelID: Int)
    func gameSceneDidRequestMenu(_ scene: GameScene)
}

// MARK: - UndoEntry

private struct UndoEntry {
    let row: Int
    let col: Int
    let previousRotation: Int
    /// Non-nil only for collapse moves; restores the pre-collapse superposed role on undo.
    let previousRole: TileRole?
    /// §3 Quantum: entries sharing the same undoGroupID are reversed together
    /// as a single undo action. Plain moves get a unique UUID per tap.
    let undoGroupID: String
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
    private let moveTrace = MoveTrace()
    private var hintButton: SKNode!
    private var hintCountLabel: SKLabelNode!
    private var hintsRemaining: Int = 3

    // Premium hint spotlight (shown when hint is used)
    private var hintSpotlightNode: SKNode?
    private var hintedTile: TileNode?

    // First-play tutorial overlay
    private var tutorialOverlay: TutorialOverlay?

    // Press-state tracking for tactile feedback
    private var pressedTile: TileNode?
    private var pressedRow: Int = -1
    private var pressedCol: Int = -1

    // Solution rotations from JSON (for hint system & shuffle)
    private var solutionRotations: [[Int]] = []

    // Win banner reference for animated dismiss
    private var bannerNode: SKNode?
    private var dimOverlayNode: SKNode?

    // "How?" chip highlights panel (milestone 1.3)
    private var highlightsPanelNode: SKNode?
    private var isHighlightsPanelShown: Bool = false
    private var pendingHighlights: [PatternHighlight] = []

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

    // §6 Superposition long-press collapse
    private var longPressStart: TimeInterval?
    private var collapseOverlay: SKNode?
    private var collapseTargetRow: Int = -1
    private var collapseTargetCol: Int = -1

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

        // §6 Long-press: fire collapse overlay after 0.45 s on a superposed tile.
        if let start = longPressStart,
           let tile = pressedTile,
           !tile.isLocked,
           CACurrentMediaTime() - start > 0.45,
           case .superposed(_, _, false, _) = tile.role {
            showCollapseOverlay(for: tile, row: pressedRow, col: pressedCol)
            longPressStart = nil   // consumed — don't re-fire
        }
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
        self.moveTrace.reset()
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
        self.collapseOverlay?.removeFromParent()
        self.collapseOverlay   = nil
        self.collapseTargetRow = -1
        self.collapseTargetCol = -1
        self.longPressStart    = nil

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

                // §1–§5: apply role and quantum group from JSON.
                // role.didSet triggers updateRoleVisuals() so the diode
                // arrow (and future role overlays) appear immediately.
                tile.role         = td.parsedRole
                tile.quantumGroup = td.quantumGroup

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

        // Show premium tutorial the first time Level 1 is played
        if levelData.id == 1 && !UserDefaults.standard.bool(forKey: "tutorialCompleted") {
            showTutorial()
        }
    }

    // MARK: - First-play tutorial

    private func showTutorial() {
        tutorialOverlay?.removeFromParent()
        let overlay = TutorialOverlay(sceneSize: size)
        overlay.alpha = 0
        overlay.onDismiss = { [weak self] in
            self?.tutorialOverlay = nil
        }
        addChild(overlay)
        tutorialOverlay = overlay
        // Delay so the grid entrance animation plays first
        overlay.run(SKAction.sequence([
            SKAction.wait(forDuration: 0.55),
            SKAction.fadeIn(withDuration: 0.30)
        ]))
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

        // Tutorial intercepts all input while visible
        if let tutorial = tutorialOverlay {
            _ = tutorial.handleTap(at: touch.location(in: self), in: self)
            return
        }

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

        // §6 Collapse overlay: intercept all input while visible.
        if collapseOverlay != nil {
            let sceneLoc2 = touch.location(in: self)
            for node in nodes(at: sceneLoc2) {
                let name = node.name ?? node.parent?.name
                if name == "collapseA" { handleCollapseChoice(toB: false); return }
                if name == "collapseB" { handleCollapseChoice(toB: true);  return }
            }
            dismissCollapseOverlay()
            return
        }

        // Check HUD buttons first (in scene coords)
        let sceneLoc = touch.location(in: self)
        let tappedNodes = nodes(at: sceneLoc)
        for node in tappedNodes {
            let name = node.name ?? node.parent?.name
            if name == "backButton" {
                dismissHintSpotlight()
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
            if name == "howChip" {
                SoundManager.shared.playButtonTap()
                if isHighlightsPanelShown { hideHighlightsPanel() } else { showHighlightsPanel() }
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
                    // §6 Start long-press timer for uncollapsed superposed tiles.
                    if case .superposed(_, _, false, _) = tile.role {
                        longPressStart = CACurrentMediaTime()
                    }
                    return
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressStart = nil
        guard let tile = pressedTile else { return }
        tile.releasePressState()

        // Verify touch is still on the same tile
        if let touch = touches.first {
            let loc = touch.location(in: gridContainer)
            let tileFrame = tile.calculateAccumulatedFrame()
            if tileFrame.contains(loc) {
                dismissHintSpotlight()

                if let group = tile.quantumGroup {
                    // §3 Quantum: rotate every tile in the group atomically.
                    // All entries share one undoGroupID so performUndo reverses
                    // the whole group in a single undo tap.
                    let undoID = UUID().uuidString
                    var groupTiles: [(tile: TileNode, row: Int, col: Int)] = []
                    for r in 0..<tileGrid.count {
                        for c in 0..<tileGrid[r].count {
                            if tileGrid[r][c].quantumGroup == group {
                                groupTiles.append((tileGrid[r][c], r, c))
                            }
                        }
                    }
                    for member in groupTiles {
                        undoStack.append(UndoEntry(row: member.row, col: member.col,
                                                   previousRotation: member.tile.rotationSteps,
                                                   previousRole: nil,
                                                   undoGroupID: undoID))
                    }
                    // Capture pre-rotation state for MoveTrace before animation starts.
                    let traceCoords   = groupTiles.map { GridCoord(col: $0.col, row: $0.row) }
                    let tracePrevRots = groupTiles.map { $0.tile.rotationSteps }
                    let rotTimestamp  = CACurrentMediaTime()
                    TileNode.rotateQuantumGroup(groupTiles.map { $0.tile }) { [weak self] in
                        guard let self = self else { return }
                        let traceAfterRots = groupTiles.map { $0.tile.rotationSteps }
                        self.moveCount += 1
                        self.moveTrace.append(MoveEntry(
                            kind: .quantumRotate,
                            coords: traceCoords,
                            rotationBefore: tracePrevRots,
                            rotationAfter: traceAfterRots,
                            timestamp: rotTimestamp,
                            moveIndex: self.moveCount
                        ))
                        self.scheduleCompletionCheck()
                    }
                } else {
                    let prevRot      = tile.rotationSteps
                    let traceCoord   = GridCoord(col: pressedCol, row: pressedRow)
                    let rotTimestamp = CACurrentMediaTime()
                    undoStack.append(UndoEntry(row: pressedRow, col: pressedCol,
                                               previousRotation: prevRot,
                                               previousRole: nil,
                                               undoGroupID: UUID().uuidString))
                    tile.rotate { [weak self] in
                        guard let self = self else { return }
                        self.moveCount += 1
                        self.moveTrace.append(MoveEntry(
                            kind: .rotate,
                            coords: [traceCoord],
                            rotationBefore: [prevRot],
                            rotationAfter: [tile.rotationSteps],
                            timestamp: rotTimestamp,
                            moveIndex: self.moveCount
                        ))
                        self.scheduleCompletionCheck()
                    }
                }
            }
        }

        pressedTile = nil
        pressedRow = -1
        pressedCol = -1
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressStart = nil
        pressedTile?.releasePressState()
        pressedTile = nil
        pressedRow = -1
        pressedCol = -1
    }

    // MARK: - Hint system

    private func performHint() {
        guard !isSolved else { return }

        guard hintsRemaining > 0 else {
            // Shake + toast when hints are exhausted
            let shake = SKAction.sequence([
                SKAction.moveBy(x: -5, y: 0, duration: 0.04),
                SKAction.moveBy(x: 10, y: 0, duration: 0.04),
                SKAction.moveBy(x: -10, y: 0, duration: 0.04),
                SKAction.moveBy(x: 5, y: 0, duration: 0.04)
            ])
            hintButton.run(shake)
            showToast("No hints remaining")
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

        hintsRemaining -= 1
        hintCountLabel?.text = "\(hintsRemaining)"
        hintButton.accessibilityLabel = "Use hint, \(hintsRemaining) remaining"
        moveCount += 2  // Cost: +2 moves penalty

        SoundManager.shared.playButtonTap()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        showPremiumHintSpotlight(row: row, col: col)
    }

    // MARK: - Premium hint spotlight

    private func showPremiumHintSpotlight(row: Int, col: Int) {
        // Dismiss any existing spotlight first
        dismissHintSpotlight()

        let tile = tileGrid[row][col]
        let tileSize = tile.tileSize

        // Convert tile position (gridContainer space) → scene space
        let worldPos = convert(tile.position, from: gridContainer)

        // Elevate the hinted tile above the dim overlay
        tile.zPosition = 145   // gridContainer.zPosition(10) + 145 = 155, above overlay at 150
        hintedTile = tile

        let container = SKNode()
        container.zPosition = 150
        addChild(container)
        hintSpotlightNode = container

        // --- 1. Full-scene dim overlay ---
        let dim = SKShapeNode(rectOf: CGSize(width: size.width + 200, height: size.height + 200))
        dim.fillColor = UIColor(white: 0.0, alpha: 0.68)
        dim.strokeColor = .clear
        dim.position = CGPoint(x: size.width / 2, y: size.height / 2)
        dim.zPosition = 0
        container.addChild(dim)

        // --- 2. Expanding pulse ring (wide atmospheric glow) ---
        let pulseRing = SKShapeNode(circleOfRadius: tileSize * 0.72)
        pulseRing.fillColor = TileNode.colorAccent.withAlphaComponent(0.10)
        pulseRing.strokeColor = TileNode.colorAccent.withAlphaComponent(0.55)
        pulseRing.lineWidth = 2
        pulseRing.position = worldPos
        pulseRing.zPosition = 1
        container.addChild(pulseRing)

        pulseRing.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.group([
                SKAction.scale(to: 1.6, duration: 0.75),
                SKAction.fadeAlpha(to: 0.15, duration: 0.75)
            ]),
            SKAction.run {
                pulseRing.setScale(1.0)
                pulseRing.alpha = 0.8
            }
        ])))

        // --- 3. Steady inner highlight border around the tile ---
        let highlight = SKShapeNode(rectOf: CGSize(width: tileSize + 10, height: tileSize + 10),
                                    cornerRadius: 13)
        highlight.fillColor = TileNode.colorAccent.withAlphaComponent(0.08)
        highlight.strokeColor = TileNode.colorAccent
        highlight.lineWidth = 2.5
        highlight.position = worldPos
        highlight.zPosition = 2
        container.addChild(highlight)

        highlight.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.fadeAlpha(to: 1.0, duration: 0.38),
            SKAction.fadeAlpha(to: 0.45, duration: 0.38)
        ])))

        // --- 4. "Rotate this tile" label ---
        let instructionLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        instructionLabel.text = "Rotate this tile"
        instructionLabel.fontSize = 14
        instructionLabel.fontColor = .white
        instructionLabel.horizontalAlignmentMode = .center
        instructionLabel.verticalAlignmentMode = .center
        instructionLabel.zPosition = 3

        // Keep label inside the screen vertically
        let labelY = worldPos.y + tileSize / 2 + 44
        let clampedLabelY = min(labelY, size.height - 50)
        instructionLabel.position = CGPoint(x: worldPos.x, y: clampedLabelY)
        container.addChild(instructionLabel)

        // --- 5. Rotation count badge ---
        let needed = (tile.solutionRotation - tile.rotationSteps + 4) % 4
        if needed > 0 {
            let tapText = needed == 1 ? "1 tap to solve" : "\(needed) taps to solve"
            let badgeLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
            badgeLabel.text = tapText
            badgeLabel.fontSize = 12
            badgeLabel.fontColor = TileNode.colorAccent
            badgeLabel.horizontalAlignmentMode = .center
            badgeLabel.verticalAlignmentMode = .center

            let badgeW: CGFloat = CGFloat(tapText.count) * 7.5 + 20
            let badgeBg = SKShapeNode(rectOf: CGSize(width: badgeW, height: 22), cornerRadius: 11)
            badgeBg.fillColor = UIColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 0.96)
            badgeBg.strokeColor = TileNode.colorAccent.withAlphaComponent(0.45)
            badgeBg.lineWidth = 1

            let badgeY = clampedLabelY - 20
            badgeBg.position = CGPoint(x: worldPos.x, y: badgeY)
            badgeBg.zPosition = 3
            container.addChild(badgeBg)

            badgeLabel.position = CGPoint(x: worldPos.x, y: badgeY)
            badgeLabel.zPosition = 4
            container.addChild(badgeLabel)
        }

        // --- 6. Tap indicator (animated downward arrow) ---
        let arrowLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        arrowLabel.text = "▼"
        arrowLabel.fontSize = 16
        arrowLabel.fontColor = TileNode.colorAccent.withAlphaComponent(0.85)
        arrowLabel.horizontalAlignmentMode = .center
        arrowLabel.verticalAlignmentMode = .center

        let arrowY = worldPos.y + tileSize / 2 + 8
        arrowLabel.position = CGPoint(x: worldPos.x, y: arrowY)
        arrowLabel.zPosition = 3
        container.addChild(arrowLabel)

        arrowLabel.run(SKAction.repeatForever(SKAction.sequence([
            SKAction.moveBy(x: 0, y: -6, duration: 0.45),
            SKAction.moveBy(x: 0, y: 6, duration: 0.45)
        ])))

        // --- 7. Hints remaining badge (bottom of screen) ---
        if hintsRemaining > 0 {
            let remainingLabel = SKLabelNode(fontNamed: "AvenirNext-Regular")
            remainingLabel.text = "\(hintsRemaining) hint\(hintsRemaining == 1 ? "" : "s") remaining"
            remainingLabel.fontSize = 12
            remainingLabel.fontColor = UIColor(white: 0.50, alpha: 1)
            remainingLabel.horizontalAlignmentMode = .center
            remainingLabel.verticalAlignmentMode = .center
            remainingLabel.position = CGPoint(x: size.width / 2, y: 42)
            remainingLabel.zPosition = 3
            container.addChild(remainingLabel)
        }

        // --- 8. Fade in + auto-dismiss after 3.5 s ---
        container.alpha = 0
        container.run(SKAction.fadeAlpha(to: 1.0, duration: 0.22))

        container.run(SKAction.sequence([
            SKAction.wait(forDuration: 3.5),
            SKAction.fadeOut(withDuration: 0.28),
            SKAction.removeFromParent()
        ])) { [weak self] in
            guard let self = self else { return }
            self.hintedTile?.zPosition = 0
            self.hintedTile = nil
            if self.hintSpotlightNode === container {
                self.hintSpotlightNode = nil
            }
        }
    }

    private func dismissHintSpotlight() {
        hintedTile?.zPosition = 0
        hintedTile = nil
        hintSpotlightNode?.removeFromParent()
        hintSpotlightNode = nil
    }

    // MARK: - §6 Collapse overlay

    private func showCollapseOverlay(for tile: TileNode, row: Int, col: Int) {
        dismissCollapseOverlay()
        // Cancel press state — touchesEnded must not fire a rotation.
        tile.releasePressState()
        pressedTile = nil

        collapseTargetRow = row
        collapseTargetCol = col

        let worldPos  = convert(tile.position, from: gridContainer)
        let panelW: CGFloat = 188
        let panelH: CGFloat = 78

        var panelX = worldPos.x
        var panelY = worldPos.y + tile.tileSize / 2 + panelH / 2 + 14
        panelX = max(panelW / 2 + 10, min(size.width  - panelW / 2 - 10, panelX))
        panelY = max(panelH / 2 + 10, min(size.height - panelH / 2 - 10, panelY))

        let overlay = SKNode()
        overlay.zPosition = 120
        overlay.name = "collapseOverlay"

        // Invisible tap-catcher so any tap outside the panel dismisses it.
        let catcher = SKShapeNode(rectOf: CGSize(width: size.width * 2, height: size.height * 2))
        catcher.fillColor   = .clear
        catcher.strokeColor = .clear
        catcher.position    = CGPoint(x: size.width / 2, y: size.height / 2)
        catcher.name        = "collapseCancel"
        overlay.addChild(catcher)

        let panel = SKShapeNode(rectOf: CGSize(width: panelW, height: panelH), cornerRadius: 14)
        panel.fillColor   = UIColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 0.97)
        panel.strokeColor = UIColor(red: 0.72, green: 0.60, blue: 1.0, alpha: 0.55)
        panel.lineWidth   = 1.5
        panel.position    = CGPoint(x: panelX, y: panelY)
        overlay.addChild(panel)

        let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        label.text = "Collapse to:"
        label.fontSize = 12
        label.fontColor = UIColor(white: 0.65, alpha: 1)
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode   = .center
        label.position = CGPoint(x: panelX, y: panelY + 18)
        overlay.addChild(label)

        let btnA = makeActionButton(text: "State A", width: 76, height: 28,
                                    color: UIColor(red: 0.50, green: 0.30, blue: 0.95, alpha: 0.90),
                                    textColor: .white, name: "collapseA")
        btnA.position = CGPoint(x: panelX - 46, y: panelY - 14)
        overlay.addChild(btnA)

        let btnB = makeActionButton(text: "State B", width: 76, height: 28,
                                    color: UIColor(red: 0.25, green: 0.50, blue: 0.95, alpha: 0.90),
                                    textColor: .white, name: "collapseB")
        btnB.position = CGPoint(x: panelX + 46, y: panelY - 14)
        overlay.addChild(btnB)

        overlay.alpha = 0
        overlay.setScale(0.85)
        addChild(overlay)
        collapseOverlay = overlay

        overlay.run(SKAction.group([
            SKAction.fadeIn(withDuration: 0.14),
            SKAction.scale(to: 1.0, duration: 0.14)
        ]))

        SoundManager.shared.playButtonTap()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func dismissCollapseOverlay() {
        collapseOverlay?.removeFromParent()
        collapseOverlay    = nil
        collapseTargetRow  = -1
        collapseTargetCol  = -1
    }

    private func handleCollapseChoice(toB: Bool) {
        let row = collapseTargetRow
        let col = collapseTargetCol
        dismissCollapseOverlay()

        guard row >= 0, col >= 0,
              row < tileGrid.count, col < tileGrid[row].count else { return }
        let tile = tileGrid[row][col]
        guard case .superposed(_, _, false, _) = tile.role else { return }

        let prevRole = tile.role
        let prevRot  = tile.rotationSteps

        tile.collapseSuperposition(toB: toB)

        // Snap animation — tile visibly "decides" its state.
        let snapUp   = SKAction.scale(to: 1.08, duration: 0.07)
        let snapDown = SKAction.scale(to: 1.00, duration: 0.07)
        tile.run(SKAction.sequence([snapUp, snapDown]))
        tile.run(SKAction.sequence([
            SKAction.fadeAlpha(to: 0.65, duration: 0.04),
            SKAction.fadeAlpha(to: 1.00, duration: 0.12)
        ]))
        SoundManager.shared.playRotate()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Push undo — stores the pre-collapse role so performUndo can
        // return the tile to uncollapsed state with ghosts intact.
        undoStack.append(UndoEntry(row: row, col: col,
                                   previousRotation: prevRot,
                                   previousRole: prevRole,
                                   undoGroupID: UUID().uuidString))

        moveCount += 1
        moveTrace.append(MoveEntry(
            kind: .collapseSuper,
            coords: [GridCoord(col: col, row: row)],
            rotationBefore: [prevRot],
            rotationAfter: [tile.rotationSteps],
            timestamp: CACurrentMediaTime(),
            moveIndex: moveCount
        ))

        scheduleCompletionCheck()
    }

    // MARK: - Toast notification

    private func showToast(_ message: String) {
        let toast = SKNode()
        toast.position = CGPoint(x: size.width / 2, y: 80)
        toast.zPosition = 160

        let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        label.text = message
        label.fontSize = 13
        label.fontColor = .white
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center

        let pillW: CGFloat = max(140, CGFloat(message.count) * 7.8 + 28)
        let pill = SKShapeNode(rectOf: CGSize(width: pillW, height: 34), cornerRadius: 17)
        pill.fillColor = UIColor(white: 0.14, alpha: 0.96)
        pill.strokeColor = UIColor(white: 0.32, alpha: 1)
        pill.lineWidth = 1

        toast.addChild(pill)
        toast.addChild(label)
        addChild(toast)

        toast.run(SKAction.sequence([
            SKAction.wait(forDuration: 1.6),
            SKAction.group([
                SKAction.fadeOut(withDuration: 0.35),
                SKAction.moveBy(x: 0, y: 8, duration: 0.35)
            ]),
            SKAction.removeFromParent()
        ]))
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
        // Highlights panel lives inside the banner node, so it dismisses automatically.
        highlightsPanelNode = nil
        isHighlightsPanelShown = false

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

        // Collect all tiles to revert (first entry + rest of its quantum group).
        // We record before/after for the MoveTrace before touching any rotation.
        struct UndoRecord { let coord: GridCoord; let before: Int; let after: Int }
        var records: [UndoRecord] = []

        let beforeFirst = tileGrid[entry.row][entry.col].rotationSteps
        tileGrid[entry.row][entry.col].setRotation(entry.previousRotation)
        // §6 Collapse undo: restoring the role puts the tile back into the
        // uncollapsed superposed state, which re-triggers updateRoleVisuals()
        // and rebuilds the ghost overlays automatically.
        if let prevRole = entry.previousRole {
            tileGrid[entry.row][entry.col].role = prevRole
        }
        records.append(UndoRecord(coord: GridCoord(col: entry.col, row: entry.row),
                                  before: beforeFirst,
                                  after: entry.previousRotation))

        // §3 Quantum: pop the rest of the group atomically (they share the
        // same undoGroupID pushed by the quantum-group dispatch in touchesEnded).
        while let next = undoStack.last, next.undoGroupID == entry.undoGroupID {
            undoStack.removeLast()
            let beforeNext = tileGrid[next.row][next.col].rotationSteps
            tileGrid[next.row][next.col].setRotation(next.previousRotation)
            if let prevRole = next.previousRole {
                tileGrid[next.row][next.col].role = prevRole
            }
            records.append(UndoRecord(coord: GridCoord(col: next.col, row: next.row),
                                      before: beforeNext,
                                      after: next.previousRotation))
        }

        moveCount = max(0, moveCount - 1)

        moveTrace.append(MoveEntry(
            kind: .undo,
            coords: records.map { $0.coord },
            rotationBefore: records.map { $0.before },
            rotationAfter: records.map { $0.after },
            timestamp: CACurrentMediaTime(),
            moveIndex: moveCount
        ))

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

        // §5 Diode: fire a one-shot rejection pulse on every diode that
        // blocked flow this pass. Skipped on a solved board — no need to
        // flag errors when the puzzle is already won.
        if !result.isSolved {
            for coord in result.blockedDiodes {
                tileGrid[coord.row][coord.col].showRejectionPulse()
            }
        }

        if result.isSolved && !isSolved {
            isSolved = true
            timerActive = false
            let stars = calculateStars()
            let choreo = ChoreographyAnalyzer.analyze(trace: moveTrace, level: levelData)
            triggerWinSequence(moveStars: stars, choreoScore: choreo)
            gameDelegate?.gameScene(self, didCompleteLevel: levelData.id,
                                    moves: moveCount, stars: stars,
                                    choreoScore: choreo, trace: moveTrace)
        }
    }

    private func calculateStars() -> Int {
        if moveCount <= par     { return 3 }
        if moveCount <= par * 2 { return 2 }
        return 1
    }

    // MARK: - Win sequence

    private func triggerWinSequence(moveStars: Int, choreoScore: ChoreographyScore) {
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
                self?.showCompletionBanner(moveStars: moveStars, choreoScore: choreoScore)
            }
        ]))

        // 4. Success haptic + sound
        SoundManager.shared.playWin()
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    // MARK: - Completion banner (milestone 1.3: dual-scoring)
    //
    // Layout (card 300×300, banner anchored at scene centre + 10pt up):
    //   y=120  Title "Circuit Sealed!"
    //   y=88   "Completed in N moves"
    //   y=68   Time
    //   y=50   thin divider
    //   y=35   MOVES  ★★★   (gold)
    //   y=-3   ELEGANCE ★★☆ (accent blue)
    //   y=-30  "How?" chip — tap-to-reveal highlights
    //   y=-62  Next Level button
    //   y=-96  Replay / Menu buttons
    //
    // A separate highlightsPanelNode slides in below the card on "How?" tap.

    private func showCompletionBanner(moveStars: Int, choreoScore: ChoreographyScore) {
        // Cache highlights so the "How?" chip handler can build the panel.
        pendingHighlights = choreoScore.highlights
        isHighlightsPanelShown = false

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
        let cardH: CGFloat = 300
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
        title.fontSize = 28
        title.fontColor = TileNode.colorConnected
        title.position = CGPoint(x: 0, y: 120)
        title.verticalAlignmentMode = .center
        title.horizontalAlignmentMode = .center
        banner.addChild(title)

        // Move count
        let subtitle = SKLabelNode(fontNamed: "AvenirNext-Regular")
        subtitle.text = "Completed in \(moveCount) moves"
        subtitle.fontSize = 15
        subtitle.fontColor = UIColor(white: 0.70, alpha: 1)
        subtitle.position = CGPoint(x: 0, y: 88)
        subtitle.verticalAlignmentMode = .center
        subtitle.horizontalAlignmentMode = .center
        banner.addChild(subtitle)

        // Time
        let mins = Int(elapsedTime) / 60
        let secs = Int(elapsedTime) % 60
        let timeStr = String(format: "Time: %d:%02d", mins, secs)
        let timeLabel = SKLabelNode(fontNamed: "AvenirNext-Regular")
        timeLabel.text = timeStr
        timeLabel.fontSize = 13
        timeLabel.fontColor = UIColor(white: 0.50, alpha: 1)
        timeLabel.position = CGPoint(x: 0, y: 68)
        timeLabel.verticalAlignmentMode = .center
        timeLabel.horizontalAlignmentMode = .center
        banner.addChild(timeLabel)

        // Thin section divider
        let divPath = CGMutablePath()
        divPath.move(to: CGPoint(x: -110, y: 50))
        divPath.addLine(to: CGPoint(x: 110, y: 50))
        let divider = SKShapeNode(path: divPath)
        divider.strokeColor = UIColor(white: 1.0, alpha: 0.08)
        divider.lineWidth = 1
        banner.addChild(divider)

        // MARK: Row 1 — "MOVES" label + 3 gold stars

        let movesRowLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        movesRowLabel.text = "MOVES"
        movesRowLabel.fontSize = 11
        movesRowLabel.fontColor = UIColor(white: 0.50, alpha: 1)
        movesRowLabel.position = CGPoint(x: -118, y: 35)
        movesRowLabel.horizontalAlignmentMode = .left
        movesRowLabel.verticalAlignmentMode = .center
        banner.addChild(movesRowLabel)

        let moveStarXPositions: [CGFloat] = [10, 42, 74]
        for (i, xPos) in moveStarXPositions.enumerated() {
            let earned = i < moveStars
            let starLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
            starLabel.text = earned ? "\u{2605}" : "\u{2606}"
            starLabel.fontSize = 30
            starLabel.fontColor = earned ? TileNode.colorGold : UIColor(white: 0.25, alpha: 1)
            starLabel.position = CGPoint(x: xPos, y: 35)
            starLabel.verticalAlignmentMode = .center
            starLabel.horizontalAlignmentMode = .center
            starLabel.setScale(0.0)
            starLabel.accessibilityLabel = earned ? "Move star earned" : "Move star not earned"
            starLabel.isAccessibilityElement = true
            banner.addChild(starLabel)

            let delay = 0.3 + Double(i) * 0.12
            starLabel.run(SKAction.sequence([
                SKAction.wait(forDuration: delay),
                SKAction.scale(to: earned ? 1.25 : 0.9, duration: 0.18),
                SKAction.scale(to: 1.0, duration: 0.08)
            ]))
            if earned {
                starLabel.run(SKAction.sequence([
                    SKAction.wait(forDuration: delay + 0.18),
                    SKAction.run { [weak self] in self?.addStarSparkle(at: starLabel, in: banner) }
                ]))
            }
        }

        // MARK: Row 2 — "ELEGANCE" label + 3 accent-blue stars

        let eleganceRowLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        eleganceRowLabel.text = "ELEGANCE"
        eleganceRowLabel.fontSize = 11
        eleganceRowLabel.fontColor = UIColor(white: 0.50, alpha: 1)
        eleganceRowLabel.position = CGPoint(x: -118, y: -3)
        eleganceRowLabel.horizontalAlignmentMode = .left
        eleganceRowLabel.verticalAlignmentMode = .center
        banner.addChild(eleganceRowLabel)

        let choreoStarXPositions: [CGFloat] = [10, 42, 74]
        for (i, xPos) in choreoStarXPositions.enumerated() {
            let earned = i < choreoScore.stars
            let starLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
            starLabel.text = earned ? "\u{2605}" : "\u{2606}"
            starLabel.fontSize = 30
            starLabel.fontColor = earned ? TileNode.colorAccent : UIColor(white: 0.25, alpha: 1)
            starLabel.position = CGPoint(x: xPos, y: -3)
            starLabel.verticalAlignmentMode = .center
            starLabel.horizontalAlignmentMode = .center
            starLabel.setScale(0.0)
            starLabel.accessibilityLabel = earned ? "Elegance star earned" : "Elegance star not earned"
            starLabel.isAccessibilityElement = true
            banner.addChild(starLabel)

            let delay = 0.6 + Double(i) * 0.12
            starLabel.run(SKAction.sequence([
                SKAction.wait(forDuration: delay),
                SKAction.scale(to: earned ? 1.25 : 0.9, duration: 0.18),
                SKAction.scale(to: 1.0, duration: 0.08)
            ]))
        }

        // Banner-level accessibility summary (both scores)
        let moveStarWord  = moveStars == 1 ? "star" : "stars"
        let choreoStarWord = choreoScore.stars == 1 ? "star" : "stars"
        banner.accessibilityLabel = "Level complete. Moves: \(moveStars) \(moveStarWord). Elegance: \(choreoScore.stars) \(choreoStarWord)."
        banner.isAccessibilityElement = false   // children carry individual labels

        // MARK: "How?" chip — tap-to-reveal highlights
        //
        // Points are intentionally hidden until the player taps "How?" to avoid
        // overwhelming first-time viewers (design rule: stars only by default).

        let howNode = SKNode()
        howNode.name = "howChip"

        let howBg = SKShapeNode(rectOf: CGSize(width: 76, height: 24), cornerRadius: 12)
        howBg.fillColor = UIColor(white: 0.18, alpha: 1)
        howBg.strokeColor = TileNode.colorAccent.withAlphaComponent(0.45)
        howBg.lineWidth = 1
        howBg.name = "howChip"
        howNode.addChild(howBg)

        let howLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        howLabel.text = "How? \u{25BE}"      // ▾ closed-triangle indicates expandable
        howLabel.fontSize = 12
        howLabel.fontColor = TileNode.colorAccent
        howLabel.verticalAlignmentMode = .center
        howLabel.horizontalAlignmentMode = .center
        howLabel.name = "howChipLabel"
        howNode.addChild(howLabel)

        howNode.position = CGPoint(x: 0, y: -30)
        howNode.accessibilityLabel = "How does Elegance scoring work? Tap to expand."
        howNode.isAccessibilityElement = true
        howNode.accessibilityTraits = .button
        banner.addChild(howNode)

        // MARK: Action buttons

        let isLastLevel = levelData.id >= (try? LevelLoader.load().levels.count) ?? 0
        let buttonY: CGFloat = -62

        if !isLastLevel {
            let nextBtn = makeActionButton(text: "Next Level", width: 160, height: 44,
                                           color: TileNode.colorConnected,
                                           textColor: UIColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
                                           name: "nextButton")
            nextBtn.position = CGPoint(x: 0, y: buttonY)
            banner.addChild(nextBtn)
        }

        let replayBtn = makeActionButton(text: "Replay", width: 120, height: 36,
                                          color: UIColor(white: 0.20, alpha: 1),
                                          textColor: UIColor(white: 0.70, alpha: 1),
                                          name: "replayButton")
        replayBtn.position = CGPoint(x: isLastLevel ? 60 : 0,
                                      y: buttonY - (isLastLevel ? 0 : 48))
        banner.addChild(replayBtn)

        let menuBtn = makeActionButton(text: "Menu", width: 100, height: 36,
                                        color: UIColor(white: 0.20, alpha: 1),
                                        textColor: UIColor(white: 0.70, alpha: 1),
                                        name: "menuButton")
        menuBtn.position = CGPoint(x: isLastLevel ? -60 : 0,
                                    y: buttonY - (isLastLevel ? 0 : 84))
        banner.addChild(menuBtn)

        addChild(banner)
        bannerNode = banner

        // Animate banner in
        let fadeIn = SKAction.fadeIn(withDuration: 0.3)
        let scaleUp = SKAction.scale(to: 1.0, duration: 0.3)
        scaleUp.timingMode = .easeOut
        banner.run(SKAction.group([fadeIn, scaleUp]))
    }

    // MARK: - Highlights panel (How? chip expansion)

    private func showHighlightsPanel() {
        guard !isHighlightsPanelShown, let banner = bannerNode else { return }
        isHighlightsPanelShown = true

        // Update chip label to indicate collapse
        if let chip = banner.childNode(withName: "howChip"),
           let lbl = chip.childNode(withName: "howChipLabel") as? SKLabelNode {
            lbl.text = "How? \u{25B4}"     // ▴ open-triangle
        }

        let highlights = pendingHighlights
        let lineH: CGFloat = 22
        let panelPad: CGFloat = 14
        let panelH: CGFloat = max(60, CGFloat(highlights.count) * lineH + panelPad * 2)
        let panelW: CGFloat = 280

        let panel = SKNode()
        panel.zPosition = 101
        // Position below the main card (card bottom is at y = -150 in banner coords)
        panel.position = CGPoint(x: 0, y: -150 - panelH / 2 - 8)
        panel.alpha = 0

        let bg = SKShapeNode(rectOf: CGSize(width: panelW, height: panelH), cornerRadius: 14)
        bg.fillColor = UIColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 0.97)
        bg.strokeColor = TileNode.colorAccent.withAlphaComponent(0.25)
        bg.lineWidth = 1
        panel.addChild(bg)

        if highlights.isEmpty {
            let noHighlight = SKLabelNode(fontNamed: "AvenirNext-Regular")
            noHighlight.text = "No patterns detected this solve."
            noHighlight.fontSize = 12
            noHighlight.fontColor = UIColor(white: 0.45, alpha: 1)
            noHighlight.verticalAlignmentMode = .center
            noHighlight.horizontalAlignmentMode = .center
            noHighlight.position = CGPoint(x: 0, y: 0)
            panel.addChild(noHighlight)
        } else {
            let startY = (panelH / 2) - panelPad - lineH / 2
            for (i, highlight) in highlights.enumerated() {
                let row = SKNode()
                row.position = CGPoint(x: 0, y: startY - CGFloat(i) * lineH)

                // Bullet + description
                let bullet = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
                bullet.text = "\u{2022}"
                bullet.fontSize = 11
                bullet.fontColor = TileNode.colorAccent
                bullet.verticalAlignmentMode = .center
                bullet.horizontalAlignmentMode = .left
                bullet.position = CGPoint(x: -panelW / 2 + 12, y: 0)
                row.addChild(bullet)

                let desc = SKLabelNode(fontNamed: "AvenirNext-Regular")
                desc.text = highlight.description
                desc.fontSize = 11
                desc.fontColor = UIColor(white: 0.80, alpha: 1)
                desc.verticalAlignmentMode = .center
                desc.horizontalAlignmentMode = .left
                desc.position = CGPoint(x: -panelW / 2 + 24, y: 0)
                desc.accessibilityLabel = highlight.description
                desc.isAccessibilityElement = true
                row.addChild(desc)

                // Points badge (expanded panel is the one place we show raw pts)
                let pts = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
                pts.text = "+\(highlight.points)"
                pts.fontSize = 10
                pts.fontColor = TileNode.colorGold
                pts.verticalAlignmentMode = .center
                pts.horizontalAlignmentMode = .right
                pts.position = CGPoint(x: panelW / 2 - 12, y: 0)
                row.addChild(pts)

                panel.addChild(row)
            }
        }

        banner.addChild(panel)
        highlightsPanelNode = panel

        panel.run(SKAction.group([
            SKAction.fadeIn(withDuration: 0.22),
            SKAction.sequence([
                SKAction.moveBy(x: 0, y: -8, duration: 0),
                SKAction.moveBy(x: 0, y: 8, duration: 0.22)
            ])
        ]))
    }

    private func hideHighlightsPanel() {
        guard isHighlightsPanelShown, let banner = bannerNode else { return }
        isHighlightsPanelShown = false

        if let chip = banner.childNode(withName: "howChip"),
           let lbl = chip.childNode(withName: "howChipLabel") as? SKLabelNode {
            lbl.text = "How? \u{25BE}"
        }

        highlightsPanelNode?.run(SKAction.sequence([
            SKAction.fadeOut(withDuration: 0.15),
            SKAction.removeFromParent()
        ]))
        highlightsPanelNode = nil
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
