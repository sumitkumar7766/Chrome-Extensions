import Darwin
import Foundation

/// Secure local Unix domain socket server bridging the Swift macOS helper with `pingglass_native_host.py`.
/// Uses 4-byte little-endian length-prefixed UTF-8 JSON framing matching Chrome's Native Messaging protocol.
public final class NativeMessagingServer: @unchecked Sendable {
    public static let maxPayloadBytes = 1_048_576

    /// Default user-private socket path: `~/.pingglass/bridge.sock` (kept short to stay well under macOS sun_path 104-byte limit).
    public static func defaultSocketURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pingglass", isDirectory: true)
            .appendingPathComponent("bridge.sock", isDirectory: false)
    }

    private let socketURL: URL
    private let ioQueue = DispatchQueue(label: "com.pingglass.ipc.server", qos: .utility)
    private let clientsLock = NSLock()

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: ClientConnection] = [:]

    public var onEnvelopeReceived: ((BridgeEnvelope) -> Void)?
    public var onClientCountChanged: ((Int) -> Void)?

    private final class ClientConnection {
        let fd: Int32
        let readSource: DispatchSourceRead
        var readBuffer = Data()

        init(fd: Int32, readSource: DispatchSourceRead) {
            self.fd = fd
            self.readSource = readSource
        }
    }

    public init(socketURL: URL = NativeMessagingServer.defaultSocketURL()) {
        self.socketURL = socketURL
    }

    deinit {
        stop()
    }

    /// Starts listening on the local Unix domain socket with `0700` directory and `0600` socket permissions.
    public func start() throws {
        let dirURL = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(dirURL.path, 0o700)

        unlink(socketURL.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Set non-blocking mode for DispatchSource async I/O.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(
                domain: "PingGlassIPC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path exceeds macOS sun_path limit."]
            )
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { sunPathPtr in
            for (index, byte) in pathBytes.enumerated() {
                sunPathPtr[index] = UInt8(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }

        guard bindResult == 0 else {
            let errCode = Int(errno)
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: errCode)
        }

        chmod(socketURL.path, 0o600)

        guard Darwin.listen(fd, 8) == 0 else {
            let errCode = Int(errno)
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: errCode)
        }

        serverFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverFD, fd >= 0 {
                close(fd)
                self?.serverFD = -1
            }
        }
        acceptSource = source
        source.resume()
    }

    /// Stops the server, closes connected clients, and unlinks the socket file.
    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil

        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }

        clientsLock.lock()
        let activeClients = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()

        for client in activeClients {
            client.readSource.cancel()
        }

        unlink(socketURL.path)
        notifyClientCount(0)
    }

    public var connectedClientCount: Int {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        return clients.count
    }

    /// Encodes and broadcasts a `BridgeEnvelope` to all authenticated local clients.
    public func broadcast(_ envelope: BridgeEnvelope) {
        guard let framedData = Self.encodeFrame(envelope) else {
            return
        }

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.clientsLock.lock()
            let targets = Array(self.clients.values)
            self.clientsLock.unlock()

            for client in targets {
                if !self.writeAll(fd: client.fd, data: framedData) {
                    self.disconnectClient(fd: client.fd)
                }
            }
        }
    }

    // MARK: - Framing Helpers (Exposed for unit tests)

    public static func encodeFrame(_ envelope: BridgeEnvelope) -> Data? {
        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(envelope),
              jsonData.count <= maxPayloadBytes else {
            return nil
        }
        var lengthLE = UInt32(jsonData.count).littleEndian
        var frame = Data(bytes: &lengthLE, count: 4)
        frame.append(jsonData)
        return frame
    }

    public static func decodeFrames(from buffer: inout Data) -> [BridgeEnvelope] {
        var decoded: [BridgeEnvelope] = []
        let decoder = JSONDecoder()

        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { rawPtr -> UInt32 in
                rawPtr.loadUnaligned(as: UInt32.self).littleEndian
            }
            if length == 0 || length > UInt32(maxPayloadBytes) {
                buffer.removeAll(keepingCapacity: false)
                break
            }

            let totalNeeded = 4 + Int(length)
            guard buffer.count >= totalNeeded else {
                break // wait for remaining bytes (partial read)
            }

            let payloadSlice = buffer.subdata(in: 4..<totalNeeded)
            buffer.removeSubrange(0..<totalNeeded)

            if let envelope = try? decoder.decode(BridgeEnvelope.self, from: payloadSlice) {
                decoded.append(envelope)
            }
        }

        return decoded
    }

    // MARK: - Socket Internals

    private func acceptPendingConnections() {
        guard serverFD >= 0 else { return }

        while true {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(serverFD, sockPtr, &len)
                }
            }

            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    break
                }
                break
            }

            // Enforce same-UID local peer verification using BSD getpeereid.
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
                close(clientFD)
                continue
            }

            let flags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            let readSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: ioQueue)
            let connection = ClientConnection(fd: clientFD, readSource: readSource)

            readSource.setEventHandler { [weak self] in
                self?.readFromClient(connection)
            }
            readSource.setCancelHandler {
                close(clientFD)
            }

            clientsLock.lock()
            clients[clientFD] = connection
            let count = clients.count
            clientsLock.unlock()

            readSource.resume()
            notifyClientCount(count)
        }
    }

    private func readFromClient(_ connection: ClientConnection) {
        var tempBuffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let bytesRead = Darwin.read(connection.fd, &tempBuffer, tempBuffer.count)
            if bytesRead > 0 {
                connection.readBuffer.append(contentsOf: tempBuffer[0..<bytesRead])
                let envelopes = Self.decodeFrames(from: &connection.readBuffer)
                for envelope in envelopes {
                    onEnvelopeReceived?(envelope)
                }
            } else if bytesRead == 0 {
                disconnectClient(fd: connection.fd)
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EINTR {
                    continue
                }
                disconnectClient(fd: connection.fd)
                return
            }
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        var totalWritten = 0
        let totalCount = data.count

        return data.withUnsafeBytes { rawBuffer -> Bool in
            guard let basePtr = rawBuffer.baseAddress else { return false }
            while totalWritten < totalCount {
                let written = Darwin.write(fd, basePtr.advanced(by: totalWritten), totalCount - totalWritten)
                if written > 0 {
                    totalWritten += written
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(1000)
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func disconnectClient(fd: Int32) {
        clientsLock.lock()
        let removed = clients.removeValue(forKey: fd)
        let count = clients.count
        clientsLock.unlock()

        if let removed {
            removed.readSource.cancel()
            notifyClientCount(count)
        }
    }

    private func notifyClientCount(_ count: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.onClientCountChanged?(count)
        }
    }
}
