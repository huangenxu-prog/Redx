import Foundation
import Security
import Darwin

enum ADBError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
private extension Data {
    mutating func word(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    func wordAt(_ i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i+1]) << 8 | UInt32(self[i+2]) << 16 | UInt32(self[i+3]) << 24
    }
}
private func tag(_ s: String) -> UInt32 { Data(s.utf8).wordAt(0) }
private struct Packet {
    let cmd: UInt32
    let a: UInt32
    let b: UInt32
    let data: Data
}
private final class Identity {
    let key: SecKey
    init() throws {
        let t = Data("com.xiaoxiao.adbx.rsa".utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: t, kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecReturnRef as String: true]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let found { key = found as! SecKey; return }
        guard status == errSecItemNotFound else { throw ADBError.message("Keychain error: \(status)") }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048, kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: t]]
        guard let generated = SecKeyCreateRandomKey(attrs as CFDictionary, nil) else { throw ADBError.message("RSA key generation failed") }
        key = generated
    }
    func sign(_ data: Data) throws -> Data {
        guard data.count == 20, let signature = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1, data as CFData, nil) else { throw ADBError.message("ADB signature failed") }
        return signature as Data
    }
    func publicPacket() throws -> Data {
        guard let pub = SecKeyCopyPublicKey(key), let raw = SecKeyCopyExternalRepresentation(pub, nil) else { throw ADBError.message("RSA public key unavailable") }
        let bytes = Array(raw as Data)
        var i = 0
        func field(_ expected: UInt8) throws -> [UInt8] {
            guard i+2 <= bytes.count, bytes[i] == expected else { throw ADBError.message("Invalid RSA DER") }
            i += 1
            var count = Int(bytes[i]); i += 1
            if count & 128 != 0 {
                let n = count & 127; count = 0
                guard n > 0, n <= 4, i+n <= bytes.count else { throw ADBError.message("Invalid DER length") }
                for _ in 0..<n { count = count*256 + Int(bytes[i]); i += 1 }
            }
            guard count <= bytes.count-i else { throw ADBError.message("Truncated RSA DER") }
            let result = Array(bytes[i..<i+count]); i += count; return result
        }
        _ = try field(0x30)
        i = 1
        let lengthByte = Int(bytes[i]); i += 1
        if lengthByte & 128 != 0 { i += lengthByte & 127 }
        var modulus = try field(2)
        while modulus.first == 0 { modulus.removeFirst() }
        let exp = try field(2)
        guard modulus.count == 256, exp.count <= 4 else { throw ADBError.message("Unsupported RSA size") }
        let little = Data(modulus.reversed())
        let n = (0..<64).map { little.wordAt($0*4) }
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- n[0] &* inverse) }
        var rr = [UInt32](repeating: 0, count: 64); rr[0] = 1
        for _ in 0..<4096 {
            var carry: UInt32 = 0
            for j in 0..<64 {
                let next = rr[j] >> 31
                rr[j] = (rr[j] << 1) | carry; carry = next
            }
            var ge = true
            for j in (0..<64).reversed() {
                if rr[j] != n[j] { ge = rr[j] > n[j]; break }
            }
            if carry != 0 || ge {
                var borrow: UInt64 = 0
                for j in 0..<64 {
                    let a = UInt64(rr[j]); let b = UInt64(n[j]) + borrow
                    rr[j] = UInt32(truncatingIfNeeded: a &- b); borrow = a < b ? 1 : 0
                }
            }
        }
        var out = Data(); out.word(64); out.word(0 &- inverse)
        for x in n { out.word(x) }; for x in rr { out.word(x) }
        out.word(exp.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        return Data((out.base64EncodedString() + " ADBX@iPhone\0").utf8)
    }
}

