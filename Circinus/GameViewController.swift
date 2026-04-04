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
}

// MARK: - MenuScene

final class MenuScene: SKScene {

    var onStartGame: (() -> Void)?

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        buildMenu()
    }

    private func buildMenu() {
        // Title
        let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        title.text = "CIRCINUS"
        title.fontSize = 62
        title.fontColor = TileNode.colorConnected
        title.position = CGPoint(x: size.width / 2, y: size.height * 0.65)
        title.horizontalAlignmentMode = .center
        title.verticalAlignmentMode = .center
        addChild(title)

        // Subtitle
        let subtitle = SKLabelNode(fontNamed: "AvenirNext-Medium")
        subtitle.text = "C L O S E  T H E  C I R C U I T"
        subtitle.fontSize = 16
        subtitle.fontColor = UIColor(white: 0.55, alpha: 1)
        subtitle.position = CGPoint(x: size.width / 2, y: size.height * 0.57)
        subtitle.horizontalAlignmentMode = .center
        subtitle.verticalAlignmentMode = .center
        addChild(subtitle)

        // Demo tile grid
        let demoPositions: [(CGFloat, CGFloat, TileType)] = [
            (0.30, 0.46, .corner),   (0.50, 0.46, .straight), (0.70, 0.46, .corner),
            (0.30, 0.40, .straight),                           (0.70, 0.40, .straight),
            (0.30, 0.34, .corner),   (0.50, 0.34, .straight), (0.70, 0.34, .corner)
        ]

        for (fx, fy, tileType) in demoPositions {
            let tile = TileNode(type: tileType, size: 50, initialRotation: Int.random(in: 0...3))
            tile.position = CGPoint(x: size.width * fx, y: size.height * fy)
            tile.isUserInteractionEnabled = false
            addChild(tile)

            // Random auto-rotation
            let waitDur = Double.random(in: 1.0...3.0)
            let rotateAction = SKAction.rotate(byAngle: -.pi / 2, duration: 0.3)
            rotateAction.timingMode = .easeInEaseOut
            tile.run(SKAction.repeatForever(SKAction.sequence([
                SKAction.wait(forDuration: waitDur),
                rotateAction
            ])))
        }

        // PLAY button
        let buttonNode = SKNode()
        buttonNode.name = "playButton"
        buttonNode.position = CGPoint(x: size.width / 2, y: size.height * 0.22)
        buttonNode.zPosition = 50

        let buttonBG = SKShapeNode(rectOf: CGSize(width: 180, height: 56), cornerRadius: 28)
        buttonBG.fillColor = TileNode.colorConnected
        buttonBG.strokeColor = .clear
        buttonBG.name = "playButton"
        buttonNode.addChild(buttonBG)

        let buttonLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
        buttonLabel.text = "PLAY"
        buttonLabel.fontSize = 22
        buttonLabel.fontColor = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        buttonLabel.verticalAlignmentMode = .center
        buttonLabel.horizontalAlignmentMode = .center
        buttonLabel.name = "playButton"
        buttonNode.addChild(buttonLabel)

        addChild(buttonNode)

        // Button pulse
        let pulseUp   = SKAction.scale(to: 1.04, duration: 0.7)
        pulseUp.timingMode = .easeInEaseOut
        let pulseDown = SKAction.scale(to: 0.97, duration: 0.7)
        pulseDown.timingMode = .easeInEaseOut
        buttonNode.run(SKAction.repeatForever(SKAction.sequence([pulseUp, pulseDown])))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let loc = touch.location(in: self)
        let tapped = nodes(at: loc)

        for node in tapped {
            if node.name == "playButton" || node.parent?.name == "playButton" {
                onStartGame?()
                return
            }
        }
    }
}

// MARK: - GameViewController

final class GameViewController: UIViewController {

    private var skView: SKView!
    private var allLevels: [LevelData] = []

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
        menu.onStartGame = { [weak self] in
            self?.startGame(levelIndex: 1)
        }
        skView.presentScene(menu, transition: .fade(withDuration: 0.4))
    }

    func startGame(levelIndex: Int) {
        guard levelIndex >= 1, levelIndex <= allLevels.count else {
            presentMainMenu()
            return
        }

        let scene = GameScene(size: skView.bounds.size)
        scene.scaleMode = .resizeFill
        scene.gameDelegate = self
        skView.presentScene(scene, transition: .push(with: .left, duration: 0.35))
        scene.loadLevel(allLevels[levelIndex - 1])
    }
}

// MARK: - GameSceneDelegate

extension GameViewController: GameSceneDelegate {
    func gameScene(_ scene: GameScene, didCompleteLevel levelID: Int,
                   moves: Int, stars: Int) {
        LevelProgress.save(levelID: levelID, stars: stars)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            let next = levelID + 1
            if next <= self.allLevels.count {
                self.startGame(levelIndex: next)
            } else {
                self.presentMainMenu()
            }
        }
    }
}
