import Darwin
import XCTest
@testable import DevDeck

final class LibProcTests: XCTestCase {
    /// What the scans read about this test process: its row, a socket it listens on and a
    /// connection to it, and its working directory.
    func testReadsThisProcess() throws {
        let pid = getpid()
        let row = try XCTUnwrap(LibProc.processTable()[pid])
        XCTAssertEqual(row.ppid, getppid())
        XCTAssertTrue(row.command.hasPrefix(CommandLine.arguments[0]), row.command)

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(listener, $0, length), 0)
                XCTAssertEqual(Darwin.listen(listener, 1), 0)
                XCTAssertEqual(getsockname(listener, $0, &length), 0)
            }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)), 0)
            }
        }

        XCTAssertEqual(LibProc.listeningPorts([pid])[pid], [port])
        XCTAssertEqual(LibProc.connections([pid], to: [port])[pid], [port])
        XCTAssertEqual(LibProc.workingDirectories([pid])[pid], FileManager.default.currentDirectoryPath)
    }
}
