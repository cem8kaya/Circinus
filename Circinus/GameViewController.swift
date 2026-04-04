import UIKit
import SpriteKit

// MARK: - LevelProgress

enum LevelProgress {
    static func save(levelID: Int, stars: Int) {
        let key = "level_\(levelID)_stars"
        if stars > UserDefaults.standard.integer(forKey: key) {
            UserDefaults.standard.set(stars, forKey: key)
        }
    }

    static func stars(for levelID: Int) -> Int {
        UserDefaults.standard.integer(forKey: "level_\(levelID)_stars")
    }

    static func saveBestMoves(levelID: Int, moves: Int) {
        let key = "level_\(levelID)_best"
        let prev = UserDefaults.standard.integer(forKey: key)
        if prev == 0 || moves < prev {
            UserDefaults.standard.set(moves, forKey: key)
        }
    }

    static func bestMoves(for levelID: Int) -> Int {
        UserDefaults.standard.integer(forKey: "level_\(levelID)_best")
    }

    static func totalStars(levelCount: Int) -> Int {
        (1...levelCount).reduce(0) { $0 + stars(for: $1) }
    }

    static func isUnlocked(levelID: Int) -> Bool {
        if levelID <= 1 { return true }
        return stars(for: levelID - 1) > 0
    }
}

// MARK: - BackgroundParticles

final class BackgroundParticles: SKNode {

    private let sceneSize: CGSize

    init(sceneSize: CGSize) {
        self.sceneSize = sceneSize
        super.init()
        spawnParticles()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func spawnParticles() {
        let particleCount = 25
        for _ in 0..<particleCount {
            let dot = SKShapeNode(circleOfRadius: CGFloat.random(in: 1.0...2.5))
            dot.fillColor = UIColor(white: 1.0, alpha: CGFloat.random(in: 0.03...0.10))
            dot.strokeColor = .clear
            dot.zPosition = 1
            dot.position = CGPoint(
                x: CGFloat.random(in: 0...sceneSize.width),
                y: CGFloat.random(in: 0...sceneSize.height)
            )
            addChild(dot)
            animateParticle(dot)
        }
    }

    private func animateParticle(_ dot: SKShapeNode) {
        let dur = Double.random(in: 6.0...14.0)
        let dx = CGFloat.random(in: -30...30)
        let dy = CGFloat.random(in: 15...40)
        let drift = SKAction.moveBy(x: dx, y: dy, duration: dur)
        let fadeOut = SKAction.fadeAlpha(to: 0.01, duration: dur)
        let group = SKAction.group([drift, fadeOut])

        dot.run(group) { [weak self] in
            guard let self = self else { return }
            dot.position = CGPoint(
                x: CGFloat.random(in: 0...self.sceneSize.width),
                y: CGFloat.random(in: -10...self.sceneSize.height * 0.3)
            )
            dot.alpha = CGFloat.random(in: 0.03...0.10)
            self.animateParticle(dot)
        }
    }
}

// MARK: - MenuScene

final class MenuScene: SKScene {

    var onStartGame: (() -> Void)?
    var onLevelSelect: (() -> Void)?
    private var totalStarCount: Int = 0
    private var levelCount: Int = 0

