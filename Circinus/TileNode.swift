import SpriteKit
import UIKit

// MARK: - ConnectionSide

enum ConnectionSide: String, Codable, CaseIterable {
    case top, right, bottom, left

    var opposite: ConnectionSide {
        switch self {
        case .top:    return .bottom
        case .bottom: return .top
        case .left:   return .right
        case .right:  return .left
        }
    }

    var rotatedCW: ConnectionSide {
        switch self {
        case .top:    return .right
        case .right:  return .bottom
        case .bottom: return .left
        case .left:   return .top
        }
    }
}

// MARK: - TileType

enum TileType: String, Codable {
    case end
    case straight
    case corner
    case tee
    case cross

    var canonicalConnections: Set<ConnectionSide> {
        switch self {
        case .end:      return [.top]
        case .straight: return [.top, .bottom]
        case .corner:   return [.top, .right]
        case .tee:      return [.top, .right, .bottom]
        case .cross:    return [.top, .right, .bottom, .left]
        }
    }
}

// MARK: - TileNode

final class TileNode: SKNode {

    // MARK: - Colour palette

    static let colorIdle      = UIColor(red: 0.42, green: 0.48, blue: 0.60, alpha: 1)
    static let colorConnected = UIColor(red: 0.20, green: 0.82, blue: 0.56, alpha: 1)
    static let colorBG        = UIColor(white: 0.13, alpha: 1)
    static let colorBGStroke  = UIColor(white: 0.28, alpha: 1)

    // MARK: - Properties

    let tileType: TileType
    let tileSize: CGFloat
    private(set) var rotationSteps: Int = 0
    private var isAnimating: Bool = false

    private var bgNode: SKShapeNode!
    private var highlightOverlay: SKShapeNode!
    private var pipeNodes: [SKNode] = []

    var isConnected: Bool = false {
        didSet {
            guard isConnected != oldValue else { return }
            animateConnectionChange()
        }
    }

    /// Pure computed property — NEVER store connections in a mutable var
    var activeConnections: Set<ConnectionSide> {
        tileType.canonicalConnections.reduce(into: Set<ConnectionSide>()) { result, side in
            var s = side
            for _ in 0..<(rotationSteps % 4) { s = s.rotatedCW }
            result.insert(s)
        }
    }

    // MARK: - Init

