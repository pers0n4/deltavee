// Helper for scripts/menubar-capture.sh. Run through `swiftc`; not part of the package.
//   fixtures <root> <codex>   Writes one fake home per scenario under <root> and prints
//                             `<id>\t<match>\t<accounts that must not show a failure>` lines
//                             for the shell script.
//   gray <level> <out>        Writes a solid sRGB gray PNG, used as a temporary wallpaper.
//   backdrop <level>          Covers the top of the main display, under the menu bar, with a flat
//                             gray until killed, so window shadows cannot shade the bar.
//   compose <shots> <out>     Splits each `<id>-light.png` / `<id>-dark.png` capture in <shots> into
//                             its parts, lays them out as the state sheet in <out>.png, and writes
//                             each cell's measured contrast to <out>.txt.
import AppKit
import CryptoKit

// MARK: Fixtures

/// One menu bar part: the provider, the weekly used percentage the source reports (nil for a
/// source without a weekly window), and how the last read went.
struct Part {
  enum Read {
    /// A successful read now, or 2 hours ago (older than the 1-hour stale threshold).
    case fresh, stale
    /// The read fails now; the last success is fresh or stale, or there is none.
    case failAfterFresh, failAfterStale, neverSucceeded
  }
  var provider = "anthropic"
  var used: Double?
  var read: Read
}

/// One app instance: its parts in menu bar order and the settings that change the title. The
/// defaults match a new install (Sources/DeltaveeCore/Settings.swift): remaining mode, usage colors
/// off.
struct Scenario {
  var id: String
  var mode = "remaining"
  var color = false
  var parts: [Part]
}

let readStates: [Part.Read] = [.fresh, .stale, .failAfterFresh, .failAfterStale]
let providers = [("claude", "anthropic"), ("codex", "openai")]

/// Every state is captured for both providers: one instance per provider and row of the sheet.
let scenarios: [Scenario] =
  [Scenario(id: "empty", parts: [])]
  + providers.flatMap { name, provider -> [Scenario] in
    func parts(_ used: Double?, _ reads: [Part.Read] = readStates) -> [Part] {
      reads.map { Part(provider: provider, used: used, read: $0) }
    }
    return [
      Scenario(id: "\(name)-novalue", parts: parts(nil, readStates + [.neverSucceeded])),
      Scenario(id: "\(name)-plain", parts: parts(50)),
      Scenario(id: "\(name)-normal", color: true, parts: parts(50)),
      Scenario(id: "\(name)-warning", color: true, parts: parts(80)),
      Scenario(id: "\(name)-critical", color: true, parts: parts(95)),
      Scenario(
        id: "\(name)-used", mode: "used", color: true,
        parts: [50, 80, 95].map { Part(provider: provider, used: $0, read: .fresh) }),
    ]
  }

/// The state sheet: each section is a grid whose cells point at one part of one instance's
/// capture. Sections start from a new install and change one thing at a time; every row appears
/// once for Claude and once for Codex. A cell may repeat a part from an earlier section when the
/// states coincide.
struct Cell {
  var scenario: String
  var part: Int
}

struct Section {
  var title: String
  var note: String
  var columns: [String]
  var rows: [(label: String, cells: [Cell])]
}

func cells(_ scenario: String, _ parts: Range<Int>) -> [Cell] {
  parts.map { Cell(scenario: scenario, part: $0) }
}