    func configure(levelCount: Int) {
        self.levelCount = levelCount
        self.totalStarCount = LevelProgress.totalStars(levelCount: levelCount)
    }

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)
        buildMenu()
    }

    private func buildMenu() {
        // Ambient particles
        let particles = BackgroundParticles(sceneSize: size)
        particles.zPosition = 1
        addChild(particles)

        // Title with glow
        let titleGlow = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        titleGlow.text = "CIRCINUS"
        titleGlow.fontSize = 64
        titleGlow.fontColor = TileNode.colorConnected.withAlphaComponent(0.3)
        titleGlow.position = CGPoint(x: size.width / 2, y: size.height * 0.66)
        titleGlow.horizontalAlignmentMode = .center
        titleGlow.verticalAlignmentMode = .center
        titleGlow.zPosition = 9
        addChild(titleGlow)

        // Glow pulse
        let glowPulse = SKAction.sequence([
            SKAction.fadeAlpha(to: 0.15, duration: 2.0),
            SKAction.fadeAlpha(to: 0.35, duration: 2.0)
        ])
        titleGlow.run(SKAction.repeatForever(glowPulse))

        let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        title.text = "CIRCINUS"
        title.fontSize = 64
        title.fontColor = TileNode.colorConnected
        title.position = CGPoint(x: size.width / 2, y: size.height * 0.66)
        title.horizontalAlignmentMode = .center
        title.verticalAlignmentMode = .center
        title.zPosition = 10
        addChild(title)

        // Subtitle
        let subtitle = SKLabelNode(fontNamed: "AvenirNext-Medium")
        subtitle.text = "C L O S E  T H E  C I R C U I T"
        subtitle.fontSize = 14
        subtitle.fontColor = UIColor(white: 0.45, alpha: 1)
        subtitle.position = CGPoint(x: size.width / 2, y: size.height * 0.58)
        subtitle.horizontalAlignmentMode = .center
        subtitle.verticalAlignmentMode = .center
        subtitle.zPosition = 10
        addChild(subtitle)

        // Star count display
        if totalStarCount > 0 {
            let starDisplay = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
            starDisplay.text = "\u{2605} \(totalStarCount) / \(levelCount * 3)"
            starDisplay.fontSize = 16
            starDisplay.fontColor = TileNode.colorGold
            starDisplay.position = CGPoint(x: size.width / 2, y: size.height * 0.54)
            starDisplay.horizontalAlignmentMode = .center
            starDisplay.verticalAlignmentMode = .center
            starDisplay.zPosition = 10
            addChild(starDisplay)
        }

        // Demo tile grid
        let demoPositions: [(CGFloat, CGFloat, TileType)] = [
            (0.30, 0.46, .corner),   (0.50, 0.46, .straight), (0.70, 0.46, .corner),
            (0.30, 0.40, .straight),                           (0.70, 0.40, .straight),
            (0.30, 0.34, .corner),   (0.50, 0.34, .straight), (0.70, 0.34, .corner)
        ]

        for (fx, fy, tileType) in demoPositions {
            let tile = TileNode(type: tileType, size: 48, initialRotation: Int.random(in: 0...3))
            tile.position = CGPoint(x: size.width * fx, y: size.height * fy)
            tile.isUserInteractionEnabled = false
            tile.zPosition = 10
            addChild(tile)

            let waitDur = Double.random(in: 1.5...3.5)
            let rotateAction = SKAction.rotate(byAngle: -.pi / 2, duration: 0.3)
            rotateAction.timingMode = .easeInEaseOut
            tile.run(SKAction.repeatForever(SKAction.sequence([
                SKAction.wait(forDuration: waitDur),
                rotateAction
            ])))
        }

        // PLAY button
        let playButton = makeButton(text: "PLAY", width: 200, height: 54,
                                     color: TileNode.colorConnected, textColor: UIColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
                                     name: "playButton")
        playButton.position = CGPoint(x: size.width / 2, y: size.height * 0.22)
        playButton.zPosition = 50
        addChild(playButton)

        // Button pulse
        let pulseUp   = SKAction.scale(to: 1.03, duration: 0.8)
        pulseUp.timingMode = .easeInEaseOut
        let pulseDown = SKAction.scale(to: 0.97, duration: 0.8)
        pulseDown.timingMode = .easeInEaseOut
        playButton.run(SKAction.repeatForever(SKAction.sequence([pulseUp, pulseDown])))

        // LEVELS button
        let levelsButton = makeButton(text: "LEVELS", width: 200, height: 44,
                                       color: UIColor(white: 0.16, alpha: 1),
                                       textColor: UIColor(white: 0.7, alpha: 1),
                                       name: "levelsButton")
        levelsButton.position = CGPoint(x: size.width / 2, y: size.height * 0.14)
        levelsButton.zPosition = 50
        addChild(levelsButton)
    }

    private func makeButton(text: String, width: CGFloat, height: CGFloat,
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
        label.fontSize = 18
        label.fontColor = textColor
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.name = name
        node.addChild(label)

        return node
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let loc = touch.location(in: self)
        let tapped = nodes(at: loc)

        for node in tapped {
            let name = node.name ?? node.parent?.name
            if name == "playButton" {
                animateButtonTap(node.name == "playButton" ? node : node.parent!) {
                    self.onStartGame?()
                }
                return
            }
            if name == "levelsButton" {
                animateButtonTap(node.name == "levelsButton" ? node : node.parent!) {
                    self.onLevelSelect?()
                }
                return
            }
        }
    }

    private func animateButtonTap(_ node: SKNode, completion: @escaping () -> Void) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        node.run(SKAction.sequence([
            SKAction.scale(to: 0.92, duration: 0.06),
            SKAction.scale(to: 1.0, duration: 0.06),
            SKAction.run { completion() }
        ]))
    }
}

