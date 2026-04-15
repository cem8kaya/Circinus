import SpriteKit
import UIKit

// MARK: - UIColor+Lerp

extension UIColor {

    /// Linearly interpolate RGB components toward a target color.
    func lerp(to target: UIColor, t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        target.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let p = max(0, min(1, t))
        return UIColor(red:   r1 + (r2 - r1) * p,
                       green: g1 + (g2 - g1) * p,
                       blue:  b1 + (b2 - b1) * p,
                       alpha: a1 + (a2 - a1) * p)
    }
}

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

    // MARK: - Colour palette (refined premium palette)

    static let colorIdle      = UIColor(red: 0.38, green: 0.42, blue: 0.56, alpha: 1)
    static let colorConnected = UIColor(red: 0.16, green: 0.85, blue: 0.58, alpha: 1)
    static let colorBG        = UIColor(white: 0.11, alpha: 1)
    static let colorBGStroke  = UIColor(white: 0.22, alpha: 1)
    static let colorAccent    = UIColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1)
    static let colorGold      = UIColor(red: 1.0, green: 0.80, blue: 0.24, alpha: 1)

    // MARK: - Properties

    let tileType: TileType
    let tileSize: CGFloat
    private(set) var rotationSteps: Int = 0
    private var isAnimating: Bool = false

    private var bgNode: SKShapeNode!
    private var shadowNode: SKShapeNode!
    private var highlightOverlay: SKShapeNode!
    private var pipeNodes: [SKNode] = []
    private var glowNode: SKEffectNode?

    /// The rotation that solves the puzzle (from JSON).
    var solutionRotation: Int = 0

    var isLocked: Bool = false {
        didSet {
            updateAccessibilityInfo()
        }
    }

    var isConnected: Bool = false {
        didSet {
            guard isConnected != oldValue else { return }
            animateConnectionChange()
            updateAccessibilityInfo()
        }
    }

    /// Pure computed property — NEVER store connections in a mutable var
    var activeConnections: Set<ConnectionSide> {
        connectionsAt(rotation: rotationSteps)
    }

    /// Connections for an arbitrary rotation value.
    func connectionsAt(rotation: Int) -> Set<ConnectionSide> {
        tileType.canonicalConnections.reduce(into: Set<ConnectionSide>()) { result, side in
            var s = side
            for _ in 0..<(rotation % 4) { s = s.rotatedCW }
            result.insert(s)
        }
    }

    /// Whether the tile is at a rotation that produces the same connections as the solution.
    var isCorrectlyRotated: Bool {
        activeConnections == connectionsAt(rotation: solutionRotation)
    }

    // MARK: - Init

    init(type: TileType, size: CGFloat, initialRotation: Int) {
        self.tileType = type
        self.tileSize = size
        super.init()

        self.rotationSteps = initialRotation % 4
        self.isUserInteractionEnabled = false
        self.isLocked = false

        buildVisuals()

        // Apply initial rotation silently (no animation)
        self.zRotation = -CGFloat(rotationSteps) * .pi / 2

        updateAccessibilityInfo()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Visual construction

    private func buildVisuals() {
        let pipeW = tileSize * 0.22
        let halfTile = tileSize / 2
        let cornerR: CGFloat = 10

        // Drop shadow
        shadowNode = SKShapeNode(rectOf: CGSize(width: tileSize - 3, height: tileSize - 3), cornerRadius: cornerR)
        shadowNode.fillColor = UIColor(white: 0.0, alpha: 0.35)
        shadowNode.strokeColor = .clear
        shadowNode.zPosition = -1
        shadowNode.position = CGPoint(x: 2, y: -2)
        addChild(shadowNode)

        // Background tile
        bgNode = SKShapeNode(rectOf: CGSize(width: tileSize - 3, height: tileSize - 3), cornerRadius: cornerR)
        bgNode.fillColor = TileNode.colorBG
        bgNode.strokeColor = TileNode.colorBGStroke
        bgNode.lineWidth = 1.0
        bgNode.zPosition = 0
        addChild(bgNode)

        // Inner subtle gradient border (top highlight for depth)
        let innerHL = SKShapeNode(rectOf: CGSize(width: tileSize - 7, height: tileSize - 7), cornerRadius: cornerR - 2)
        innerHL.fillColor = .clear
        innerHL.strokeColor = UIColor(white: 1.0, alpha: 0.04)
        innerHL.lineWidth = 1.0
        innerHL.zPosition = 0.5
        addChild(innerHL)

        // Highlight overlay
        highlightOverlay = SKShapeNode(rectOf: CGSize(width: tileSize - 3, height: tileSize - 3), cornerRadius: cornerR)
        highlightOverlay.fillColor = UIColor.white.withAlphaComponent(0.18)
        highlightOverlay.strokeColor = .clear
        highlightOverlay.alpha = 0
        highlightOverlay.zPosition = 5
        addChild(highlightOverlay)

        // Hub circle at centre (slightly larger for premium feel)
        let hub = SKShapeNode(circleOfRadius: pipeW * 0.72)
        hub.fillColor = TileNode.colorIdle
        hub.strokeColor = .clear
        hub.zPosition = 2
        hub.name = "pipe"
        addChild(hub)
        pipeNodes.append(hub)

        // Arms for each canonical connection
        let armLen = halfTile
        for side in tileType.canonicalConnections {
            // Arm rectangle with rounded ends
            let arm = SKShapeNode(rectOf: CGSize(width: pipeW, height: armLen), cornerRadius: pipeW * 0.15)
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

        // Sound
        SoundManager.shared.playRotate()

        // 1. Rotate 90° CW (negative in SpriteKit)
        let rotAction = SKAction.rotate(byAngle: -.pi / 2, duration: 0.16)
        rotAction.timingMode = .easeInEaseOut

        // 2. Scale bounce on bgNode (snappy premium feel)
        let bounceDown = SKAction.scale(to: 0.90, duration: 0.05)
        let bounceUp   = SKAction.scale(to: 1.05, duration: 0.07)
        let bounceBack = SKAction.scale(to: 1.0, duration: 0.06)
        let bounce = SKAction.sequence([bounceDown, bounceUp, bounceBack])

        // 3. White flash on highlight overlay
        let flashIn  = SKAction.fadeAlpha(to: 0.8, duration: 0.03)
        let flashOut = SKAction.fadeAlpha(to: 0.0, duration: 0.13)
        let flash = SKAction.sequence([flashIn, flashOut])

        // 4. Background pulse with smooth lerp
        let bgBase = TileNode.colorBG
        let bgBright = UIColor(white: 0.16, alpha: 1)
        let pulseColor = SKAction.customAction(withDuration: 0.16) { [weak self] _, time in
            guard let self = self else { return }
            let progress = time / 0.16
            if progress < 0.5 {
                self.bgNode.fillColor = bgBase.lerp(to: bgBright, t: progress * 2)
            } else {
                self.bgNode.fillColor = bgBright.lerp(to: bgBase, t: (progress - 0.5) * 2)
            }
        }

        // 5. Shadow squish during rotation
        let shadowSquish = SKAction.sequence([
            SKAction.moveTo(y: -1, duration: 0.05),
            SKAction.moveTo(y: -2, duration: 0.11)
        ])

        // Run all together
        self.run(rotAction)
        bgNode.run(bounce)
        highlightOverlay.run(flash)
        bgNode.run(pulseColor)
        shadowNode.run(shadowSquish)

        // Completion after rotation finishes
        self.run(SKAction.sequence([
            SKAction.wait(forDuration: 0.16),
            SKAction.run { [weak self] in
                self?.isAnimating = false
                self?.updateAccessibilityInfo()
                completion?()
            }
        ]))
    }

    /// Set rotation directly without animation (for undo)
    func setRotation(_ steps: Int) {
        rotationSteps = steps % 4
        self.zRotation = -CGFloat(rotationSteps) * .pi / 2
        updateAccessibilityInfo()
    }

    // MARK: - Press state feedback

    func applyPressState() {
        bgNode.run(SKAction.scale(to: 0.94, duration: 0.06), withKey: "press")
        shadowNode.run(SKAction.group([
            SKAction.moveTo(x: 1, duration: 0.06),
            SKAction.moveTo(y: -1, duration: 0.06)
        ]), withKey: "pressShadow")
        highlightOverlay.run(SKAction.fadeAlpha(to: 0.12, duration: 0.06), withKey: "pressHL")
    }

    func releasePressState() {
        bgNode.run(SKAction.scale(to: 1.0, duration: 0.06), withKey: "press")
        shadowNode.run(SKAction.group([
            SKAction.moveTo(x: 2, duration: 0.06),
            SKAction.moveTo(y: -2, duration: 0.06)
        ]), withKey: "pressShadow")
        highlightOverlay.run(SKAction.fadeAlpha(to: 0.0, duration: 0.06), withKey: "pressHL")
    }

    // MARK: - Hint pulse

    func showHintPulse() {
        let border = SKShapeNode(rectOf: CGSize(width: tileSize - 1, height: tileSize - 1), cornerRadius: 10)
        border.fillColor = .clear
        border.strokeColor = TileNode.colorAccent
        border.lineWidth = 3.0
        border.zPosition = 6
        border.alpha = 0
        addChild(border)

        let pulse = SKAction.sequence([
            SKAction.fadeAlpha(to: 1.0, duration: 0.15),
            SKAction.fadeAlpha(to: 0.2, duration: 0.25),
            SKAction.fadeAlpha(to: 1.0, duration: 0.15),
            SKAction.fadeAlpha(to: 0.2, duration: 0.25),
            SKAction.fadeAlpha(to: 1.0, duration: 0.15),
            SKAction.fadeOut(withDuration: 0.3)
        ])
        border.run(pulse) {
            border.removeFromParent()
        }
    }

    // MARK: - Connection animation

    private func animateConnectionChange() {
        let fromColor = isConnected ? TileNode.colorIdle : TileNode.colorConnected
        let targetColor = isConnected ? TileNode.colorConnected : TileNode.colorIdle
        let dur: TimeInterval = 0.22

        // Staggered colour sweep with smooth RGB lerp
        for (index, node) in pipeNodes.enumerated() {
            let delay = Double(index) * 0.02
            node.run(SKAction.sequence([
                SKAction.wait(forDuration: delay),
                SKAction.customAction(withDuration: dur) { node, elapsed in
                    if let shape = node as? SKShapeNode {
                        let t = CGFloat(elapsed / dur)
                        shape.fillColor = fromColor.lerp(to: targetColor, t: t)
                    }
                }
            ]))
        }

        // Glow ring on connection
        if isConnected {
            SoundManager.shared.playConnect()

            let glowSize = tileSize - 3
            let glow = SKShapeNode(rectOf: CGSize(width: glowSize, height: glowSize), cornerRadius: 10)
            glow.fillColor = .clear
            glow.strokeColor = TileNode.colorConnected.withAlphaComponent(0.5)
            glow.lineWidth = 3.0
            glow.zPosition = 4
            glow.setScale(1.0)
            glow.alpha = 0.9
            addChild(glow)

            let expand = SKAction.scale(to: 1.35, duration: 0.35)
            expand.timingMode = .easeOut
            let fadeOut = SKAction.fadeOut(withDuration: 0.35)
            glow.run(SKAction.group([expand, fadeOut])) {
                glow.removeFromParent()
            }

            // Tile bg stroke glow with smooth lerp
            let strokeFrom = TileNode.colorConnected.withAlphaComponent(0.6)
            let strokeTo = TileNode.colorBGStroke
            let strokeAnim = SKAction.customAction(withDuration: 0.4) { [weak self] _, elapsed in
                guard let self = self else { return }
                let t = CGFloat(elapsed / 0.4)
                self.bgNode.strokeColor = strokeFrom.lerp(to: strokeTo, t: t)
            }
            bgNode.run(strokeAnim)
        } else {
            bgNode.strokeColor = TileNode.colorBGStroke
        }
    }

    // MARK: - Accessibility

    private func updateAccessibilityInfo() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        let connState = isConnected ? "connected" : "not connected"
        accessibilityLabel = "\(tileType.rawValue) tile, rotation \(rotationSteps) of 4, \(connState)"
        accessibilityHint = !isLocked ? "Double tap to rotate" : "Locked tile"
    }

    // MARK: - Node recycling

    /// Reset tile state for reuse without rebuilding the node tree.
    func resetForRecycling(rotation: Int, solutionRotation sol: Int) {
        solutionRotation = sol
        isConnected = false
        isAnimating = false
        rotationSteps = rotation % 4
        zRotation = -CGFloat(rotationSteps) * .pi / 2
        alpha = 1
        setScale(1)
        isLocked = false

        for node in pipeNodes {
            if let shape = node as? SKShapeNode {
                shape.fillColor = TileNode.colorIdle
            }
        }
        bgNode.fillColor = TileNode.colorBG
        bgNode.strokeColor = TileNode.colorBGStroke
        bgNode.setScale(1.0)
        shadowNode.position = CGPoint(x: 2, y: -2)
        highlightOverlay.alpha = 0

        updateAccessibilityInfo()
    }
}