let sections: [Section] = {
  let reads = ["Fresh", "Stale", "Failed", "Failed, stale"]
  let levels = ["Normal", "Warning", "Critical"]
  let names = [("claude", "Claude"), ("codex", "Codex")]
  func byProvider(_ label: String, _ make: (String) -> [Cell]) -> [(label: String, cells: [Cell])] {
    names.map { id, name in ("\(name) · \(label)", make(id)) }
  }
  return [
    Section(
      title: "No data", note: "Before any account or successful read",
      columns: ["No accounts", "Claude never read", "Codex never read"],
      rows: [
        (
          "",
          [Cell(scenario: "empty", part: 0)]
            + names.map { Cell(scenario: "\($0.0)-novalue", part: 4) }
        )
      ]),
    Section(
      title: "Defaults", note: "Remaining mode, usage colors off", columns: reads,
      rows: byProvider("50% left") { cells("\($0)-plain", 0..<4) }
        + byProvider("no weekly value") { cells("\($0)-novalue", 0..<4) }),
    Section(
      title: "Usage colors on", note: "A dot shows the severity; no weekly value looks the same",
      columns: reads,
      rows: byProvider("50% left") { cells("\($0)-normal", 0..<4) }
        + byProvider("20% left") { cells("\($0)-warning", 0..<4) }
        + byProvider("5% left") { cells("\($0)-critical", 0..<4) }),
    Section(
      title: "Used mode", note: "Usage colors on, the same accounts", columns: levels,
      rows: names.flatMap { id, name in
        [
          (
            "\(name) · remaining",
            ["normal", "warning", "critical"].map { Cell(scenario: "\(id)-\($0)", part: 0) }
          ),
          ("\(name) · used", cells("\(id)-used", 0..<3)),
        ]
      }),
  ]
}()

func write(_ object: Any, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
}

func fixtures(root: URL, codex: String) throws {
  let now = Date()
  for scenario in scenarios {
    let home = root.appendingPathComponent(scenario.id).appendingPathComponent("home")
    let support = home.appendingPathComponent("Library/Application Support/dev.pers0n4.deltavee")
    var accounts: [[String: Any]] = []
    var states: [Any] = []
    var pending: [String] = []
    for (index, part) in scenario.parts.enumerated() {
      let id = UUID().uuidString
      let configDir = home.appendingPathComponent("config-\(index)").standardizedFileURL.path
      try FileManager.default.createDirectory(
        atPath: configDir, withIntermediateDirectories: true)
      accounts.append([
        "id": id, "name": "\(scenario.id)-\(index)", "provider": part.provider,
        "configDir": configDir, "showInIcon": true, "order": index,
      ])
      let observed: Date? =
        switch part.read {
        case .fresh, .failAfterFresh: now
        case .stale, .failAfterStale: now.addingTimeInterval(-7200)
        case .neverSucceeded: nil
        }
      let codex = part.provider == "openai"
      // A Codex read always reports the time of the read, so a stale Codex value exists only while
      // a read is still running over an old one: that fake Codex never answers, and the capture
      // must finish before the app's 20-second timeout (the script checks for the failure mark).
      let succeeds = part.read == .fresh || (part.read == .stale && !codex)
      if codex, part.read == .stale {
        pending.append("\(scenario.id)-\(index)")
        try "".write(toFile: configDir + "/hang", atomically: true, encoding: .utf8)
      }
      // Sources the app reads on launch. A failing read has no file, so the state below survives.
      if succeeds, let observed {
        if codex {
          // The fake Codex answers with this percentage, or no weekly window for "none", and fails
          // when the file is missing.
          try (part.used.map { "\($0)" } ?? "none").write(
            toFile: configDir + "/used", atomically: true, encoding: .utf8)
        } else {
          // Statusline file name: the first 16 hex digits of the SHA-256 of the absolute config
          // directory (Sources/DeltaveeCore/Models.swift, `Paths.statuslineFile`).
          let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined()
          let file = support.appendingPathComponent("statusline/\(digest.prefix(16)).json")
          let weekly: Any =
            part.used.map {
              ["used_percentage": $0, "resets_at": now.timeIntervalSince1970 + 3 * 86400]
            } ?? NSNull()
          try write(
            [
              "observedAt": observed.timeIntervalSince1970,
              "rateLimits": ["seven_day": weekly],
            ], to: file)
          try FileManager.default.setAttributes(
            [.modificationDate: observed], ofItemAtPath: file.path)
        }
      }
      // The last success that a failing or unfinished read keeps (`AccountState` as
      // `snapshots.json` encodes it).
      if !succeeds, let observed {
        var snapshot: [String: Any] = [
          "observedAt": observed.timeIntervalSinceReferenceDate,
          "fetchedAt": observed.timeIntervalSinceReferenceDate,
          "source": codex ? "codexAppServer" : "claudeStatusline",
        ]
        if let used = part.used {
          snapshot["weeklyUsedPercent"] = used
          snapshot["weeklyResetsAt"] =
            now.addingTimeInterval(3 * 86400)
            .timeIntervalSinceReferenceDate
        }
        states += [id, ["ok": ["_0": snapshot]]]
      }
    }
    let settings: [String: Any] = [
      "mode": scenario.mode, "colorMenuBarUsage": scenario.color, "claudeSource": "statuslineOnly",
      "codexPath": codex, "intervalSeconds": 600, "resetTimeMode": "relative",
      "updatedTimeMode": "relative", "timeFormat": "auto", "transparentPanel": false,
      "theme": "system",
    ]
    try write(
      ["settings": settings, "accounts": accounts],
      to: support.appendingPathComponent("accounts.json"))
    try write(states, to: support.appendingPathComponent("snapshots.json"))
    // The menu bar description lists account names, which identify the instance; with no
    // accounts it says "No accounts".
    let match = scenario.parts.isEmpty ? "No accounts" : "\(scenario.id)-0"
    print("\(scenario.id)\t\(match)\t\(pending.joined(separator: ","))")
  }
}