final class ADB {
    private var fd: Int32 = -1
    private var nextID: UInt32 = 1
    private var version: UInt32 = 0x01000000
    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 }; version = 0x01000000 }
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < p.count {
                let count = Darwin.send(fd, p.baseAddress!.advanced(by: offset), p.count-offset, 0)
                guard count > 0 else { throw ADBError.message("Connection write failed") }
                offset += count
            }
        }
    }
    private func read(_ count: Int) throws -> Data {
        var d = Data(count: count)
        try d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < count {
                let n = Darwin.recv(fd, p.baseAddress!.advanced(by: offset), count-offset, 0)
                guard n > 0 else { throw ADBError.message("Connection closed or timed out") }
                offset += n
            }
        }
        return d
    }
    private func send(_ cmd: String, _ a: UInt32, _ b: UInt32, _ data: Data = Data()) throws {
        var packet = Data(); let c = tag(cmd)
        packet.word(c); packet.word(a); packet.word(b); packet.word(UInt32(data.count))
        packet.word(version >= 0x01000001 ? 0 : data.reduce(UInt32(0)) { $0 &+ UInt32($1) })
        packet.word(~c); packet.append(data); try writeAll(packet)
    }
    private func receive() throws -> Packet {
        let h = try read(24); let c = h.wordAt(0); let size = Int(h.wordAt(12))
        guard h.wordAt(20) == ~c, size <= 1024*1024 else { throw ADBError.message("Invalid ADB packet") }
        let d = try read(size)
        if version < 0x01000001 && c != tag("CNXN") && h.wordAt(16) != d.reduce(UInt32(0), { $0 &+ UInt32($1) }) { throw ADBError.message("ADB checksum mismatch") }
        return Packet(cmd: c, a: h.wordAt(4), b: h.wordAt(8), data: d)
    }
    func connect(host: String, port: UInt16) throws {
        close()
        do {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { throw ADBError.message("Invalid host") }
            defer { freeaddrinfo(first) }
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let item = current {
                let a = item.pointee; current = a.ai_next
                let s = socket(a.ai_family, a.ai_socktype, a.ai_protocol)
                if s < 0 { continue }
                var one: Int32 = 1
                _ = setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(s, F_SETFL, O_NONBLOCK)
                let rc = Darwin.connect(s, a.ai_addr, a.ai_addrlen)
                var ok = rc == 0
                if !ok && errno == EINPROGRESS {
                    var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                    if poll(&p, 1, 5000) > 0 {
                        var error: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
                        ok = getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &len) == 0 && error == 0
                    }
                }
                if ok {
                    _ = fcntl(s, F_SETFL, 0)
                    var timeout = timeval(tv_sec: 60, tv_usec: 0)
                    _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    _ = setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    fd = s; break
                }
                Darwin.close(s)
            }
            guard fd >= 0 else { throw ADBError.message("无法连接电视，请检查 IP、端口和 ADB 开关") }
            try send("CNXN", 0x01000000, 4096, Data("host::\0".utf8))
            var attempts = 0
            while attempts < 3 {
                let p = try receive()
                if p.cmd == tag("CNXN") { version = min(p.a, 0x01000000); return }
                guard p.cmd == tag("AUTH"), p.a == 1 else { throw ADBError.message("电视不支持传统 ADB，可能需要无线配对") }
                let identity = try Identity()
                if attempts == 0 { try send("AUTH", 2, 0, identity.sign(p.data)) }
                else if attempts == 1 { try send("AUTH", 3, 0, identity.publicPacket()) }
                else { throw ADBError.message("电视拒绝 ADB 授权") }
                attempts += 1
            }
            throw ADBError.message("ADB authentication failed")
        } catch { close(); throw error }
    }
    func shell(_ command: String) throws -> String {
        guard fd >= 0 else { throw ADBError.message("未连接电视") }
        let local = nextID; nextID &+= 1
        do {
            try send("OPEN", local, 0, Data(("shell:" + command + "\0").utf8))
            var output = Data()
            var remote: UInt32 = 0
            while true {
                let p = try receive()
                guard p.b == local else { throw ADBError.message("Unexpected ADB stream") }
                if p.cmd == tag("OKAY") { remote = p.a }
                else if p.cmd == tag("WRTE") {
                    remote = p.a
                    guard output.count + p.data.count <= 4*1024*1024 else { throw ADBError.message("Output too large") }
                    output.append(p.data); try send("OKAY", local, remote)
                } else if p.cmd == tag("CLSE") {
                    if remote != 0 { try send("CLSE", local, remote) }
                    return String(decoding: output, as: UTF8.self)
                } else { throw ADBError.message("Unexpected ADB response") }
            }
        } catch { close(); throw error }
    }
}
