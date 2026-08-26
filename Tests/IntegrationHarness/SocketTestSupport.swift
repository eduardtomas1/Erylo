import Darwin
@_spi(Testing) import EryloLocalIntegrations
import Foundation

let privateObjectACLAllowPermissions: [(name: String, permission: acl_perm_t)] = [
    ("write-data", ACL_WRITE_DATA),
    ("write-attributes", ACL_WRITE_ATTRIBUTES),
    ("write-extended-attributes", ACL_WRITE_EXTATTRIBUTES),
    ("write-security", ACL_WRITE_SECURITY),
    ("change-owner", ACL_CHANGE_OWNER),
]

extension IntegrationHarness {
    func waitUntil(
        milliseconds: Int = 2_000,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    func completesWithin(
        milliseconds: Int,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = WallClockCompletionGate(continuation: continuation)
            Task.detached {
                await operation()
                gate.resolve(true)
            }
            Task.detached {
                try? await ContinuousClock().sleep(for: .milliseconds(milliseconds))
                gate.resolve(false)
            }
        }
    }

    func temporaryRoot(_ suffix: String) -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("EryloIntegrationHarness-\(getpid())-\(suffix)", isDirectory: true)
    }

    func removeIfPresent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func mode(at url: URL) -> mode_t? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        return metadata.st_mode & 0o777
    }

    func owner(at url: URL) -> uid_t? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        return metadata.st_uid
    }

    func openDescriptorCount() -> Int {
        (0..<getdtablesize()).reduce(into: 0) { count, descriptor in
            if fcntl(descriptor, F_GETFD) >= 0 { count += 1 }
        }
    }

    func applyEveryoneACL(
        to url: URL,
        tag: acl_tag_t,
        permissions: [acl_perm_t],
        flags: [acl_flag_t] = []
    ) throws {
        try applyTestEveryoneACL(to: url, tag: tag, permissions: permissions, flags: flags)
    }

    func aclAllows(_ permission: acl_perm_t, at url: URL) -> Bool {
        testACLContains(tag: ACL_EXTENDED_ALLOW, permission: permission, at: url)
    }

    func clearACL(at url: URL) {
        clearTestACL(at: url)
    }

    func connect(
        to socketURL: URL,
        receiveBufferBytes: Int32? = nil,
        observeReceiveBufferBeforeConnect: (Int32) -> Void = { _ in }
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HarnessError.systemCall("socket", errno) }
        do {
            var enabled: Int32 = 1
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0,
                  setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    &timeout,
                    socklen_t(MemoryLayout<timeval>.size)
                  ) == 0 else {
                throw HarnessError.systemCall("setsockopt", errno)
            }
            if var receiveBufferBytes {
                guard receiveBufferBytes > 0,
                      setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_RCVBUF,
                        &receiveBufferBytes,
                        socklen_t(MemoryLayout<Int32>.size)
                      ) == 0 else {
                    throw HarnessError.systemCall("setsockopt", errno)
                }
                observeReceiveBufferBeforeConnect(try self.receiveBufferBytes(for: descriptor))
            }

            var address = sockaddr_un()
            let bytes = Array(socketURL.path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw HarnessError.invalidURL
            }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { storage in
                storage.initializeMemory(as: UInt8.self, repeating: 0)
                storage.copyBytes(from: bytes)
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw HarnessError.systemCall("connect", errno) }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func receiveBufferBytes(for descriptor: Int32) throws -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &value, &length) == 0 else {
            throw HarnessError.systemCall("getsockopt", errno)
        }
        return value
    }

    func createStaleSocketNode(at socketURL: URL) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HarnessError.systemCall("socket", errno) }
        defer { _ = Darwin.close(descriptor) }

        var address = sockaddr_un()
        let bytes = Array(socketURL.path.utf8)
        guard !bytes.isEmpty,
              bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HarnessError.invalidURL
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            storage.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw HarnessError.systemCall("bind", errno) }
        guard chmod(socketURL.path, 0o600) == 0 else {
            throw HarnessError.systemCall("chmod", errno)
        }
    }

    func readResponse(from descriptor: Int32) throws -> ActivityIntegrationResponse {
        let prefix = try readExactly(4, from: descriptor)
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(ActivityIntegrationAPI.maximumResponseBodyBytes) else {
            throw HarnessError.invalidFrame
        }
        let body = try readExactly(Int(length), from: descriptor)
        return try JSONDecoder().decode(ActivityIntegrationResponse.self, from: body)
    }

    func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var output = Data(count: count)
        var received = 0
        try output.withUnsafeMutableBytes { storage in
            guard let baseAddress = storage.baseAddress else { throw HarnessError.invalidFrame }
            while received < count {
                let result = Darwin.recv(
                    descriptor,
                    baseAddress.advanced(by: received),
                    count - received,
                    0
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw HarnessError.systemCall("recv", errno)
                }
                guard result > 0 else { throw HarnessError.invalidFrame }
                received += result
            }
        }
        return output
    }

    func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { storage in
            guard let baseAddress = storage.baseAddress else { throw HarnessError.invalidFrame }
            var sent = 0
            while sent < storage.count {
                let result = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sent),
                    storage.count - sent,
                    0
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw HarnessError.systemCall("send", errno)
                }
                guard result > 0 else { throw HarnessError.invalidFrame }
                sent += result
            }
        }
    }

    func requestFrame(_ json: String) throws -> Data {
        try LengthPrefixedFrameDecoder.encode(
            Data(json.utf8),
            maximumBodyBytes: ActivityIntegrationAPI.maximumRequestBodyBytes
        )
    }

    func framePrefix(_ length: UInt32) -> Data {
        Data([
            UInt8(length >> 24), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
    }
}

func clearTestACL(at url: URL) {
    guard let accessControlList = acl_init(0) else { return }
    _ = acl_set_file(url.path, ACL_TYPE_EXTENDED, accessControlList)
    _ = acl_free(UnsafeMutableRawPointer(accessControlList))
}

func testACLContains(tag expectedTag: acl_tag_t, permission: acl_perm_t, at url: URL) -> Bool {
    guard let accessControlList = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
        return false
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(accessControlList)) }
    var entryIdentifier = ACL_FIRST_ENTRY.rawValue
    while true {
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(accessControlList, entryIdentifier, &entry)
        if result != 0, errno == EINVAL { return false }
        guard result == 0, let entry else { return false }
        var tag = ACL_UNDEFINED_TAG
        var permissionSet: acl_permset_t?
        guard acl_get_tag_type(entry, &tag) == 0,
              acl_get_permset(entry, &permissionSet) == 0,
              let permissionSet else { return false }
        if tag == expectedTag, acl_get_perm_np(permissionSet, permission) == 1 {
            return true
        }
        entryIdentifier = ACL_NEXT_ENTRY.rawValue
    }
}

