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
    case empty

    var canonicalConnections: Set<ConnectionSide> {
        switch self {
        case .end:      return [.top]
        case .straight: return [.top, .bottom]
        case .corner:   return [.top, .right]
        case .tee:      return [.top, .right, .bottom]
        case .cross:    return [.top, .right, .bottom, .left]
        case .empty:    return []
        }
    }
}

// MARK: - EnergyColor
//
// Directional energy is tagged with a colour. `.none` represents either an
// un-energised pipe (before the solver has propagated flow into it) or a
// structural-only tile that can carry any colour transparently.
//
// Mixing follows simple subtractive-style rules: red ⊕ blue = purple.
// Purple is an absorbing state — once a path is saturated, it stays purple.

enum EnergyColor: String, Codable {
    case none
    case red
    case blue
    case purple

    /// Combine two flows meeting at a node (a Mixer, or an accidental
    /// collision at a non-mixer tile — the latter will be flagged as a
    /// short-circuit by the solver).
    static func mix(_ a: EnergyColor, _ b: EnergyColor) -> EnergyColor {
        switch (a, b) {
        case (.none, let x), (let x, .none):   return x
        case let (x, y) where x == y:          return x
        case (.red, .blue), (.blue, .red):     return .purple
        default:                               return .purple  // saturated
        }
    }

    /// Design note: these hues are intentionally high-saturation so colour-
    /// blind players can still distinguish purple from red/blue by value.
    var uiColor: UIColor {
        switch self {
        case .none:   return TileNode.colorIdle
        case .red:    return UIColor(red: 0.95, green: 0.28, blue: 0.35, alpha: 1)
        case .blue:   return UIColor(red: 0.30, green: 0.58, blue: 1.00, alpha: 1)
        case .purple: return UIColor(red: 0.74, green: 0.32, blue: 0.92, alpha: 1)
        }
    }
}

// MARK: - TileRole
//
// Role is orthogonal to geometry (TileType). Any geometry can be fragile,
// any geometry can be quantum-linked, etc. The four new mechanics plug in
// here so level authors can compose them freely.

enum TileRole: Equatable {
    /// Plain connective tile — the legacy behaviour.
    case normal

    /// Emits `color` energy out of `side` (canonical, i.e. at rotation 0).
    /// Sources are typically authored as locked `.end` tiles.
    case source(side: ConnectionSide, color: EnergyColor)

    /// Consumes energy and requires `required` colour to arrive at `side`.
    /// Sinks are the win-condition terminals (replaces "single closed loop"
    /// as the goal when any sources are present).
    case sink(side: ConnectionSide, required: EnergyColor)

    /// A 4-way junction that combines all inbound coloured flows and re-
    /// emits their mix on every other face. Geometrically must be `.cross`.
    case mixer

    /// Breaks (becomes non-conducting + visually shattered) after being
    /// rotated more than `limit` times. Forces pre-planning over spinning.
    case fragile(limit: Int)

    /// §5 Diode: conducts energy in one direction only.
    /// Canonical in-face = .bottom, out-face = .top (flows upward at rotation
    /// 0). After N CW rotations both faces rotate accordingly. Topology sees
    /// both faces normally (so neighbours aren't flagged leaky); the solver's
    /// flow pass enforces the one-way constraint.
    ///
    /// Decision forced: the player must orient the diode so current flows
    /// *through* it — a topologically valid but backwards diode leaves the
    /// downstream sink dark. The always-visible arrow overlay makes the
    /// direction unambiguous even before the player taps.
    case diode

    var isMixer: Bool  { if case .mixer  = self { return true } else { return false } }
    var isSource: Bool { if case .source = self { return true } else { return false } }
    var isSink: Bool   { if case .sink   = self { return true } else { return false } }
    var isDiode: Bool  { if case .diode  = self { return true } else { return false } }
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

    // MARK: New mechanic state (design doc §1–§4)

    /// Role determines directional / colour / fragility behaviour.
    /// Defaults to `.normal` so legacy levels keep working unchanged.
    var role: TileRole = .normal {
        didSet { updateRoleVisuals() }
    }

    /// Opaque tag. Any two tiles sharing a non-nil quantumGroup rotate
    /// together (mechanic §3). Set via level JSON, resolved by GameScene.
    var quantumGroup: String? = nil

    /// Monotonic count of player-initiated rotations this level.
    /// Consulted by the fragile-tile mechanic (§4) and displayed as a
    /// "cracks" meter on fragile tiles.
    private(set) var rotationCount: Int = 0

    /// A broken tile is non-conducting: the solver treats it as if it had
    /// no active connections. Visually shown with a cracked overlay.
    var isBroken: Bool = false {
        didSet {
            guard isBroken != oldValue else { return }
            if isBroken { animateBreak() }
            updateAccessibilityInfo()
        }
    }

    /// Colour currently flowing through this tile, assigned by the solver
    /// on each evaluation pass. Drives pipe tint so the player can read
    /// the live circuit state at a glance.
    var currentEnergy: EnergyColor = .none {
        didSet {
            guard currentEnergy != oldValue else { return }
            applyEnergyTint(animated: true)
        }
    }

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

