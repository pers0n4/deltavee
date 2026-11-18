import AppKit
import DeltaveeCore
import XCTest

@testable import Deltavee

final class MenuBarTitleTests: XCTestCase {
  @MainActor
  func testOfficialImagesReplaceNamesAndPreserveUsageMarkers() {
    let parts = [
      IconPart(provider: .anthropic, accountName: "Claude 개인 계정", usageText: "64%!", stale: true),
      IconPart(provider: .openai, accountName: "Codex 개인 계정", usageText: "--", stale: false),
    ]
    let title = MenuBarTitle.attributedString(parts: parts, colorUsage: false)
    XCTAssertEqual(title.string, "\u{fffc} 64%!  \u{fffc} --")
    var images: [NSImage] = []
    title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) {
      value, _, _ in
      guard let attachment = value as? NSTextAttachment else { return }
      XCTAssertEqual(attachment.bounds.size, NSSize(width: 14, height: 14))
      XCTAssertEqual(
        attachment.bounds.midY, NSFont.menuBarFont(ofSize: 0).capHeight / 2, accuracy: 0.01)
      if let image = attachment.image { images.append(image) }
    }
    XCTAssertEqual(images.count, 2)
    XCTAssertTrue(images.allSatisfy { $0.isValid && $0.size.width > 0 })
    XCTAssertNotEqual(images.first?.tiffRepresentation, images.last?.tiffRepresentation)
    let staleColor = title.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
    XCTAssertEqual(staleColor, .secondaryLabelColor)
    let description = MenuBarTitle.accessibilityDescription(parts: parts, mode: .remaining)
    XCTAssertTrue(description.hasPrefix("Deltavee weekly quota (remaining)"))
    XCTAssertTrue(
      description.contains("Claude · Claude 개인 계정: 64%! (more than 1 hour old)"))
    XCTAssertTrue(description.hasSuffix("Codex · Codex 개인 계정: --"))
  }

  @MainActor
  func testStaleValueIsAnnouncedWithoutVisibleMarker() {
    let stale = IconPart(provider: .anthropic, accountName: "Work", usageText: "64%", stale: true)
    let fresh = IconPart(provider: .openai, accountName: "Home", usageText: "30%", stale: false)
    let title = MenuBarTitle.attributedString(parts: [stale], colorUsage: false)
    XCTAssertEqual(title.string, "\u{fffc} 64%")
    XCTAssertEqual(
      title.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor,
      .secondaryLabelColor)
    XCTAssertEqual(
      MenuBarTitle.accessibilityDescription(parts: [stale, fresh], mode: .used),
      "Deltavee weekly quota (used)\nClaude · Work: 64% (more than 1 hour old)\nCodex · Home: 30%")
  }

  @MainActor
  func testUsageColorOptionTintsBySeverityOfActualConsumption() throws {
    func title(_ used: Double?, stale: Bool = false, enabled: Bool = true) -> NSAttributedString {
      MenuBarTitle.attributedString(
        parts: [
          IconPart(
            provider: .anthropic, accountName: "A", usageText: "42%", stale: stale,
            weeklyUsedPercent: used)
        ], colorUsage: enabled)
    }
    /// The number's color; the dot, when present, is the attachment just before it.
    func numberColor(_ used: Double?, stale: Bool = false, enabled: Bool = true) -> NSColor {
      let string = title(used, stale: stale, enabled: enabled)
      return string.attribute(.foregroundColor, at: string.length - 1, effectiveRange: nil)
        as! NSColor
    }
    func color(_ used: Double?, stale: Bool = false) -> NSColor {
      MenuBarTitle.severityDotColor(
        IconPart(
          provider: .anthropic, accountName: "A", usageText: "42%", stale: stale,
          weeklyUsedPercent: used), colorUsage: true)!
    }
    XCTAssertEqual(title(50).string, "\u{fffc} \u{fffc}42%", "Logo, space, dot, number")
    XCTAssertEqual(title(50, stale: true).string, "\u{fffc} \u{fffc}42%")
    XCTAssertEqual(title(50, enabled: false).string, "\u{fffc} 42%")
    XCTAssertEqual(title(nil).string, "\u{fffc} 42%", "No usage, no dot")
    XCTAssertEqual(title(.nan).string, "\u{fffc} 42%")
    let dot = try XCTUnwrap(
      title(50).attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment)
    XCTAssertEqual(dot.bounds.height, MenuBarTitle.severityDotDiameter)
    XCTAssertEqual(
      dot.bounds.midY, NSFont.menuBarFont(ofSize: 0).capHeight / 2, accuracy: 0.01,
      "The dot sits on the digits' optical center")
    for used in [50.0, 80, 95] {
      XCTAssertEqual(numberColor(used), .labelColor, "Numbers stay in label ink: \(used)")
      XCTAssertEqual(numberColor(used, stale: true), .labelColor, "The dot marks staleness")
    }
    XCTAssertEqual(numberColor(nil), .labelColor)
    XCTAssertEqual(numberColor(.nan, stale: true), .secondaryLabelColor)
    XCTAssertEqual(numberColor(95, enabled: false), .labelColor)
    XCTAssertEqual(numberColor(95, stale: true, enabled: false), .secondaryLabelColor)
    // Severity boundaries pick the graph's hue; mixing with black or white keeps it.
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      func hue(_ color: NSColor) -> CGFloat {
        var resolved: NSColor?
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
          resolved = color.usingColorSpace(.sRGB)
        }
        return resolved!.hueComponent
      }
      XCTAssertEqual(hue(color(69.9)), hue(.systemTeal), accuracy: 0.01)
      XCTAssertEqual(hue(color(70)), hue(.systemOrange), accuracy: 0.01)
      XCTAssertEqual(hue(color(90)), hue(.systemRed), accuracy: 0.01)
      XCTAssertNotEqual(hue(color(69.9)), hue(color(70)), accuracy: 0.05)
      XCTAssertEqual(hue(color(95, stale: true)), hue(color(95)), accuracy: 0.001)
    }
  }

  /// The dot's color is resolved when the menu bar draws it, so the drawn pixels must carry the
  /// mixed severity color of the appearance being drawn. A fresh value draws a filled dot and a
  /// stale value a ring with a transparent center; the number stays neutral and follows the dot.
  @MainActor
  func testSeverityDotDrawsFilledOrHollowInSeverityColor() throws {
    for (name, used, stale) in [
      (NSAppearance.Name.aqua, 95.0, false), (.aqua, 50, true), (.darkAqua, 80, false),
      (.darkAqua, 95, true),
    ] {
      let appearance = try XCTUnwrap(NSAppearance(named: name))
      let part = IconPart(
        provider: .openai, accountName: "A", usageText: "42%", stale: stale,
        weeklyUsedPercent: used)
      var target: NSColor?
      appearance.performAsCurrentDrawingAppearance {
        target = MenuBarTitle.severityDotColor(part, colorUsage: true)?.usingColorSpace(.sRGB)
      }
      let expected = try XCTUnwrap(target)
      let title = MenuBarTitle.attributedString(parts: [part], colorUsage: true)
      let size = title.size()
      let scale = 4
      let width = Int(ceil(size.width)) * scale
      let height = Int(ceil(size.height)) * scale
      let bitmap = try XCTUnwrap(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0))
      bitmap.size = size
      let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      appearance.performAsCurrentDrawingAppearance { title.draw(at: .zero) }
      NSGraphicsContext.restoreGraphicsState()
      let label = "\(name.rawValue) \(used) stale \(stale)"
      var dotPixels = 0
      var minX = width
      var maxX = -1
      var minY = height
      var maxY = -1
      var neutralMinX = width
      for y in 0..<height {
        for x in 0..<width {
          let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
          guard color.alphaComponent > 0.9 else { continue }
          let channels = [color.redComponent, color.greenComponent, color.blueComponent]
          if channels.max()! - channels.min()! < 0.05 {
            if x > maxX, maxX >= 0 { neutralMinX = min(neutralMinX, x) }
            continue
          }
          dotPixels += 1
          minX = min(minX, x)
          maxX = max(maxX, x)
          minY = min(minY, y)
          maxY = max(maxY, y)
          XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.03, label)
          XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.03, label)
          XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.03, label)
        }
      }
      let diameter = MenuBarTitle.severityDotDiameter * CGFloat(scale)
      XCTAssertGreaterThan(dotPixels, 40, "The dot must be drawn: \(label)")
      XCTAssertEqual(CGFloat(maxX - minX + 1), diameter, accuracy: 2, label)
      XCTAssertLessThan(maxX, neutralMinX, "The number follows the dot: \(label)")
      let center = try XCTUnwrap(bitmap.colorAt(x: (minX + maxX) / 2, y: (minY + maxY) / 2))
      let filledArea = Double.pi * pow(Double(diameter) / 2, 2)
      if stale {
        XCTAssertLessThan(center.alphaComponent, 0.1, "A stale dot is hollow: \(label)")
        XCTAssertLessThan(Double(dotPixels), filledArea * 0.6, label)
      } else {
        XCTAssertGreaterThan(center.alphaComponent, 0.9, "A fresh dot is filled: \(label)")
        XCTAssertGreaterThan(Double(dotPixels), filledArea * 0.7, label)
      }
    }
  }

  /// Numbers keep text contrast (4.5:1) and dots keep graphical-object contrast (3:1) on both menu
  /// bar extremes; the dot is the graph color mixed with the bar's label ink, and staleness changes
  /// its shape, not its color.
  /// Backgrounds approximate the bars captured on 2026-11-15: a bright solid wallpaper gives a
  /// near-white bar with dark text, and Reduce Transparency in dark mode a dark gray bar.
  @MainActor
  func testUsageTintsKeepContrastOnLightAndDarkMenuBars() throws {
    func linear(_ value: CGFloat) -> CGFloat {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func luminance(_ color: NSColor) -> CGFloat {
      0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722
        * linear(color.blueComponent)
    }
    func resolve(_ color: NSColor, _ appearance: NSAppearance) throws -> NSColor {
      var resolved: NSColor?
      appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
      return try XCTUnwrap(resolved)
    }
    func over(_ color: NSColor, _ background: CGFloat) -> NSColor {
      let alpha = color.alphaComponent
      func mix(_ value: CGFloat) -> CGFloat { value * alpha + background * (1 - alpha) }
      return NSColor(
        srgbRed: mix(color.redComponent), green: mix(color.greenComponent),
        blue: mix(color.blueComponent), alpha: 1)
    }
    func contrast(_ color: NSColor, _ background: CGFloat) -> CGFloat {
      let text = luminance(over(color, background))
      let bar = luminance(
        NSColor(srgbRed: background, green: background, blue: background, alpha: 1))
      return (max(text, bar) + 0.05) / (min(text, bar) + 0.05)
    }
    let bars: [(NSAppearance.Name, CGFloat, ink: CGFloat)] = [
      (.aqua, 0.95, 0), (.vibrantLight, 0.95, 0), (.darkAqua, 0.20, 1), (.vibrantDark, 0.20, 1),
    ]
    for used in [50.0, 80, 95] {
      let severity = try XCTUnwrap(QuotaPresentation.usageSeverity(usedPercent: used))
      let graph = QuotaPresentation.usageColor(severity)
      func part(stale: Bool) -> IconPart {
        IconPart(
          provider: .openai, accountName: "A", usageText: "--", stale: stale,
          weeklyUsedPercent: used)
      }
      func dot(stale: Bool) throws -> NSColor {
        try XCTUnwrap(MenuBarTitle.severityDotColor(part(stale: stale), colorUsage: true))
      }
      for (name, background, ink) in bars {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        let label = "\(severity) on \(name.rawValue)"
        for stale in [false, true] {
          let number = try resolve(
            MenuBarTitle.usageTextColor(part(stale: stale), colorUsage: true), appearance)
          XCTAssertGreaterThanOrEqual(
            contrast(number, background), 4.5, "Number (stale \(stale)): \(label)")
        }
        let fresh = try resolve(try dot(stale: false), appearance)
        let stale = try resolve(try dot(stale: true), appearance)
        XCTAssertGreaterThanOrEqual(contrast(fresh, background), 3, "Dot: \(label)")
        XCTAssertEqual(fresh, stale, "Staleness changes the shape only: \(label)")
        let resolvedGraph = try resolve(graph, appearance)
        let fraction = MenuBarTitle.severityInkFraction
        for (component, source) in zip(
          [fresh.redComponent, fresh.greenComponent, fresh.blueComponent],
          [resolvedGraph.redComponent, resolvedGraph.greenComponent, resolvedGraph.blueComponent])
        {
          XCTAssertEqual(
            component, source * (1 - fraction) + ink * fraction, accuracy: 0.002,
            "The graph color mixed with the label ink: \(label)")
        }
      }
    }
    // Unmixed, the light-bar teal and orange would fall below 3:1, so the mix is what passes.
    for color in [NSColor.systemTeal, .systemOrange] {
      let light = try resolve(color, try XCTUnwrap(NSAppearance(named: .aqua)))
      XCTAssertLessThan(contrast(light, 0.95), 3)
    }
  }

  @MainActor
  func testEmptyAccountsRemainVisible() throws {
    for colorUsage in [false, true] {
      let title = MenuBarTitle.attributedString(parts: [], colorUsage: colorUsage)
      XCTAssertEqual(title.string, "Δ --")
      var range = NSRange()
      let attributes = title.attributes(at: 0, effectiveRange: &range)
      XCTAssertEqual(
        range, NSRange(location: 0, length: title.length), "One style for the whole title")
      XCTAssertEqual(attributes[.font] as? NSFont, NSFont.menuBarFont(ofSize: 0))
      XCTAssertEqual(attributes[.foregroundColor] as? NSColor, .labelColor)
    }
    XCTAssertEqual(
      MenuBarTitle.accessibilityDescription(parts: [], mode: .used),
      "Deltavee weekly quota (used)\nNo accounts")
  }

  /// The placeholder must follow the appearance like the usage text: dark glyphs on a light bar,
  /// light glyphs on a dark bar.
  @MainActor
  func testEmptyAccountsTextFollowsLightAndDarkAppearance() throws {
    let title = MenuBarTitle.attributedString(parts: [], colorUsage: true)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      let size = title.size()
      let width = Int(ceil(size.width))
      let height = Int(ceil(size.height))
      let bitmap = try XCTUnwrap(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0))
      let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        title.draw(at: .zero)
      }
      NSGraphicsContext.restoreGraphicsState()
      var inkPixels = 0
      var brightness = 0.0
      for y in 0..<height {
        for x in 0..<width {
          let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          guard color.alphaComponent > 0.5 else { continue }
          inkPixels += 1
          brightness += color.redComponent
        }
      }
      XCTAssertGreaterThan(inkPixels, 10, "Placeholder must not be blank")
      let mean = brightness / Double(max(1, inkPixels))
      if name == .darkAqua {
        XCTAssertGreaterThan(mean, 0.7)
      } else {
        XCTAssertLessThan(mean, 0.3)
      }
    }
  }

  @MainActor
  func testVectorMarksAreMonochromeAndFollowLightAndDarkAppearance() throws {
    for provider in Provider.allCases {
      XCTAssertTrue(MenuBarTitle.icon(for: provider).isTemplate)
      for name in [NSAppearance.Name.aqua, .darkAqua] {
        let part = IconPart(provider: provider, accountName: "test", usageText: "42%", stale: false)
        let title = MenuBarTitle.attributedString(parts: [part], colorUsage: false)
        let attachment = try XCTUnwrap(
          title.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let image = try XCTUnwrap(attachment.image)
        let bitmap = try XCTUnwrap(
          NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
          image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        }
        NSGraphicsContext.restoreGraphicsState()
        var opaquePixels = 0
        var brightness = 0.0
        var minX = 32
        var minY = 32
        var maxX = -1
        var maxY = -1
        for y in 0..<32 {
          for x in 0..<32 {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            guard color.alphaComponent > 0.5 else { continue }
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            opaquePixels += 1
            brightness += color.redComponent
            XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.02)
            XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.02)
          }
        }
        XCTAssertGreaterThan(opaquePixels, 40, "Logo must not be blank")
        XCTAssertGreaterThanOrEqual(
          max(maxX - minX + 1, maxY - minY + 1), 30, "Both marks must fill the same optical size")
        XCTAssertEqual(Double(minX + maxX) / 2, 15.5, accuracy: 1)
        XCTAssertEqual(Double(minY + maxY) / 2, 15.5, accuracy: 1)
        XCTAssertLessThan(
          opaquePixels, 750, "Logo must have transparent negative space, not a filled tile")
        let mean = brightness / Double(max(1, opaquePixels))
        if name == .darkAqua {
          XCTAssertGreaterThan(mean, 0.7)
        } else {
          XCTAssertLessThan(mean, 0.3)
        }
      }
    }
  }
}
