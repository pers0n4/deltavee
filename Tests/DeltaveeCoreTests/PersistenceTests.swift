import XCTest

@testable import DeltaveeCore

final class PersistenceTests: CoreTestCase {
  func testRateLimitStoreRoundTrip() throws {
    let directory = try temporaryDirectory()
    let store = RateLimitStore(directory: directory)
    XCTAssertEqual(try store.load(), [:])
    let holds = [UUID(): now.addingTimeInterval(300)]
    try store.save(holds)
    XCTAssertEqual(try RateLimitStore(directory: directory).load(), holds)
  }
  func testFreshStoreShowsRemainingWithoutOverridingSavedPercentMode() throws {
    let store = AccountStore(directory: try temporaryDirectory())
    var document = try store.load()
    XCTAssertEqual(
      IconRenderer.percentage(64, mode: document.settings.mode), "36%")
    for mode in PercentMode.allCases {
      document.settings.mode = mode
      try store.save(document)
      let restored = try store.load()
      XCTAssertEqual(restored, document)
      XCTAssertEqual(
        IconRenderer.percentage(64, mode: restored.settings.mode),
        mode == .remaining ? "36%" : "64%")
    }
  }
  func testLegacyAccountDocumentPreservesAccountsAndSettings() throws {
    for resetTimeField in ["", #", "resetTimeMode": null"#] {
      let data = Data(
        """
        {
          "accounts": [{
            "id": "AE79D859-9D79-4CB1-BEAC-FA01E173627A",
            "name": "Work Claude", "provider": "anthropic",
            "configDir": "/fake/work-claude", "showInIcon": false, "order": 3,
            "identityFingerprint": "stored-identity"
          }],
          "settings": {
            "mode": "remaining", "claudeSource": "statuslineOnly",
            "intervalSeconds": 1234, "codexPath": "/fake/bin/codex"\(resetTimeField)
          }
        }
        """.utf8)
      let document = try JSONDecoder().decode(AccountDocument.self, from: data)
      XCTAssertEqual(
        document.accounts,
        [
          Account(
            id: try XCTUnwrap(UUID(uuidString: "AE79D859-9D79-4CB1-BEAC-FA01E173627A")),
            name: "Work Claude", provider: .anthropic, configDir: "/fake/work-claude",
            showInIcon: false, order: 3, identityFingerprint: "stored-identity")
        ])
      XCTAssertEqual(document.settings.resetTimeMode, .absolute)
      XCTAssertEqual(document.settings.mode, .remaining)
      XCTAssertEqual(document.settings.claudeSource, .statuslineOnly)
      // A free-form interval saved before the fixed choices snaps to the nearest choice.
      XCTAssertEqual(document.settings.intervalSeconds, 900)
      XCTAssertEqual(document.settings.codexPath, "/fake/bin/codex")
    }
  }
  func testIntervalSnapsToNearestChoiceWithTiesTakingTheLongerInterval() throws {
    XCTAssertEqual(Settings.intervalChoices, [180, 300, 600, 900, 1800])
    let cases: [(Double, Double)] = [
      (-5, 180), (0, 180), (179, 180), (180, 180), (240, 300), (241, 300), (449, 300),
      (450, 600), (600, 600), (750, 900), (1234, 900), (1349, 900), (1350, 1800),
      (3599, 1800), (99999, 1800), (.nan, 600), (.infinity, 600), (-.infinity, 600),
    ]
    for (saved, expected) in cases {
      XCTAssertEqual(Settings.nearestInterval(to: saved), expected, "Saved: \(saved)")
      var settings = Settings()
      settings.intervalSeconds = saved
      XCTAssertEqual(settings.validInterval, expected, "Saved: \(saved)")
    }
    for saved in [42.0, 240, 1234, 99999] {
      var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any])
      object["intervalSeconds"] = saved
      let decoded = try JSONDecoder().decode(
        Settings.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertEqual(decoded.intervalSeconds, Settings.nearestInterval(to: saved))
    }
  }
  func testSettingsDecodingRejectsMalformedResetTimeAndRequiredFields() throws {
    let legacy: [String: Any] = [
      "mode": "remaining", "claudeSource": "statuslineOnly",
      "intervalSeconds": 1234, "codexPath": "/fake/bin/codex",
    ]
    for value in ["unknown", 42, true] as [Any] {
      var settings = legacy
      settings["resetTimeMode"] = value
      let data = try JSONSerialization.data(withJSONObject: settings)
      XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: data))
    }
    for key in legacy.keys {
      var missing = legacy
      missing.removeValue(forKey: key)
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          Settings.self, from: JSONSerialization.data(withJSONObject: missing))
      ) { error in
        guard case DecodingError.keyNotFound(let codingKey, _) = error else {
          return XCTFail("Expected missing required key error for \(key), got \(error)")
        }
        XCTAssertEqual(codingKey.stringValue, key)
      }
      for value in [NSNull(), ["invalid": true]] as [Any] {
        var malformed = legacy
        malformed[key] = value
        XCTAssertThrowsError(
          try JSONDecoder().decode(
            Settings.self, from: JSONSerialization.data(withJSONObject: malformed)))
      }
    }
  }
  func testLegacyClockPreferencePreservesSavedDocument() throws {
    var settings = Settings()
    settings.mode = .remaining
    settings.resetTimeMode = .relative
    settings.claudeSource = .statuslineOnly
    settings.intervalSeconds = 900
    settings.codexPath = "/fake/bin/codex"
    var savedAccount = account()
    savedAccount.showInIcon = false
    savedAccount.order = 3
    savedAccount.identityFingerprint = "stored-identity"
    let document = AccountDocument(accounts: [savedAccount], settings: settings)
    let encoded = try JSONEncoder().encode(document)
    for value in [nil, NSNull()] as [Any?] {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      var storedSettings = try XCTUnwrap(object["settings"] as? [String: Any])
      storedSettings["timeFormat"] = value
      object["settings"] = storedSettings
      let decoded = try JSONDecoder().decode(
        AccountDocument.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertEqual(decoded, document)
      XCTAssertEqual(decoded.settings.timeFormat, .auto)
    }
  }
  func testSavedClockPreferencesRoundtripWithoutChangingOtherPreferences() throws {
    let directory = try temporaryDirectory()
    for timeFormat in TimeFormat.allCases {
      var settings = Settings()
      settings.mode = .remaining
      settings.resetTimeMode = .relative
      settings.timeFormat = timeFormat
      settings.claudeSource = .statuslineOnly
      settings.intervalSeconds = 900
      settings.codexPath = "/fake/bin/codex"
      let document = AccountDocument(accounts: [account()], settings: settings)
      try AccountStore(directory: directory).save(document)
      XCTAssertEqual(try AccountStore(directory: directory).load(), document)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
      XCTAssertEqual(object["timeFormat"] as? String, timeFormat.rawValue)
    }
  }
  func testLegacyDocumentsDefaultAppearancePreferences() throws {
    var settings = Settings()
    settings.mode = .remaining
    settings.codexPath = "/fake/bin/codex"
    let encoded = try JSONEncoder().encode(settings)
    let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(stored["colorMenuBarUsage"] as? Bool, false)
    XCTAssertEqual(stored["transparentPanel"] as? Bool, true)
    for value in [nil, NSNull()] as [Any?] {
      var object = stored
      object["colorMenuBarUsage"] = value
      object["transparentPanel"] = value
      let decoded = try JSONDecoder().decode(
        Settings.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertEqual(decoded, settings)
    }
    var custom = settings
    custom.colorMenuBarUsage = true
    custom.transparentPanel = false
    XCTAssertEqual(
      try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(custom)), custom)
    for key in ["colorMenuBarUsage", "transparentPanel"] {
      var object = stored
      object[key] = "yes"
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          Settings.self, from: JSONSerialization.data(withJSONObject: object)))
    }
  }
  func testUpdatedTimeModeDefaultsForLegacyDocumentsAndRoundtrips() throws {
    var settings = Settings()
    settings.resetTimeMode = .relative
    let encoded = try JSONEncoder().encode(settings)
    let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(stored["updatedTimeMode"] as? String, "absolute")
    for value in [nil, NSNull()] as [Any?] {
      var object = stored
      object["updatedTimeMode"] = value
      let decoded = try JSONDecoder().decode(
        Settings.self, from: JSONSerialization.data(withJSONObject: object))
      XCTAssertEqual(decoded, settings)
    }
    settings.updatedTimeMode = .relative
    XCTAssertEqual(
      try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
    for value in ["ago", 1, true] as [Any] {
      var object = stored
      object["updatedTimeMode"] = value
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          Settings.self, from: JSONSerialization.data(withJSONObject: object)))
    }
  }
  func testThemeDefaultsToSystemForLegacyDocumentsAndRejectsUnknownValues() throws {
    let stored = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any])
    XCTAssertEqual(stored["theme"] as? String, "system")
    for value in [nil, NSNull()] as [Any?] {
      var object = stored
      object["theme"] = value
      XCTAssertEqual(
        try JSONDecoder().decode(
          Settings.self, from: JSONSerialization.data(withJSONObject: object)
        ).theme, .system)
    }
    for theme in AppTheme.allCases {
      var settings = Settings()
      settings.theme = theme
      XCTAssertEqual(
        try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
    }
    for value in ["auto", "Dark", 1, false] as [Any] {
      var object = stored
      object["theme"] = value
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          Settings.self, from: JSONSerialization.data(withJSONObject: object)))
    }
  }
  func testSettingsRejectUnknownAndWrongTypeClockPreferences() throws {
    let encoded = try JSONEncoder().encode(Settings())
    for value in ["unknown", "hour13", 24, true, ["hour24"], ["invalid": true]] as [Any] {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      object["timeFormat"] = value
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          Settings.self, from: JSONSerialization.data(withJSONObject: object)))
    }
  }
  func testAccountAndSnapshotStoreRoundtripPreservesObservation() throws {
    let directory = try temporaryDirectory()
    var a = account()
    a.identityFingerprint = Paths.fingerprint("fake-store")
    var settings = Settings()
    settings.mode = .remaining
    settings.resetTimeMode = .relative
    settings.claudeSource = .statuslineOnly
    let document = AccountDocument(accounts: [a], settings: settings)
    try AccountStore(directory: directory).save(document)
    XCTAssertEqual(try AccountStore(directory: directory).load(), document)
    let states: [UUID: AccountState] = [
      a.id: .failed(.rateLimited, lastSuccess: snapshot(observedAt: now.addingTimeInterval(-7200)))
    ]
    try SnapshotStore(directory: directory).save(states)
    let restored = try SnapshotStore(directory: directory).load()
    XCTAssertEqual(restored, states)
    XCTAssertEqual(restored[a.id]?.lastSuccess?.observedAt, now.addingTimeInterval(-7200))
    XCTAssertTrue(restored[a.id]!.lastSuccess!.isStale(now: now))
  }
}