    // MARK: Derived mechanic queries

    /// Rotation budget remaining before this fragile tile shatters.
    /// `nil` means the tile is not fragile.
    var rotationsRemaining: Int? {
        if case .fragile(let limit) = role {
            return max(0, limit - rotationCount)
        }
        return nil
    }

    /// §5 Diode: in/out faces in world-space for the current rotationSteps.
    /// Canonical: inFace = .bottom, outFace = .top (flows "upward" at rot 0).
    /// Only meaningful when role == .diode; safe to call on any tile.
    var diodeFaces: (inFace: ConnectionSide, outFace: ConnectionSide) {
        var inf:  ConnectionSide = .bottom
        var outf: ConnectionSide = .top
        for _ in 0..<(rotationSteps % 4) {
            inf  = inf.rotatedCW
            outf = outf.rotatedCW
        }
        return (inFace: inf, outFace: outf)
    }

    /// Connections this tile actually participates in after accounting for
    /// its role. Broken tiles conduct nothing; sources/sinks only expose
    /// their single declared face. This is what the solver must consult,
    /// not the raw `activeConnections`.
    var effectiveConnections: Set<ConnectionSide> {
        if isBroken { return [] }
        switch role {
        case .source(let side, _), .sink(let side, _):
            // Apply current rotation to the canonical side.
            var s = side
            for _ in 0..<(rotationSteps % 4) { s = s.rotatedCW }
            return [s]
        case .normal, .mixer, .fragile, .diode:
            // §5 Diode: exposes both geometric faces for topology so neither
            // neighbour is flagged leaky. Directionality is a flow property
            // enforced by PuzzleSolver Pass 2, not a topology property.
            return activeConnections
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

        if tileType == .empty {
            // Invisible node to hold space but draw nothing.
            // Still needed to populate `bgNode` for fallback refs although alpha is zero
            bgNode = SKShapeNode(rectOf: CGSize(width: tileSize - 3, height: tileSize - 3), cornerRadius: cornerR)
            bgNode.alpha = 0
            addChild(bgNode)

            // Needs highlightOverlay and shadowNode internally for press states
            highlightOverlay = SKShapeNode(rectOf: CGSize(width: tileSize - 3, height: tileSize - 3), cornerRadius: cornerR)
            highlightOverlay.alpha = 0
            addChild(highlightOverlay)

            shadowNode = SKShapeNode(rectOf: CGSize(width: tileSize - 3, height: tileSize - 3), cornerRadius: cornerR)
            shadowNode.alpha = 0
            addChild(shadowNode)
            return
        }

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
        // Broken / locked tiles are rotation-inert.
        guard !isBroken, !isLocked else { completion?(); return }

        // §4 Overload: fragile tiles refuse rotations past their limit —
        // the *attempted* rotation is what shatters them. Design choice:
        // we let the attempt happen and then break on the way out, so the
        // player sees the move they just made was the fatal one.
        isAnimating = true
        rotationSteps = (rotationSteps + 1) % 4
        rotationCount += 1

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
                guard let self = self else { return }
                self.isAnimating = false

                // §4 Overload evaluation: if we have blown the budget,
                // break the tile now. Setting isBroken triggers the
                // shatter animation via didSet.
                if case .fragile(let limit) = self.role, self.rotationCount > limit {
                    self.isBroken = true
                }

                self.updateAccessibilityInfo()
                completion?()
            }
        ]))
    }

    // MARK: - New mechanic visuals & helpers

    /// Tint every pipe segment to reflect the current energy colour.
    /// Called by the didSet on `currentEnergy` whenever the solver
    /// re-evaluates the board.
    private func applyEnergyTint(animated: Bool) {
        guard !isBroken else { return }
        let target = currentEnergy == .none
            ? (isConnected ? TileNode.colorConnected : TileNode.colorIdle)
            : currentEnergy.uiColor

        for node in pipeNodes {
            guard let shape = node as? SKShapeNode else { continue }
            if animated {
                let from = shape.fillColor
                shape.run(SKAction.customAction(withDuration: 0.22) { n, elapsed in
                    guard let s = n as? SKShapeNode else { return }
                    s.fillColor = from.lerp(to: target, t: CGFloat(elapsed / 0.22))
                })
            } else {
                shape.fillColor = target
            }
        }
    }

    /// §5 Diode: refresh role-specific overlays after a role assignment.
    /// Called by the `role.didSet` observer. Safe to call multiple times —
    /// always removes the previous overlay before re-adding.
    private func updateRoleVisuals() {
        // Always clear the previous diode arrow so a recycled tile doesn't
        // carry stale visuals when its role is reset to .normal.
        childNode(withName: "diodeArrow")?.removeFromParent()

        if role.isDiode {
            addChild(buildDiodeArrow())
        }
    }

    /// §5 Diode: a semi-transparent arrowhead drawn in *local* space pointing
    /// from canonical in-face (.bottom) toward out-face (.top). Because the
    /// tile rotates as a whole via `zRotation`, this single upward arrow
    /// always displays the live flow direction without needing updates on
    /// each rotation. The arrow is always visible (not just when energised)
    /// so the player can read the diode direction on a dark/unconnected tile.
    private func buildDiodeArrow() -> SKNode {
        let container = SKNode()
        container.name = "diodeArrow"
        container.zPosition = 3     // above pipe arms (z 1–2), below highlight (z 5)

        let sz = tileSize
        // Proportional sizing: comfortably readable at the smallest tile size
        // used in levels.json (50pt) and not oversized at 95pt.
        let headH:  CGFloat = sz * 0.22
        let headW:  CGFloat = sz * 0.16
        let stemH:  CGFloat = sz * 0.10
        let stemW:  CGFloat = sz * 0.06
        // Shift the whole arrow up slightly so the stem base clears the hub.
        let offsetY: CGFloat = sz * 0.04

        // Arrowhead triangle: apex up, base below.
        let headPath = CGMutablePath()
        headPath.move(to:     CGPoint(x: 0,          y: offsetY + stemH + headH))
        headPath.addLine(to:  CGPoint(x: -headW / 2, y: offsetY + stemH))
        headPath.addLine(to:  CGPoint(x:  headW / 2, y: offsetY + stemH))
        headPath.closeSubpath()

        let head = SKShapeNode(path: headPath)
        head.fillColor   = UIColor(white: 1.0, alpha: 0.72)
        head.strokeColor = .clear
        container.addChild(head)

        // Stem below the arrowhead.
        let stem = SKShapeNode(rectOf: CGSize(width: stemW, height: stemH),
                               cornerRadius: stemW * 0.3)
        stem.fillColor   = UIColor(white: 1.0, alpha: 0.72)
        stem.strokeColor = .clear
        stem.position    = CGPoint(x: 0, y: offsetY + stemH / 2)
        container.addChild(stem)

        return container
    }

    /// Shatter feedback for fragile tiles that exceeded their rotation
    /// budget. Pipes dim, a crack overlay appears, haptic thumps, and the
    /// tile stops accepting input (guarded by `isBroken` in `rotate`).
    private func animateBreak() {
        SoundManager.shared.playRotate()  // reuse until a dedicated SFX ships
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        heavy.impactOccurred()

        // Dim pipes to a muted grey.
        let dead = UIColor(white: 0.28, alpha: 1)
        for node in pipeNodes {
            if let shape = node as? SKShapeNode {
                shape.run(SKAction.customAction(withDuration: 0.25) { n, t in
                    guard let s = n as? SKShapeNode else { return }
                    s.fillColor = (s.fillColor).lerp(to: dead, t: CGFloat(t / 0.25))
                })
            }
        }

        // Crack overlay — simple two-stroke X that reads well at small sizes.
        let crack = SKShapeNode()
        let path = CGMutablePath()
        let h = tileSize * 0.4
        path.move(to: CGPoint(x: -h, y: -h * 0.4))
        path.addLine(to: CGPoint(x: h * 0.2, y: h * 0.1))
        path.addLine(to: CGPoint(x: -h * 0.1, y: h * 0.4))
        path.move(to: CGPoint(x: h * 0.4, y: -h))
        path.addLine(to: CGPoint(x: -h * 0.1, y: -h * 0.1))
        path.addLine(to: CGPoint(x: h * 0.3, y: h * 0.3))
        crack.path = path
        crack.strokeColor = UIColor(white: 0.92, alpha: 0.9)
        crack.lineWidth = 2.2
        crack.zPosition = 6
        crack.alpha = 0
        crack.name = "crackOverlay"
        addChild(crack)
        crack.run(SKAction.fadeAlpha(to: 0.85, duration: 0.18))

        // One-shot jolt.
        run(SKAction.sequence([
            SKAction.rotate(byAngle: 0.08, duration: 0.04),
            SKAction.rotate(byAngle: -0.16, duration: 0.06),
            SKAction.rotate(byAngle: 0.08, duration: 0.04)
        ]))
    }

    /// §3 Quantum link: rotate every tile in `group` as a single atomic
    /// action. Called by GameScene when the player taps any member of the
    /// group. Exposed as a static utility so the scene doesn't need to
    /// know how individual TileNodes animate.
    static func rotateQuantumGroup(_ group: [TileNode], completion: (() -> Void)? = nil) {
        guard !group.isEmpty else { completion?(); return }
        // Gate on the "slowest" member so callers get one completion.
        var remaining = group.count
        for t in group {
            t.rotate {
                remaining -= 1
                if remaining == 0 { completion?() }
            }
        }
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

        // Reset new mechanic state (§1–§5).
        // Note: setting role = .normal triggers updateRoleVisuals() via didSet,
        // which removes the diode arrow. crackOverlay is separate (added by
        // animateBreak, not role-driven) so it needs its own explicit removal.
        role = .normal
        quantumGroup = nil
        rotationCount = 0
        isBroken = false
        currentEnergy = .none
        childNode(withName: "crackOverlay")?.removeFromParent()

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