func testACLAllows(_ permission: acl_perm_t, at url: URL) -> Bool {
    testACLContains(tag: ACL_EXTENDED_ALLOW, permission: permission, at: url)
}

func applyTestEveryoneACL(
    to url: URL,
    tag: acl_tag_t,
    permissions: [acl_perm_t],
    flags: [acl_flag_t] = []
) throws {
    guard let initialAccessControlList = acl_init(1) else {
        throw HarnessError.systemCall("acl_init", errno)
    }
    var accessControlList: acl_t? = initialAccessControlList
    defer {
        if let accessControlList {
            _ = acl_free(UnsafeMutableRawPointer(accessControlList))
        }
    }
    var entry: acl_entry_t?
    guard acl_create_entry(&accessControlList, &entry) == 0,
          let entry,
          acl_set_tag_type(entry, tag) == 0 else {
        throw HarnessError.systemCall("acl_create_entry", errno)
    }
    var everyoneUUID = UUID(
        uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C"
    )!.uuid
    guard acl_set_qualifier(entry, &everyoneUUID) == 0 else {
        throw HarnessError.systemCall("acl_set_qualifier", errno)
    }
    var permissionSet: acl_permset_t?
    guard acl_get_permset(entry, &permissionSet) == 0,
          let permissionSet,
          acl_clear_perms(permissionSet) == 0 else {
        throw HarnessError.systemCall("acl_get_permset", errno)
    }
    for permission in permissions {
        guard acl_add_perm(permissionSet, permission) == 0 else {
            throw HarnessError.systemCall("acl_add_perm", errno)
        }
    }
    var flagSet: acl_flagset_t?
    guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flagSet) == 0,
          let flagSet,
          acl_clear_flags_np(flagSet) == 0 else {
        throw HarnessError.systemCall("acl_get_flagset_np", errno)
    }
    for flag in flags {
        guard acl_add_flag_np(flagSet, flag) == 0 else {
            throw HarnessError.systemCall("acl_add_flag_np", errno)
        }
    }
    guard let accessControlList,
          acl_set_file(url.path, ACL_TYPE_EXTENDED, accessControlList) == 0 else {
        throw HarnessError.systemCall("acl_set_file", errno)
    }
}

private final class WallClockCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ result: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

final class SocketConnectFlood: @unchecked Sendable {
    private let lock = NSLock()
    private let socketURL: URL
    private var stopped = false
    private var attempts = 0

    init(socketURL: URL) {
        self.socketURL = socketURL
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func run() {
        while !Task.isCancelled {
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            attempts += 1
            lock.unlock()
            attemptNonblockingConnect(to: socketURL)
        }
    }

    private func attemptNonblockingConnect(to socketURL: URL) {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return }

        var address = sockaddr_un()
        let bytes = Array(socketURL.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            storage.copyBytes(from: bytes)
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

final class WakeWriteScript: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [UnixSocketIntegrationTestingWakeWriteResult]
    private var calls = 0

    init(_ results: [UnixSocketIntegrationTestingWakeWriteResult]) {
        self.results = results
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func next() -> UnixSocketIntegrationTestingWakeWriteResult {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return results.isEmpty ? .written : results.removeFirst()
    }
}

final class CapturedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURL: URL?

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedURL
    }

    func capture(_ url: URL) {
        lock.lock()
        storedURL = url
        lock.unlock()
    }
}

final class CapturedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func capture(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

final class WeakSocketServiceReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedValue: UnixSocketActivityIntegrationService?

    init(_ value: UnixSocketActivityIntegrationService) {
        storedValue = value
    }

    var value: UnixSocketActivityIntegrationService? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

struct RejectAllPeers: UnixSocketPeerValidating {
    func allows(socketDescriptor: Int32, expectedEffectiveUserID: uid_t) -> Bool {
        _ = socketDescriptor
        _ = expectedEffectiveUserID
        return false
    }
}