// MARK: - LevelSelectScene

final class LevelSelectScene: SKScene {

    var onSelectLevel: ((Int) -> Void)?
    var onBack: (() -> Void)?
    private var allLevels: [LevelData] = []

    func configure(levels: [LevelData]) {
        self.allLevels = levels
    }

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)
        buildUI()
    }

    private func buildUI() {
        // Ambient particles
        let particles = BackgroundParticles(sceneSize: size)
        particles.zPosition = 1
        addChild(particles)

        // Title
        let title = SKLabelNode(fontNamed: "AvenirNext-Bold")
        title.text = "SELECT LEVEL"
        title.fontSize = 28
        title.fontColor = .white
        title.position = CGPoint(x: size.width / 2, y: size.height - 70)
        title.horizontalAlignmentMode = .center
        title.zPosition = 10
        addChild(title)

        // Back button
        let backBtn = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        backBtn.text = "\u{2190} Back"
        backBtn.fontSize = 18
        backBtn.fontColor = UIColor(white: 0.55, alpha: 1)
        backBtn.position = CGPoint(x: 55, y: size.height - 70)
        backBtn.horizontalAlignmentMode = .left
        backBtn.name = "backButton"
        backBtn.zPosition = 10
        addChild(backBtn)

        // Level grid
        let cols = 2
        let cardW: CGFloat = 140
        let cardH: CGFloat = 120
        let spacingX: CGFloat = 20
        let spacingY: CGFloat = 18
        let totalW = CGFloat(cols) * cardW + CGFloat(cols - 1) * spacingX
        let startX = (size.width - totalW) / 2 + cardW / 2
        let startY = size.height - 150

        for (index, level) in allLevels.enumerated() {
            let col = index % cols
            let row = index / cols
            let x = startX + CGFloat(col) * (cardW + spacingX)
            let y = startY - CGFloat(row) * (cardH + spacingY)

            let unlocked = LevelProgress.isUnlocked(levelID: level.id)
            let stars = LevelProgress.stars(for: level.id)
            let best = LevelProgress.bestMoves(for: level.id)

            let card = buildLevelCard(level: level, unlocked: unlocked, stars: stars,
                                       bestMoves: best, cardSize: CGSize(width: cardW, height: cardH))
            card.position = CGPoint(x: x, y: y)
            card.zPosition = 10
            card.name = "level_\(level.id)"

            // Entrance animation
            card.alpha = 0
            card.setScale(0.7)
            let delay = Double(index) * 0.06
            card.run(SKAction.sequence([
                SKAction.wait(forDuration: delay),
                SKAction.group([
                    SKAction.fadeIn(withDuration: 0.25),
                    SKAction.scale(to: 1.0, duration: 0.25)
                ])
            ]))

            addChild(card)
        }
    }

    private func buildLevelCard(level: LevelData, unlocked: Bool, stars: Int,
                                 bestMoves: Int, cardSize: CGSize) -> SKNode {
        let node = SKNode()
        node.name = "level_\(level.id)"

        let bg = SKShapeNode(rectOf: cardSize, cornerRadius: 14)
        bg.fillColor = unlocked ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.09, alpha: 1)
        bg.strokeColor = unlocked ? UIColor(white: 0.24, alpha: 1) : UIColor(white: 0.14, alpha: 1)
        bg.lineWidth = 1.5
        bg.name = "level_\(level.id)"
        node.addChild(bg)

        if unlocked {
            // Level number
            let numLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            numLabel.text = "\(level.id)"
            numLabel.fontSize = 32
            numLabel.fontColor = stars > 0 ? TileNode.colorConnected : UIColor(white: 0.6, alpha: 1)
            numLabel.position = CGPoint(x: 0, y: 14)
            numLabel.verticalAlignmentMode = .center
            numLabel.name = "level_\(level.id)"
            node.addChild(numLabel)

            // Level name
            let nameLabel = SKLabelNode(fontNamed: "AvenirNext-Medium")
            nameLabel.text = level.name
            nameLabel.fontSize = 12
            nameLabel.fontColor = UIColor(white: 0.50, alpha: 1)
            nameLabel.position = CGPoint(x: 0, y: -6)
            nameLabel.verticalAlignmentMode = .center
            nameLabel.name = "level_\(level.id)"
            node.addChild(nameLabel)

            // Stars
            let starStr: String
            switch stars {
            case 3:  starStr = "\u{2605}\u{2605}\u{2605}"
            case 2:  starStr = "\u{2605}\u{2605}\u{2606}"
            case 1:  starStr = "\u{2605}\u{2606}\u{2606}"
            default: starStr = "\u{2606}\u{2606}\u{2606}"
            }
            let starLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
            starLabel.text = starStr
            starLabel.fontSize = 18
            starLabel.fontColor = stars > 0 ? TileNode.colorGold : UIColor(white: 0.30, alpha: 1)
            starLabel.position = CGPoint(x: 0, y: -28)
            starLabel.verticalAlignmentMode = .center
            starLabel.name = "level_\(level.id)"
            node.addChild(starLabel)

            // Best moves
            if bestMoves > 0 {
                let bestLabel = SKLabelNode(fontNamed: "AvenirNext-Regular")
                bestLabel.text = "Best: \(bestMoves)"
                bestLabel.fontSize = 10
                bestLabel.fontColor = UIColor(white: 0.40, alpha: 1)
                bestLabel.position = CGPoint(x: 0, y: -44)
                bestLabel.verticalAlignmentMode = .center
                bestLabel.name = "level_\(level.id)"
                node.addChild(bestLabel)
            }
        } else {
            // Lock icon
            let lock = SKLabelNode(fontNamed: "AvenirNext-Heavy")
            lock.text = "\u{1F512}"
            lock.fontSize = 28
            lock.position = CGPoint(x: 0, y: 4)
            lock.verticalAlignmentMode = .center
            lock.name = "level_\(level.id)"
            node.addChild(lock)

            let lockLabel = SKLabelNode(fontNamed: "AvenirNext-Medium")
            lockLabel.text = "Locked"
            lockLabel.fontSize = 12
            lockLabel.fontColor = UIColor(white: 0.30, alpha: 1)
            lockLabel.position = CGPoint(x: 0, y: -20)
            lockLabel.verticalAlignmentMode = .center
            lockLabel.name = "level_\(level.id)"
            node.addChild(lockLabel)
        }

        return node
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let loc = touch.location(in: self)
        let tapped = nodes(at: loc)

        for node in tapped {
            let name = node.name ?? ""
            if name == "backButton" {
                onBack?()
                return
            }
            if name.hasPrefix("level_"), let idStr = name.split(separator: "_").last,
               let id = Int(idStr), LevelProgress.isUnlocked(levelID: id) {
                // Tap animation
                let target = children.first { $0.name == "level_\(id)" } ?? node
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                target.run(SKAction.sequence([
                    SKAction.scale(to: 0.92, duration: 0.06),
                    SKAction.scale(to: 1.0, duration: 0.06),
                    SKAction.run { [weak self] in self?.onSelectLevel?(id) }
                ]))
                return
            }
        }
    }
}

