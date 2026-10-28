import Darwin
import Foundation

/// A Unix socket in Application Support that `devdeck-hook` talks to. Each connection
/// carries one JSON line from the hook; for calls that wait, DevDeck answers with one JSON
/// line when it has decided. Only the user can connect (the socket is 0600).
final class BrokerServer: @unchecked Sendable {
    /// Keep in sync with Sources/devdeck-hook/main.swift.
    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevDeck/broker.sock")
    }

    private let queue = DispatchQueue(label: "DevDeck.broker")
    private let listener: Int32
    private let source: DispatchSourceRead
    /// The socket file's inode, to notice when something else replaced or removed it.
    private let inode: ino_t
    private let handler: @Sendable (Data, BrokerConnection) -> Void

    init?(handler: @escaping @Sendable (Data, BrokerConnection) -> Void) {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(url.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 64) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            close(fd)
            return nil
        }

        inode = info.st_ino
        listener = fd
        self.handler = handler
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
        if !isStale { unlink(Self.socketURL.path) }
    }

    /// The socket file is gone or belongs to someone else, so hooks can't reach us.
    var isStale: Bool {
        var info = stat()
        return stat(Self.socketURL.path, &info) != 0 || info.st_ino != inode
    }

    private func acceptAll() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            // Accepted sockets inherit O_NONBLOCK; read the request with a short timeout.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var nosigpipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

            // One line (older hooks just close after writing, which ends it too).
            var data = Data()
            var byte: UInt8 = 0
            while data.count < 1 << 20, read(client, &byte, 1) == 1, byte != 0x0A {
                data.append(byte)
            }
            let connection = BrokerConnection(fd: client, queue: queue)
            if data.isEmpty {
                connection.close()
            } else {
                handler(data, connection)
            }
        }
    }
}

/// One hook connection, kept open while its call waits for an answer.
final class BrokerConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var closed = false
    private var hangupSource: DispatchSourceRead?

    fileprivate init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    /// Sends the answer line and closes the connection.
    func respond(_ json: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: json) else { return close() }
        line.append(0x0A)
        queue.async { [self] in
            guard !closed else { return }
            line.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            closeNow()
        }
    }

    func close() {
        queue.async { [self] in closeNow() }
    }

    /// Calls `handler` if the hook goes away before it gets an answer (the agent was
    /// interrupted, or the hook timed out).
    func onHangup(_ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, !self.closed else { return }
                var buffer = [UInt8](repeating: 0, count: 256)
                let count = recv(self.fd, &buffer, buffer.count, MSG_DONTWAIT)
                // 0 is end of file; anything the hook sends after its line is ignored.
                if count == 0 || (count < 0 && errno != EAGAIN) {
                    self.closeNow()
                    handler()
                }
            }
            source.resume()
            hangupSource = source
        }
    }

    private func closeNow() {
        guard !closed else { return }
        closed = true
        hangupSource?.cancel()
        hangupSource = nil
        Darwin.close(fd)
    }
}
