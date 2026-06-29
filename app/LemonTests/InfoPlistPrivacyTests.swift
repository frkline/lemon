@testable import Lemon
import XCTest

/// Guards the deliberate omission of personal-data TCC usage descriptions from
/// `Info.plist` (#86). Lemon never legitimately touches the user's Downloads,
/// Photos, Music, etc.; shipping a usage string for one would turn a runaway
/// session's stray `find ~` into an "Allow" prompt that grants permanent access.
/// With no usage string, macOS denies the access outright. This test fails the
/// build if any of those keys is ever (re)introduced.
final class InfoPlistPrivacyTests: XCTestCase {
    /// `NS*UsageDescription` keys whose mere presence makes macOS *prompt* (and,
    /// on "Allow", permanently grant) access to a personal-data domain Lemon must
    /// never reach. Keep in sync with the comment in `app/Lemon/Info.plist`.
    private static let forbiddenKeys = [
        "NSDownloadsFolderUsageDescription",
        "NSDesktopFolderUsageDescription",
        "NSDocumentsFolderUsageDescription",
        "NSPhotoLibraryUsageDescription",
        "NSPhotoLibraryAddUsageDescription",
        "NSAppleMusicUsageDescription",
        "NSCameraUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSContactsUsageDescription",
        "NSCalendarsUsageDescription",
        "NSRemindersUsageDescription",
    ]

    func testInfoPlistShipsNoPersonalDataUsageDescriptions() throws {
        let plist = try loadSourceInfoPlist()
        for key in Self.forbiddenKeys where plist[key] != nil {
            XCTFail("""
            Info.plist must not declare \(key): Lemon never touches that personal-data \
            domain, and declaring it turns a stray session traversal into a one-click \
            permanent grant (#86). Remove the key so macOS denies the access outright.
            """)
        }
    }

    /// Loads the checked-in `app/Lemon/Info.plist` directly (the artifact we're
    /// guarding), located relative to this test source file so it's independent of
    /// how the test/app bundle is packaged.
    private func loadSourceInfoPlist() throws -> [String: Any] {
        let plistURL = URL(fileURLWithPath: #filePath) // .../app/LemonTests/InfoPlistPrivacyTests.swift
            .deletingLastPathComponent() // .../app/LemonTests
            .deletingLastPathComponent() // .../app
            .appendingPathComponent("Lemon/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(parsed as? [String: Any], "Info.plist is not a dictionary")
    }
}
