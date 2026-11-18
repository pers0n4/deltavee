import AppKit
import DeltaveeCore

@MainActor
enum MenuBarTitle {
  static let menuIconSize: CGFloat = 14
  static let panelIconSize: CGFloat = 16
  private final class ResourceAnchor: NSObject {}
  private static let resources: Bundle = {
    // SwiftPM 6.2's generated resource_bundle_accessor.swift embeds the absolute build fallback
    // (verified 2026-11-18). Source: https://github.com/swiftlang/swift-package-manager
    // Resolve resources relative to the containing bundle instead.
    let host = Bundle(for: ResourceAnchor.self)
    let directory =
      host.bundleURL.pathExtension == "xctest"
      ? host.bundleURL.deletingLastPathComponent() : host.resourceURL
    guard
      let url = directory?.appendingPathComponent("Deltavee_Deltavee.bundle"),
      let bundle = Bundle(url: url)
    else { preconditionFailure("Missing executable resource bundle") }
    return bundle
  }()

  // Claude's Spark is from Anthropic's press kit; Codex's Blossom is the view container
  // icon of OpenAI's VS Code extension. Each SVG records its source. Both use a white
  // fill and no background.
  private static let icons: [Provider: NSImage] = Dictionary(
    uniqueKeysWithValues: Provider.allCases.map { provider in
      let name = provider == .anthropic ? "claude" : "codex"
      guard
        let url = resources.url(
          forResource: name, withExtension: "svg", subdirectory: "Resources"),
        let image = NSImage(contentsOf: url)
      else {
        preconditionFailure("Missing bundled provider icon: \(name)")
      }
      image.isTemplate = true
      return (provider, image)
    })

  static func icon(for provider: Provider) -> NSImage {
    icons[provider]!
  }

  private static let menuIcons: [Provider: NSImage] = Dictionary(
    uniqueKeysWithValues: Provider.allCases.map { provider in
      let source = icon(for: provider)
      // NSTextAttachment does not apply NSImage template tinting. Resolve the label
      // color at draw time so the mark follows the menu bar's actual appearance.
      let image = NSImage(size: NSSize(width: menuIconSize, height: menuIconSize), flipped: false) {
        rect in
        source.draw(in: rect)
        NSColor.labelColor.setFill()
        rect.fill(using: .sourceIn)
        return true
      }
      image.cacheMode = .never
      return (provider, image)
    })