// MARK: - GameViewController

final class GameViewController: UIViewController {

    private var skView: SKView!
    private var allLevels: [LevelData] = []
    private var currentLevelIndex: Int = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSKView()
        loadLevels()
        presentMainMenu()
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: - Setup

    private func setupSKView() {
        skView = SKView(frame: view.bounds)
        skView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        skView.ignoresSiblingOrder = true
        view.addSubview(skView)

        #if DEBUG
        skView.showsFPS = true
        skView.showsNodeCount = true
        #endif
    }

    private func loadLevels() {
        do {
            let pack = try LevelLoader.load()
            allLevels = pack.levels.filter { LevelLoader.validate($0) }
        } catch {
            allLevels = LevelLoader.fallbackLevels()
        }
    }

    private func presentMainMenu() {
        let menu = MenuScene(size: skView.bounds.size)
        menu.scaleMode = .resizeFill
        menu.configure(levelCount: allLevels.count)
        menu.onStartGame = { [weak self] in
            guard let self = self else { return }
            // Start from first incomplete level
            var startLevel = 1
            for level in self.allLevels {
                if LevelProgress.stars(for: level.id) == 0 {
                    startLevel = level.id
                    break
                }
                startLevel = level.id
            }
            self.startGame(levelIndex: startLevel)
        }
        menu.onLevelSelect = { [weak self] in
            self?.presentLevelSelect()
        }
        skView.presentScene(menu, transition: .fade(withDuration: 0.4))
    }