// MARK: Compose

func linear(_ value: CGFloat) -> CGFloat {
  value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}
func luminance(_ c: [CGFloat]) -> CGFloat {
  0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
}
func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
func hex(_ c: [CGFloat]) -> String {
  c.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
}

func loadBitmap(_ path: String) throws -> NSBitmapImageRep {
  guard let data = FileManager.default.contents(atPath: path),
    let rep = NSBitmapImageRep(data: data)
  else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path]) }
  return rep
}

/// sRGB pixels of a capture, which carries the display's color profile.
func pixels(_ rep: NSBitmapImageRep) -> [[[CGFloat]]] {
  (0..<rep.pixelsHigh).map { y in
    (0..<rep.pixelsWide).map { x in
      let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
      return [c.redComponent, c.greenComponent, c.blueComponent]
    }
  }
}

/// Contrast uses each dot's most saturated third and the most extreme twelfth of neutral glyph
/// pixels, measured against the surrounding menu bar.
func measure(_ rep: NSBitmapImageRep) -> (summary: String, black: Bool) {
  let image = pixels(rep)
  let width = rep.pixelsWide
  let edge = image[0] + image[image.count - 1]
  let barLuminance = edge.map(luminance).sorted()[edge.count / 2]
  let bar = edge.min { abs(luminance($0) - barLuminance) < abs(luminance($1) - barLuminance) }!
  if barLuminance < 0.001, image.joined().allSatisfy({ luminance($0) < 0.001 }) {
    return ("black capture", true)
  }
  func chroma(_ c: [CGFloat]) -> CGFloat { c.max()! - c.min()! }
  var groups: [[Int]] = []
  for x in 0..<width where image.contains(where: { chroma($0[x]) > 0.1 }) {
    if let last = groups.last?.last, x - last <= 2 {
      groups[groups.count - 1].append(x)
    } else {
      groups.append([x])
    }
  }
  var lines = ["bar #\(hex(bar))"]
  for group in groups {
    let colored = group.flatMap { x in image.map { $0[x] } }.filter { chroma($0) > 0.1 }
      .sorted { chroma($0) > chroma($1) }
    let core = colored.prefix(max(1, colored.count / 3))
    let mean = (0..<3).map { i in core.map { $0[i] }.reduce(0, +) / CGFloat(core.count) }
    lines.append(
      String(
        format: "dot x=%d #%@ %.2f:1", group[0], hex(mean),
        contrast(luminance(mean), barLuminance)))
  }
  let glyphs = image.joined().filter {
    chroma($0) < 0.05 && abs(luminance($0) - barLuminance) > 0.05
  }
  .sorted { abs(luminance($0) - barLuminance) > abs(luminance($1) - barLuminance) }
  if !glyphs.isEmpty {
    let ink = glyphs.prefix(max(1, glyphs.count / 12))
    let mean = (0..<3).map { i in ink.map { $0[i] }.reduce(0, +) / CGFloat(ink.count) }
    lines.append(
      String(format: "ink #%@ %.2f:1", hex(mean), contrast(luminance(mean), barLuminance)))
  }
  return (lines.joined(separator: ", "), false)
}

