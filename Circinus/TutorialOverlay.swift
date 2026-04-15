import SpriteKit
import UIKit

// MARK: - TutorialOverlay

/// Premium step-by-step tutorial overlay shown when a player opens Level 1 for the first time.
/// Persists dismissal state in UserDefaults ("tutorialCompleted").
final class TutorialOverlay: SKNode {

    // MARK: - Public

    var onDismiss: (() -> Void)?

    // MARK: - Private

    private let sceneSize: CGSize
    private var currentStep: Int = 0
    private var cardNode: SKNode?
    private var progressDots: [SKShapeNode] = []

    private struct Step {
        let icon: String
        let title: String
        let body: String
    }

    private let steps: [Step] = [
        Step(icon: "⚡",
             title: "Welcome to Circinus",
             body: "Rotate pipe tiles to connect them all into one complete, closed circuit."),
        Step(icon: "↻",
             title: "Tap to Rotate",
             body: "Tap any tile to rotate it 90°. Keep tapping until every pipe connects to its neighbour."),
        Step(icon: "🔗",
             title: "Close the Circuit",
             body: "Every pipe must link up with no open ends and no orphaned segments."),
        Step(icon: "💡",
             title: "Use Hints Wisely",
             body: "Stuck? Tap the 💡 button. A spotlight highlights a misaligned tile — but it costs +2 moves."),
        Step(icon: "★",
             title: "Earn 3 Stars",
             body: "Solve in par moves or fewer to earn 3 stars. Less is more — good luck!")
    ]

    // MARK: - Init