    private func presentLevelSelect() {
        let scene = LevelSelectScene(size: skView.bounds.size)
        scene.scaleMode = .resizeFill
        scene.configure(levels: allLevels)
        scene.onSelectLevel = { [weak self] id in
            self?.startGame(levelIndex: id)
        }
        scene.onBack = { [weak self] in
            self?.presentMainMenu()
        }
        skView.presentScene(scene, transition: .push(with: .left, duration: 0.3))
    }

    func startGame(levelIndex: Int) {
        guard levelIndex >= 1, levelIndex <= allLevels.count else {
            presentMainMenu()
            return
        }

        currentLevelIndex = levelIndex

        let scene = GameScene(size: skView.bounds.size)
        scene.scaleMode = .resizeFill
        scene.gameDelegate = self
        skView.presentScene(scene, transition: .push(with: .left, duration: 0.3))
        scene.loadLevel(allLevels[levelIndex - 1])
    }
}

// MARK: - GameSceneDelegate

extension GameViewController: GameSceneDelegate {
    func gameScene(_ scene: GameScene, didCompleteLevel levelID: Int,
                   moves: Int, stars: Int) {
        LevelProgress.save(levelID: levelID, stars: stars)
        LevelProgress.saveBestMoves(levelID: levelID, moves: moves)
    }

    func gameSceneDidRequestNextLevel(_ scene: GameScene, currentLevelID: Int) {
        let next = currentLevelID + 1
        if next <= allLevels.count {
            startGame(levelIndex: next)
        } else {
            presentLevelSelect()
        }
    }

    func gameSceneDidRequestRestart(_ scene: GameScene, levelID: Int) {
        startGame(levelIndex: levelID)
    }

    func gameSceneDidRequestMenu(_ scene: GameScene) {
        presentMainMenu()
    }
}