func fail(_ message: String) -> Error {
  CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: message])
}

/// The horizontal pixel ranges of a capture's parts. Parts are joined by two spaces, the widest
/// gaps in the title (Sources/Deltavee/MenuBarTitle.swift, `attributedString`), so the `count - 1`
/// widest gaps between drawn columns separate them.
func partRanges(_ rep: NSBitmapImageRep, count: Int) throws -> [Range<Int>] {
  let image = pixels(rep)
  // The bar can shade, so each pixel is compared with the bar at the same row, interpolated between
  // the capture's left and right edges, which the script pads with 4 points of empty bar.
  let last = rep.pixelsWide - 1
  let rowBars = image.map { row in
    (luminance(row[0]), luminance(row[last]))
  }
  var runs: [Range<Int>] = []
  for x in 0..<rep.pixelsWide
  where image.indices.contains(where: { y in
    let pixel = image[y][x]
    let t = CGFloat(x) / CGFloat(last)
    let bar = rowBars[y].0 * (1 - t) + rowBars[y].1 * t
    return abs(luminance(pixel) - bar) > 0.04 || pixel.max()! - pixel.min()! > 0.08
  }) {
    if let last = runs.last, last.upperBound == x {
      runs[runs.count - 1] = last.lowerBound..<(x + 1)
    } else {
      runs.append(x..<(x + 1))
    }
  }
  guard runs.count >= count else { throw fail("Found \(runs.count) glyph runs for \(count) parts") }
  let splits = (1..<runs.count)
    .sorted {
      runs[$0].lowerBound - runs[$0 - 1].upperBound > runs[$1].lowerBound - runs[$1 - 1].upperBound
    }
    .prefix(count - 1).sorted()
  return zip([0] + splits, splits + [runs.count]).map {
    runs[$0].lowerBound..<runs[$1 - 1].upperBound
  }
}

/// A capture without its top and bottom 3 points, where the menu bar can blend into the window or
/// shadow below it. The glyphs are 14 points tall and centered in the item.
func trimmed(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
  let inset = 6
  let rect = CGRect(x: 0, y: inset, width: rep.pixelsWide, height: rep.pixelsHigh - inset * 2)
  return NSBitmapImageRep(cgImage: rep.cgImage!.cropping(to: rect)!)
}

func crop(_ rep: NSBitmapImageRep, _ range: Range<Int>) -> NSBitmapImageRep {
  let pad = 12
  let x = max(0, range.lowerBound - pad)
  let rect = CGRect(
    x: x, y: 0, width: min(rep.pixelsWide, range.upperBound + pad) - x, height: rep.pixelsHigh)
  return NSBitmapImageRep(cgImage: rep.cgImage!.cropping(to: rect)!)
}