    init(type: TileType, size: CGFloat, initialRotation: Int) {
        self.tileType = type
        self.tileSize = size
        super.init()

        self.rotationSteps = initialRotation % 4
        self.isUserInteractionEnabled = true

        buildVisuals()

        // Apply initial rotation silently (no animation)
        self.zRotation = -CGFloat(rotationSteps) * .pi / 2
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Visual construction

    private func buildVisuals() {
        let pipeW = tileSize * 0.24
        let halfTile = tileSize / 2

        // Background tile
        bgNode = SKShapeNode(rectOf: CGSize(width: tileSize - 3, height: tileSize - 3), cornerRadius: 6)
        bgNode.fillColor = TileNode.colorBG
        bgNode.strokeColor = TileNode.colorBGStroke
        bgNode.lineWidth = 1.5
        bgNode.zPosition = 0
        addChild(bgNode)

        // Highlight overlay
        highlightOverlay = SKShapeNode(rectOf: CGSize(width: tileSize - 3, height: tileSize - 3), cornerRadius: 6)
        highlightOverlay.fillColor = UIColor.white.withAlphaComponent(0.15)
        highlightOverlay.strokeColor = .clear
        highlightOverlay.alpha = 0
        highlightOverlay.zPosition = 5
        addChild(highlightOverlay)

        // Hub circle at centre
        let hub = SKShapeNode(circleOfRadius: pipeW * 0.65)
        hub.fillColor = TileNode.colorIdle
        hub.strokeColor = .clear
        hub.zPosition = 2
        hub.name = "pipe"
        addChild(hub)
        pipeNodes.append(hub)

        // Arms for each canonical connection
        let armLen = halfTile
        for side in tileType.canonicalConnections {
            // Arm rectangle
            let arm = SKShapeNode(rectOf: CGSize(width: pipeW, height: armLen))
            arm.fillColor = TileNode.colorIdle
            arm.strokeColor = .clear
            arm.zPosition = 1
            arm.name = "pipe"

            // Cap circle at tip
            let cap = SKShapeNode(circleOfRadius: pipeW * 0.52)
            cap.fillColor = TileNode.colorIdle
            cap.strokeColor = .clear
            cap.zPosition = 2
            cap.name = "pipe"

            switch side {
            case .top:
                arm.position = CGPoint(x: 0, y: armLen / 2)
                cap.position = CGPoint(x: 0, y: armLen)
            case .bottom:
                arm.position = CGPoint(x: 0, y: -armLen / 2)
                cap.position = CGPoint(x: 0, y: -armLen)
            case .right:
                arm.position = CGPoint(x: armLen / 2, y: 0)
                arm.zRotation = .pi / 2
                cap.position = CGPoint(x: armLen, y: 0)
            case .left:
                arm.position = CGPoint(x: -armLen / 2, y: 0)
                arm.zRotation = .pi / 2
                cap.position = CGPoint(x: -armLen, y: 0)
            }

            addChild(arm)
            addChild(cap)
            pipeNodes.append(arm)
            pipeNodes.append(cap)
        }
    }

    // MARK: - Rotation

    func rotate(completion: (() -> Void)? = nil) {
        guard !isAnimating else { return }
        isAnimating = true
        rotationSteps = (rotationSteps + 1) % 4

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // 1. Rotate 90° CW (negative in SpriteKit)
        let rotAction = SKAction.rotate(byAngle: -.pi / 2, duration: 0.18)
        rotAction.timingMode = .easeInEaseOut

        // 2. Scale bounce on bgNode
        let bounceDown = SKAction.scale(to: 0.88, duration: 0.06)
        let bounceUp   = SKAction.scale(to: 1.04, duration: 0.06)
        let bounceBack = SKAction.scale(to: 1.0, duration: 0.06)
        let bounce = SKAction.sequence([bounceDown, bounceUp, bounceBack])

        // 3. White flash on highlight overlay
        let flashIn  = SKAction.fadeAlpha(to: 1.0, duration: 0.04)
        let flashOut = SKAction.fadeAlpha(to: 0.0, duration: 0.14)
        let flash = SKAction.sequence([flashIn, flashOut])

        // 4. Background pulse
        let pulseColor = SKAction.customAction(withDuration: 0.18) { [weak self] _, time in
            guard let self = self else { return }
            let progress = time / 0.18
            if progress < 0.5 {
                self.bgNode.fillColor = UIColor(white: 0.18, alpha: 1)
            } else {
                self.bgNode.fillColor = TileNode.colorBG
            }
        }

        // Run all together
        self.run(rotAction)
        bgNode.run(bounce)
        highlightOverlay.run(flash)
        bgNode.run(pulseColor)

        // Completion after rotation finishes
        self.run(SKAction.sequence([
            SKAction.wait(forDuration: 0.18),
            SKAction.run { [weak self] in
                self?.isAnimating = false
                completion?()
            }
        ]))
    }

    // MARK: - Connection animation

    private func animateConnectionChange() {
        let targetColor = isConnected ? TileNode.colorConnected : TileNode.colorIdle

        // Staggered colour sweep
        for (index, node) in pipeNodes.enumerated() {
            let delay = Double(index) * 0.015
            node.run(SKAction.sequence([
                SKAction.wait(forDuration: delay),
                SKAction.customAction(withDuration: 0.2) { node, _ in
                    if let shape = node as? SKShapeNode {
                        shape.fillColor = targetColor
                    }
                }
            ]))
        }

        // Glow ring on connection
        if isConnected {
            let glowSize = tileSize - 3
            let glow = SKShapeNode(rectOf: CGSize(width: glowSize, height: glowSize), cornerRadius: 6)
            glow.fillColor = .clear
            glow.strokeColor = TileNode.colorConnected.withAlphaComponent(0.6)
            glow.lineWidth = 2.5
            glow.zPosition = 4
            glow.setScale(1.0)
            glow.alpha = 0.8
            addChild(glow)

            let expand = SKAction.scale(to: 1.3, duration: 0.3)
            expand.timingMode = .easeOut
            let fadeOut = SKAction.fadeOut(withDuration: 0.3)
            glow.run(SKAction.group([expand, fadeOut])) {
                glow.removeFromParent()
            }
        }
    }
}
