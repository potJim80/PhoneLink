// Two small listeners on the home network:
//   http  :8580 — the setup page and the certificate download (works before the phone trusts us)
//   https :8581 — the Phone Link page itself and its WebSocket (/ws) carrying the audio
// One phone at a time: a new WebSocket replaces the old one.
import Foundation
import Network
import CryptoKit

final class Server {
    static let httpPort: UInt16 = 8580, httpsPort: UInt16 = 8581

    var httpFiles: [String: (Data, String)] = [:]   // path → (body, content type)
    var httpsFiles: [String: (Data, String)] = [:]
    var onPhoneConnected: ((String) -> Void)?       // remote address
    var onPhoneDisconnected: (() -> Void)?
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "phonelink.net", qos: .userInteractive)
    private var listeners: [NWListener] = []
    private var phone: Conn?
    private var conns: [ObjectIdentifier: Conn] = [:]   // keeps open connections alive (net queue only)

    func start(identity: SecIdentity) throws {
        listeners = [try listen(port: Self.httpPort, tls: nil), try listen(port: Self.httpsPort, tls: identity)]
    }

    func stop() { listeners.forEach { $0.cancel() }; listeners = []; phone?.close() }

    private func listen(port: UInt16, tls identity: SecIdentity?) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        var tlsOpts: NWProtocolTLS.Options?
        if let identity {
            let t = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(t.securityProtocolOptions, sec_identity_create(identity)!)
            sec_protocol_options_set_min_tls_protocol_version(t.securityProtocolOptions, .TLSv12)
            tlsOpts = t
        }
        let params = NWParameters(tls: tlsOpts, tcp: tcp)
        params.serviceClass = .interactiveVoice
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            let conn = Conn(c, server: self, secure: identity != nil)
            self.conns[ObjectIdentifier(conn)] = conn
            conn.start(queue: self.queue)
        }
        l.start(queue: queue)
        return l
    }

    // MARK: sending to the phone (any thread)

    private let backlog = ManagedAtomicInt()

    func sendBinary(_ d: Data) {
        // If Wi-Fi stalls, drop audio rather than let delay pile up (~25 packets ≈ 250 ms).
        guard backlog.value < 25 else { return }
        backlog.add(1)
        queue.async { [backlog] in
            guard let p = self.phone else { backlog.add(-1); return }
            p.sendFrame(opcode: 2, payload: d) { backlog.add(-1) }
        }
    }

    func sendText(_ s: String) {
        queue.async { self.phone?.sendFrame(opcode: 1, payload: Data(s.utf8), done: nil) }
    }

    fileprivate func becamePhone(_ c: Conn) {
        if let old = phone, old !== c { phone = nil; old.close() }
        phone = c
        onPhoneConnected?(c.remote)
    }

    fileprivate func ended(_ c: Conn) {
        conns[ObjectIdentifier(c)] = nil
        if phone === c { phone = nil; onPhoneDisconnected?() }
    }
}

final class ManagedAtomicInt {
    private var v = 0
    private let lock = NSLock()
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    func add(_ d: Int) { lock.lock(); v += d; lock.unlock() }
    func set(_ n: Int) { lock.lock(); v = n; lock.unlock() }
}

private final class Conn {
    let c: NWConnection
    weak var server: Server?
    var buf = Data()
    var isWS = false
    var closed = false
    var remote: String {
        if case let .hostPort(h, _) = c.endpoint { return "\(h)".components(separatedBy: "%").first ?? "\(h)" }
        return "\(c.endpoint)"
    }

    let secure: Bool
    init(_ c: NWConnection, server: Server, secure: Bool) { self.c = c; self.server = server; self.secure = secure }

    func start(queue: DispatchQueue) {
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        c.start(queue: queue)
        receive()
    }

    func receive() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.buf.append(data); self.process() }
            if done || err != nil { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    func close() { guard !closed else { return }; closed = true; c.cancel(); finish() }

    private var finished = false
    func finish() { guard !finished else { return }; finished = true; closed = true; server?.ended(self) }

    // MARK: HTTP

    func process() {
        if isWS { parseFrames(); return }
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            if buf.count > 16384 { close() }
            return
        }
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        buf.removeSubrange(buf.startIndex..<end.upperBound)
        var lines = head.components(separatedBy: "\r\n")
        let reqLine = lines.removeFirst().split(separator: " ")
        guard reqLine.count >= 2 else { close(); return }
        var headers: [String: String] = [:]
        for l in lines { if let i = l.firstIndex(of: ":") {
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        } }
        var path = String(reqLine[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }

        if secure, path == "/ws", headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            isWS = true
            server?.becamePhone(self)
            if !buf.isEmpty { parseFrames() }
            return
        }

        let key = path == "/" ? "/index.html" : path
        if let (body, type) = secure ? server?.httpsFiles[key] : server?.httpFiles[key] {
            var h = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n"
            h += "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            c.send(content: Data(h.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close() })
        } else {
            let body = Data("Not found".utf8)
            let h = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(h.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close() })
        }
    }

    // MARK: WebSocket frames

    func parseFrames() {
        while true {
            let b = [UInt8](buf.prefix(14))
            guard b.count >= 2 else { return }
            let opcode = b[0] & 0x0F
            let masked = b[1] & 0x80 != 0
            var len = Int(b[1] & 0x7F), off = 2
            if len == 126 { guard b.count >= 4 else { return }; len = Int(b[2]) << 8 | Int(b[3]); off = 4 }
            else if len == 127 {
                guard b.count >= 10 else { return }
                len = 0; for i in 2..<10 { len = len << 8 | Int(b[i]) }; off = 10
            }
            if len > 4_000_000 { close(); return }
            let maskOff = off
            if masked { off += 4 }
            guard buf.count >= off + len else { return }
            let start = buf.startIndex
            var payload = Data(buf[(start + off)..<(start + off + len)])
            if masked {
                let m = [UInt8](buf[(start + maskOff)..<(start + maskOff + 4)])
                payload.withUnsafeMutableBytes { p in
                    let q = p.bindMemory(to: UInt8.self)
                    for i in 0..<q.count { q[i] ^= m[i & 3] }
                }
            }
            buf.removeSubrange(start..<(start + off + len))
            switch opcode {
            case 1: server?.onText?(String(decoding: payload, as: UTF8.self))
            case 2: server?.onBinary?(payload)
            case 8: sendFrame(opcode: 8, payload: Data(), done: nil); close(); return
            case 9: sendFrame(opcode: 10, payload: payload, done: nil)
            default: break
            }
        }
    }

    func sendFrame(opcode: UInt8, payload: Data, done: (() -> Void)?) {
        var h = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 { h.append(UInt8(n)) }
        else if n < 65536 { h.append(126); h.append(UInt8(n >> 8)); h.append(UInt8(n & 0xFF)) }
        else { h.append(127); for i in (0..<8).reversed() { h.append(UInt8((n >> (8 * i)) & 0xFF)) } }
        c.send(content: h + payload, completion: .contentProcessed { _ in done?() })
    }
}