func compose(shots: String, out: String) throws {
  // Every part of every instance, cropped from both captures.
  var parts: [String: [(light: NSBitmapImageRep, dark: NSBitmapImageRep)]] = [:]
  var shaded: [String] = []
  for scenario in scenarios {
    let count = max(1, scenario.parts.count)
    let light = trimmed(try loadBitmap("\(shots)/\(scenario.id)-light.png"))
    let dark = trimmed(try loadBitmap("\(shots)/\(scenario.id)-dark.png"))
    for (theme, rep) in [("light", light), ("dark", dark)] where measure(rep).black {
      throw fail("The \(theme) capture of \(scenario.id) is black; the display may be locked.")
    }
    // A light bar should be flat. It shades toward its bottom when something below the menu bar
    // shows through, such as a window shadow.
    let edge = pixels(light).map { luminance($0[0]) }
    if edge.first! - edge.last! > 0.05 {
      shaded.append(scenario.id)
    }
    // Both captures cover the same item, so the dark one, whose bar a window shadow cannot shade,
    // splits both.
    let ranges: [Range<Int>]
    do {
      ranges = try partRanges(dark, count: count)
    } catch {
      throw fail("\(scenario.id)-dark.png: \(error.localizedDescription)")
    }
    let themes = [light, dark].map { rep in ranges.map { crop(rep, $0) } }
    parts[scenario.id] = zip(themes[0], themes[1]).map { ($0, $1) }
  }

  var report: [String] = []
  for section in sections {
    for row in section.rows {
      for (column, cell) in zip(section.columns, row.cells) {
        let pair = parts[cell.scenario]![cell.part]
        let name = [section.title, row.label, column].filter { !$0.isEmpty }.joined(
          separator: " / ")
        report.append("\(name) [light] \(measure(pair.light).summary)")
        report.append("\(name) [dark] \(measure(pair.dark).summary)")
      }
    }
  }
  if !shaded.isEmpty {
    let warning =
      "Warning: the light bar darkens toward its bottom in \(shaded.joined(separator: ", ")). "
      + "Something below the menu bar, such as a window shadow, may show through."
    report.insert(warning, at: 0)
    FileHandle.standardError.write(Data((warning + "\n").utf8))
  }
  try (report.joined(separator: "\n") + "\n").write(
    toFile: out + ".txt", atomically: true, encoding: .utf8)

  // Layout in points; captures are 2x and are drawn pixel for pixel.
  let scale: CGFloat = 2
  let margin: CGFloat = 28
  let titleFont = NSFont.systemFont(ofSize: 18, weight: .bold)
  let noteFont = NSFont.systemFont(ofSize: 11)
  let sectionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
  let headerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
  let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
  let secondary = NSColor(white: 0.45, alpha: 1)
  func width(_ text: String, _ font: NSFont) -> CGFloat {
    ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
  }
  let title = "Deltavee menu bar states"
  let note =
    "Each cell shows the installed app on a light menu bar (top) and a dark one (bottom). "
    + "Stale: the last successful read is over an hour old. Failed: the latest read failed."
  let pairs = parts.values.joined()
  let chipHeight =
    pairs.map { CGFloat(max($0.light.pixelsHigh, $0.dark.pixelsHigh)) }.max()! / scale
  let labelWidth = sections.flatMap { $0.rows.map { width($0.label, labelFont) } }.max()! + 20
  let columnGap: CGFloat = 12
  let rowGap: CGFloat = 12
  // One column width for the whole sheet, so every grid lines up like a design system table.
  let columnWidth =
    max(
      sections.flatMap { $0.columns.map { width($0, headerFont) } }.max()!,
      pairs.map { CGFloat(max($0.light.pixelsWide, $0.dark.pixelsWide)) / scale }.max()!) + 16
  let columnWidths = sections.map { Array(repeating: columnWidth, count: $0.columns.count) }
  let gridWidth = columnWidths.map { $0.reduce(0, +) + columnGap * CGFloat($0.count - 1) }.max()!
  let sheetWidth = margin * 2 + max(labelWidth + gridWidth, width(title, titleFont))
  let noteHeight: CGFloat = 32
  let sectionHeights = sections.map {
    28 + 20 + CGFloat($0.rows.count) * (chipHeight * 2 + rowGap) + 16
  }
  let sheetHeight = margin * 2 + 26 + noteHeight + 8 + sectionHeights.reduce(0, +)

  let sheet = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(sheetWidth * scale),
    pixelsHigh: Int(sheetHeight * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  sheet.size = NSSize(width: sheetWidth, height: sheetHeight)
  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: sheet)!
  context.imageInterpolation = .none
  NSGraphicsContext.current = context
  /// A rectangle given from the top of the sheet.
  func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: sheetHeight - top - h, width: w, height: h)
  }
  func text(
    _ string: String, _ font: NSFont, _ color: NSColor, in frame: NSRect, center: Bool = false
  ) {
    let style = NSMutableParagraphStyle()
    style.alignment = center ? .center : .left
    NSAttributedString(
      string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
    ).draw(with: frame, options: [.usesLineFragmentOrigin])
  }
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight).fill()
  var top = margin
  text(title, titleFont, .black, in: rect(margin, top, sheetWidth - margin * 2, 26))
  top += 26
  text(note, noteFont, secondary, in: rect(margin, top, sheetWidth - margin * 2, noteHeight))
  top += noteHeight + 8
  for (section, widths) in zip(sections, columnWidths) {
    top += 12
    text(section.title, sectionFont, .black, in: rect(margin, top, sheetWidth, 18))
    let noteX = margin + width(section.title, sectionFont) + 10
    text(section.note, noteFont, secondary, in: rect(noteX, top + 2, sheetWidth - noteX, 16))
    NSColor(white: 0.88, alpha: 1).setFill()
    rect(margin, top + 21, sheetWidth - margin * 2, 1).fill()
    top += 28
    var x = margin + labelWidth
    for (column, w) in zip(section.columns, widths) {
      text(column, headerFont, secondary, in: rect(x, top, w, 16), center: true)
      x += w + columnGap
    }
    top += 20
    for row in section.rows {
      let rowHeight = chipHeight * 2
      text(row.label, labelFont, .black, in: rect(margin, top + rowHeight / 2 - 8, labelWidth, 18))
      x = margin + labelWidth
      for (cell, w) in zip(row.cells, widths) {
        let pair = parts[cell.scenario]![cell.part]
        let frame = rect(x, top, w, rowHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).addClip()
        for (index, rep) in [pair.light, pair.dark].enumerated() {
          let band = rect(x, top + chipHeight * CGFloat(index), w, chipHeight)
          // Extend the bar across the cell by stretching the capture's first pixel column, which
          // goes through the same color matching as the capture itself.
          rep.draw(
            in: band, from: NSRect(x: 0, y: 0, width: 0.5, height: CGFloat(rep.pixelsHigh) / scale),
            operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
          let size = NSSize(
            width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
          rep.draw(
            in: NSRect(
              x: (band.midX - size.width / 2).rounded(), y: (band.midY - size.height / 2).rounded(),
              width: size.width, height: size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        x += w + columnGap
      }
      top += rowHeight + rowGap
    }
    top += 4
  }
  NSGraphicsContext.restoreGraphicsState()
  try sheet.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: out + ".png"))
}

func gray(level: CGFloat, out: String) throws {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor(srgbRed: level, green: level, blue: level, alpha: 1).setFill()
  NSRect(x: 0, y: 0, width: 64, height: 64).fill()
  NSGraphicsContext.restoreGraphicsState()
  try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}

/// A window AppKit leaves where it is put, including under the menu bar.
final class UnconstrainedWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// The menu bar is translucent: the shadow of a window just below it shows through and darkens a
/// light bar toward its bottom. A shadowless, click-through window of the wallpaper's gray sits
/// above every app window and below the menu bar, so the bar shows only that gray.
func backdrop(level: CGFloat) -> Never {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let screen = NSScreen.screens[0]
  let height: CGFloat = 120
  let window = UnconstrainedWindow(
    contentRect: NSRect(
      x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width,
      height: height),
    styleMask: .borderless, backing: .buffered, defer: false)
  window.backgroundColor = NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
  window.isOpaque = true
  window.hasShadow = false
  window.ignoresMouseEvents = true
  window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
  window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
  window.orderFrontRegardless()
  app.run()
  exit(0)
}

let arguments = CommandLine.arguments
do {
  switch arguments.count > 1 ? arguments[1] : "" {
  case "fixtures" where arguments.count == 4:
    try fixtures(root: URL(fileURLWithPath: arguments[2]), codex: arguments[3])
  case "gray" where arguments.count == 4:
    guard let level = Double(arguments[2]) else { exit(2) }
    try gray(level: CGFloat(level), out: arguments[3])
  case "backdrop" where arguments.count == 3:
    guard let level = Double(arguments[2]) else { exit(2) }
    backdrop(level: CGFloat(level))
  case "compose" where arguments.count == 4:
    try compose(shots: arguments[2], out: arguments[3])
  default:
    FileHandle.standardError.write(
      Data(
        "usage: fixtures <root> <codex> | gray <level> <out> | backdrop <level> | compose <shots> <out>\n"
          .utf8))
    exit(2)
  }
} catch {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(1)
}