  static func attributedString(parts: [IconPart], colorUsage: Bool) -> NSAttributedString {
    let font = NSFont.menuBarFont(ofSize: 0)
    guard !parts.isEmpty else {
      return NSAttributedString(
        string: "Δ --", attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
    let title = NSMutableAttributedString(string: "")
    for (index, part) in parts.enumerated() {
      if index > 0 { title.append(NSAttributedString(string: "  ")) }
      let attachment = NSTextAttachment()
      attachment.image = menuIcons[part.provider]
      attachment.bounds = NSRect(
        x: 0, y: (font.capHeight - menuIconSize) / 2, width: menuIconSize, height: menuIconSize)
      title.append(NSAttributedString(attachment: attachment))
      title.append(NSAttributedString(string: " "))
      if let dotColor = severityDotColor(part, colorUsage: colorUsage) {
        let dot = NSTextAttachment()
        dot.image = severityDot(dotColor, hollow: part.stale)
        dot.bounds = NSRect(
          x: 0, y: (font.capHeight - severityDotDiameter) / 2,
          width: severityDotDiameter + severityDotGap, height: severityDotDiameter)
        title.append(NSAttributedString(attachment: dot))
      }
      title.append(
        NSAttributedString(
          string: part.usageText,
          attributes: [.font: font, .foregroundColor: usageTextColor(part, colorUsage: colorUsage)]
        ))
    }
    return title
  }

  static let severityDotDiameter: CGFloat = 8
  static let severityRingWidth: CGFloat = 1.5
  private static let severityDotGap: CGFloat = 3
  /// Label-ink mix needed for 3:1 dot contrast on sRGB gray bars of 0.95 (light) and 0.20 (dark).
  /// Verified 2026-11-18 by MenuBarTitleTests.testUsageTintsKeepContrastOnLightAndDarkMenuBars.
  /// Threshold: https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html
  static let severityInkFraction: CGFloat = 0.3

  /// The usage number stays in label ink so text keeps at least 4.5:1 on either bar; severity
  /// color moves to the dot beside it. With colors on, staleness is carried by a hollow dot.
  static func usageTextColor(_ part: IconPart, colorUsage: Bool) -> NSColor {
    guard colorUsage, severityDotColor(part, colorUsage: true) != nil else {
      return part.stale ? .secondaryLabelColor : .labelColor
    }
    return .labelColor
  }

  /// The graph's severity color, mixed with the label ink of the bar it is drawn on: darker on a
  /// light bar and lighter on a dark one. Mixing with black or white keeps the hue. The dot is a
  /// graphical object: unmodified system teal and orange fall below the 3:1 contrast threshold on
  /// the test's light bar. No usage, no dot.
  /// The mix uses only the RGB channels of the label ink and returns an opaque color (`alpha: 1`).
  /// `labelColor` is partly transparent black or white, and its alpha must not carry over:
  /// a translucent dot shows the bar through it and lowers contrast. Use an opaque sRGB mix.
  static func severityDotColor(_ part: IconPart, colorUsage: Bool) -> NSColor? {
    guard colorUsage,
      let severity = QuotaPresentation.usageSeverity(usedPercent: part.weeklyUsedPercent)
    else { return nil }
    let color = QuotaPresentation.usageColor(severity)
    let fraction = severityInkFraction
    return NSColor(name: nil) { appearance in
      var tint = color
      var ink = NSColor.labelColor
      appearance.performAsCurrentDrawingAppearance {
        tint = color.usingColorSpace(.sRGB) ?? color
        ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
      }
      func mix(_ value: CGFloat, _ inkValue: CGFloat) -> CGFloat {
        value * (1 - fraction) + inkValue * fraction
      }
      return NSColor(
        srgbRed: mix(tint.redComponent, ink.redComponent),
        green: mix(tint.greenComponent, ink.greenComponent),
        blue: mix(tint.blueComponent, ink.blueComponent), alpha: 1)
    }
  }

  /// A filled circle, or a ring of the same color for a stale value, followed by transparent
  /// spacing. The color is resolved at draw time, like the provider marks, so it follows the menu
  /// bar's actual appearance.
  private static func severityDot(_ color: NSColor, hollow: Bool) -> NSImage {
    let image = NSImage(
      size: NSSize(width: severityDotDiameter + severityDotGap, height: severityDotDiameter),
      flipped: false
    ) { _ in
      let circle = NSRect(x: 0, y: 0, width: severityDotDiameter, height: severityDotDiameter)
      if hollow {
        color.setStroke()
        let ring = NSBezierPath(
          ovalIn: circle.insetBy(dx: severityRingWidth / 2, dy: severityRingWidth / 2))
        ring.lineWidth = severityRingWidth
        ring.stroke()
      } else {
        color.setFill()
        NSBezierPath(ovalIn: circle).fill()
      }
      return true
    }
    image.cacheMode = .never
    return image
  }

  static func accessibilityDescription(parts: [IconPart], mode: PercentMode) -> String {
    let heading = "Deltavee weekly quota (\(mode == .used ? "used" : "remaining"))"
    guard !parts.isEmpty else { return "\(heading)\nNo accounts" }
    let accounts = parts.map { part in
      "\(part.provider == .anthropic ? "Claude" : "Codex") · \(part.accountName): \(part.usageText)"
        + (part.stale ? " (more than 1 hour old)" : "")
    }
    return ([heading] + accounts).joined(separator: "\n")
  }
}
