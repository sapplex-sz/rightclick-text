import XCTest
@testable import RightClickTextCore

final class ServiceDirectoryPolicyTests: XCTestCase {
    func testConfiguredFolderAndDescendantsOnly() {
        let roots = ["/Users/me/iCloud/工作", "/Volumes/外置磁盘"]
        XCTAssertTrue(ServiceDirectoryPolicy.allows(canonicalDirectory: roots[0], configuredPaths: roots))
        XCTAssertTrue(ServiceDirectoryPolicy.allows(canonicalDirectory: roots[0] + "/空 文件夹", configuredPaths: roots))
        XCTAssertFalse(ServiceDirectoryPolicy.allows(canonicalDirectory: roots[0] + "副本", configuredPaths: roots))
        XCTAssertFalse(ServiceDirectoryPolicy.allows(canonicalDirectory: "/Users/me/iCloud", configuredPaths: roots))
        XCTAssertFalse(ServiceDirectoryPolicy.allows(canonicalDirectory: "/Users/me/iCloud/其他", configuredPaths: roots))
    }

    func testRemovalAndCanonicalSymlinkEscapeAreDenied() {
        XCTAssertFalse(ServiceDirectoryPolicy.allows(canonicalDirectory: "/allowed/sub", configuredPaths: []))
        // The worker resolves the actual filesystem path first. A link leading out
        // of the configured folder must not be allowed by its original spelling.
        XCTAssertFalse(ServiceDirectoryPolicy.allows(canonicalDirectory: "/outside", configuredPaths: ["/allowed"]))
    }

    func testMalformedUnboundedAndTraversalInputsFailClosed() {
        for bad in ["", "relative", "~/folder", "/allowed/../outside", "/allowed/./sub",
                    "/allowed//sub", "/allowed/", "/allowed\0evil", "/" + String(repeating: "x", count: 16384)] {
            XCTAssertFalse(ServiceDirectoryPolicy.allows(canonicalDirectory: bad, configuredPaths: ["/"]))
            XCTAssertFalse(ServiceDirectoryPolicy.allows(canonicalDirectory: "/allowed/sub", configuredPaths: [bad]))
        }
        XCTAssertFalse(ServiceDirectoryPolicy.allows(canonicalDirectory: "/allowed", configuredPaths: Array(repeating: "/allowed", count: 1025)))
    }
}