    init(sceneSize: CGSize) {
        self.sceneSize = sceneSize
        super.init()
        zPosition = 200
        isUserInteractionEnabled = false

        // Full-screen dim background
        let dim = SKShapeNode(rectOf: CGSize(width: sceneSize.width + 200,
                                             height: sceneSize.height + 200))
        dim.fillColor = UIColor(white: 0.0, alpha: 0.80)
        dim.strokeColor = .clear
        dim.position = CGPoint(x: sceneSize.width / 2, y: sceneSize.height / 2)
        dim.zPosition = 0
        addChild(dim)

        showStep(0, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Step management

    private func showStep(_ index: Int, animated: Bool) {
        currentStep = index

        // Slide-out old card
        if animated, let old = cardNode {
            old.run(SKAction.sequence([
                SKAction.group([
                    SKAction.fadeOut(withDuration: 0.14),
                    SKAction.moveBy(x: -24, y: 0, duration: 0.14)
                ]),
                SKAction.removeFromParent()
            ]))
        } else {
            cardNode?.removeFromParent()
        }

        let isLandscape = sceneSize.width > sceneSize.height
        let cardCenterY = sceneSize.height * (isLandscape ? 0.50 : 0.48)

        let card = buildCard(index: index)
        if animated {
            card.position = CGPoint(x: sceneSize.width / 2 + 24, y: cardCenterY)
            card.alpha = 0
            card.run(SKAction.group([
                SKAction.fadeIn(withDuration: 0.18),
                SKAction.moveTo(x: sceneSize.width / 2, duration: 0.18)
            ]))
        } else {
            card.position = CGPoint(x: sceneSize.width / 2, y: cardCenterY)
        }

        addChild(card)
        cardNode = card

        updateProgressDots(index)
    }

    // MARK: - Card builder

    private func buildCard(index: Int) -> SKNode {
        let step = steps[index]
        let isLast = index == steps.count - 1
        let isLandscape = sceneSize.width > sceneSize.height

        let cardW: CGFloat = isLandscape ? min(sceneSize.width * 0.52, 360) : min(sceneSize.width - 48, 340)
        let cardH: CGFloat = isLandscape ? 210 : 268

        let card = SKNode()

        // Card background (dark glass)
        let bg = SKShapeNode(rectOf: CGSize(width: cardW, height: cardH), cornerRadius: 24)
        bg.fillColor = UIColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 0.97)
        bg.strokeColor = TileNode.colorConnected.withAlphaComponent(0.40)
        bg.lineWidth = 1.5
        bg.zPosition = 1
        card.addChild(bg)

        // Subtle inner highlight border
        let innerBorder = SKShapeNode(rectOf: CGSize(width: cardW - 6, height: cardH - 6), cornerRadius: 22)
        innerBorder.fillColor = .clear
        innerBorder.strokeColor = UIColor(white: 1.0, alpha: 0.05)
        innerBorder.lineWidth = 1
        innerBorder.zPosition = 1
        card.addChild(innerBorder)

        // Step counter pill
        let stepLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        stepLabel.text = "\(index + 1) / \(steps.count)"
        stepLabel.fontSize = 10
        stepLabel.fontColor = TileNode.colorConnected.withAlphaComponent(0.65)
        stepLabel.position = CGPoint(x: 0, y: cardH / 2 - 20)
        stepLabel.verticalAlignmentMode = .center
        stepLabel.horizontalAlignmentMode = .center
        stepLabel.zPosition = 2
        card.addChild(stepLabel)

        // Icon
        let iconFontSize: CGFloat = isLandscape ? 32 : 42
        let iconY: CGFloat = isLandscape ? cardH / 2 - 56 : cardH / 2 - 72
        let iconLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        iconLabel.text = step.icon
        iconLabel.fontSize = iconFontSize
        iconLabel.position = CGPoint(x: 0, y: iconY)
        iconLabel.verticalAlignmentMode = .center
        iconLabel.horizontalAlignmentMode = .center
        iconLabel.zPosition = 2
        card.addChild(iconLabel)

        // Gentle bounce animation on icon
        let bounce = SKAction.repeatForever(SKAction.sequence([
            SKAction.scale(to: 1.10, duration: 0.55),
            SKAction.scale(to: 0.94, duration: 0.55)
        ]))
        iconLabel.run(bounce)

        // Title
        let titleFontSize: CGFloat = isLandscape ? 17 : 20
        let titleY: CGFloat = isLandscape ? cardH / 2 - 96 : cardH / 2 - 122
        let titleLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        titleLabel.text = step.title
        titleLabel.fontSize = titleFontSize
        titleLabel.fontColor = .white
        titleLabel.position = CGPoint(x: 0, y: titleY)
        titleLabel.verticalAlignmentMode = .center
        titleLabel.horizontalAlignmentMode = .center
        titleLabel.zPosition = 2
        card.addChild(titleLabel)

        // Body text (word-wrapped into lines)
        let approxChars = Int((cardW - 52) / 7.4)
        let lines = wordWrap(step.body, maxChars: approxChars)
        let bodyStartY: CGFloat = isLandscape ? cardH / 2 - 126 : cardH / 2 - 154
        for (i, line) in lines.enumerated() {
            let lineLabel = SKLabelNode(fontNamed: "AvenirNext-Regular")
            lineLabel.text = line
            lineLabel.fontSize = 13
            lineLabel.fontColor = UIColor(white: 0.72, alpha: 1)
            lineLabel.position = CGPoint(x: 0, y: bodyStartY - CGFloat(i) * 18)
            lineLabel.verticalAlignmentMode = .center
            lineLabel.horizontalAlignmentMode = .center
            lineLabel.zPosition = 2
            card.addChild(lineLabel)
        }

        // CTA button
        let btnY: CGFloat = -(cardH / 2 - 34)
        let btnText = isLast ? "Let's Play!" : "Next  →"
        let btnColor: UIColor = isLast
            ? TileNode.colorConnected
            : UIColor(white: 0.22, alpha: 1)
        let btnTextColor: UIColor = isLast
            ? UIColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1)
            : UIColor(white: 0.85, alpha: 1)

        let ctaBtn = makeButton(text: btnText, width: 156, height: 40,
                                color: btnColor, textColor: btnTextColor,
                                name: "tutNext")
        ctaBtn.position = CGPoint(x: isLast ? 0 : 28, y: btnY)
        ctaBtn.zPosition = 3
        card.addChild(ctaBtn)

        // Pulsing scale on the final "Let's Play!" button
        if isLast {
            let p1 = SKAction.scale(to: 1.04, duration: 0.72)
            p1.timingMode = .easeInEaseOut
            let p2 = SKAction.scale(to: 0.97, duration: 0.72)
            p2.timingMode = .easeInEaseOut
            ctaBtn.run(SKAction.repeatForever(SKAction.sequence([p1, p2])))
        }

        // Skip button (all steps except the last)
        if !isLast {
            let skipLabel = SKLabelNode(fontNamed: "AvenirNext-Regular")
            skipLabel.text = "Skip"
            skipLabel.fontSize = 12
            skipLabel.fontColor = UIColor(white: 0.34, alpha: 1)
            skipLabel.position = CGPoint(x: -62, y: btnY)
            skipLabel.verticalAlignmentMode = .center
            skipLabel.horizontalAlignmentMode = .center
            skipLabel.name = "tutSkip"
            skipLabel.zPosition = 3
            card.addChild(skipLabel)

            // Underline on skip
            let underline = SKShapeNode(rectOf: CGSize(width: 28, height: 0.6))
            underline.fillColor = UIColor(white: 0.34, alpha: 0.8)
            underline.strokeColor = .clear
            underline.position = CGPoint(x: -62, y: btnY - 8)
            underline.zPosition = 3
            card.addChild(underline)
        }

        return card
    }

