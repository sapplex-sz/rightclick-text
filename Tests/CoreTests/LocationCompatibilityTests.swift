import XCTest
@testable import RightClickTextCore

final class LocationCompatibilityTests: XCTestCase {
    func testRecognizesICloudStorageRootAndDescendants() {
        for path in [
            "/Users/example/Library/Mobile Documents",
            "/Users/example/Library/Mobile Documents/",
            "/Users/example/Library/Mobile Documents/com~apple~CloudDocs",
            "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/开发/右键新文本",
            "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/Desktop"
        ] {
            XCTAssertEqual(LocationCompatibility.classify(path: path), .iCloudDrive, path)
        }
    }

    func testRecognizesFileProviderRootAndDescendants() {
        for path in [
            "/Users/example/Library/CloudStorage",
            "/Users/example/Library/CloudStorage/",
            "/Users/example/Library/CloudStorage/Dropbox",
            "/Users/example/Library/CloudStorage/OneDrive-Personal/Documents",
            "/Users/example/Library/CloudStorage/GoogleDrive-user@example.com/My Drive"
        ] {
            XCTAssertEqual(LocationCompatibility.classify(path: path), .fileProvider, path)
        }
    }

    func testClassificationIsIndependentOfCurrentUserHome() {
        for user in ["alice", "bob", "user with spaces", "张三"] {
            XCTAssertEqual(LocationCompatibility.classify(path: "/Users/\(user)/Library/Mobile Documents/com~apple~CloudDocs"), .iCloudDrive)
            XCTAssertEqual(LocationCompatibility.classify(path: "/Users/\(user)/Library/CloudStorage/Dropbox"), .fileProvider)
            XCTAssertEqual(LocationCompatibility.classify(path: "/Users/\(user)/Documents"), .standard)
        }
    }

    func testSimilarNamesAndNestedImitationsAreStandard() {
        for path in [
            "/Users/alice/Library/Mobile Documents Backup",
            "/Users/alice/Library/Mobile Documents.old/com~apple~CloudDocs",
            "/Users/alice/Library/CloudStorageBackup/Dropbox",
            "/Users/alice/Library/CloudStorage.old/Dropbox",
            "/Users/alice/Documents/Mobile Documents",
            "/Users/alice/Documents/CloudStorage",
            "/Users/alice/Library/Backups/Mobile Documents",
            "/Users/alice/Documents/Users/bob/Library/Mobile Documents",
            "/Volumes/Backup/Users/alice/Library/CloudStorage/Dropbox",
            "/UsersBackup/alice/Library/Mobile Documents",
            "/Users/alice/LibraryBackup/CloudStorage",
            "/Users/alice/Library/Mobile%20Documents",
            "/Users/alice/Desktop",
            "/Users/alice/Documents",
            "/Users/alice/Downloads"
        ] {
            XCTAssertEqual(LocationCompatibility.classify(path: path), .standard, path)
        }
    }

    func testLexicalNormalizationDoesNotMisclassifyEscapedCloudPaths() {
        XCTAssertEqual(LocationCompatibility.classify(path: "/Users/alice/Library/Mobile Documents/../Caches"), .standard)
        XCTAssertEqual(LocationCompatibility.classify(path: "/Users/alice/Library/CloudStorage/../../Documents"), .standard)
        XCTAssertEqual(LocationCompatibility.classify(path: "/Users/alice/Library/Mobile Documents/../CloudStorage/Dropbox"), .fileProvider)
        XCTAssertEqual(LocationCompatibility.classify(path: "/Users/alice/Library/./Mobile Documents/com~apple~CloudDocs"), .iCloudDrive)
        XCTAssertEqual(LocationCompatibility.classify(path: "/Users//alice/Library//CloudStorage/Dropbox/"), .fileProvider)
    }

    func testInvalidRelativeAndIncompletePathsAreStandard() {
        for path in [
            "", "/", "/Users", "/Users/alice", "/Users/alice/Library",
            "Users/alice/Library/Mobile Documents",
            "~/Library/CloudStorage/Dropbox",
            "/Users/alice/Library/Mobile Documents\0/com~apple~CloudDocs",
            "/Users/alice/Library/CloudStorage/Dropbox\0",
            "file:///Users/alice/Library/Mobile%20Documents"
        ] {
            XCTAssertEqual(LocationCompatibility.classify(path: path), .standard, path)
        }
    }
}