    // MARK: - Button factory

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
        label.fontSize = 15
        label.fontColor = textColor
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.name = name
        node.addChild(label)

        return node
    }

    // MARK: - Progress dots

    private func updateProgressDots(_ active: Int) {
        progressDots.forEach { $0.removeFromParent() }
        progressDots = []

        let isLandscape = sceneSize.width > sceneSize.height
        let cardH: CGFloat = isLandscape ? 210 : 268
        let cardCenterY = sceneSize.height * (isLandscape ? 0.50 : 0.48)
        let dotsY = cardCenterY - cardH / 2 - 18

        let spacing: CGFloat = 14
        let total = CGFloat(steps.count - 1) * spacing
        let startX = sceneSize.width / 2 - total / 2

        for i in 0..<steps.count {
            let radius: CGFloat = i == active ? 5 : 3
            let dot = SKShapeNode(circleOfRadius: radius)
            dot.fillColor = i == active ? TileNode.colorConnected : UIColor(white: 0.28, alpha: 1)
            dot.strokeColor = .clear
            dot.position = CGPoint(x: startX + CGFloat(i) * spacing, y: dotsY)
            dot.zPosition = 201
            addChild(dot)
            progressDots.append(dot)
        }
    }

    // MARK: - Touch handling

    /// Call this from the scene's touchesBegan. Returns true to consume the event.
    func handleTap(at location: CGPoint, in scene: SKScene) -> Bool {
        let hitNames = Set(scene.nodes(at: location).compactMap { $0.name })

        if hitNames.contains("tutNext") {
            SoundManager.shared.playButtonTap()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let next = currentStep + 1
            if next >= steps.count {
                dismiss()
            } else {
                showStep(next, animated: true)
            }
            return true
        }

        if hitNames.contains("tutSkip") {
            SoundManager.shared.playButtonTap()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dismiss()
            return true
        }

        // Consume all touches while the tutorial is visible
        return true
    }

    // MARK: - Dismiss

    func dismiss() {
        UserDefaults.standard.set(true, forKey: "tutorialCompleted")
        run(SKAction.sequence([
            SKAction.group([
                SKAction.fadeOut(withDuration: 0.28),
                SKAction.scale(to: 0.96, duration: 0.28)
            ]),
            SKAction.removeFromParent()
        ])) { [weak self] in
            self?.onDismiss?()
        }
    }

    // MARK: - Helpers

    private func wordWrap(_ text: String, maxChars: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= maxChars {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
