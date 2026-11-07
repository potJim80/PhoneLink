// The phone only lets a page use its microphone over https, so this Mac acts as its own tiny
// certificate authority. The phone trusts the authority once; the server certificate under it
// is remade whenever this Mac's name or Wi-Fi address changes. Uses macOS's own /usr/bin/openssl.
import Foundation
import Security
import SystemConfiguration

enum Certs {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneLink")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var caDER: URL { dir.appendingPathComponent("ca.cer") }
    private static let pass = "phonelink"

    static var hostName: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" } ?? "localhost"
    }

    static var ipv4Addresses: [String] {
        var out: [String] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return out }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let i = p?.pointee {
            defer { p = i.ifa_next }
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  i.ifa_flags & UInt32(IFF_UP) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: host)
                if !s.hasPrefix("169.254.") { out.append(s) }
            }
        }
        return out
    }

    @discardableResult
    private static func openssl(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.currentDirectoryURL = dir
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw AudioError(description: "openssl \(args.first ?? ""): \(text)") }
        return text
    }

    private static func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Returns the server identity, creating or refreshing certificates as needed.
    static func identity() throws -> SecIdentity {
        let fm = FileManager.default
        func has(_ n: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(n).path) }

        if !has("ca.key") || !has("ca.pem") || !has("ca.cer") {
            try write("ca.cnf", """
                [req]
                distinguished_name = dn
                prompt = no
                [dn]
                CN = Phone Link (\(hostName.replacingOccurrences(of: ".local", with: "")))
                O = Phone Link
                [ext]
                basicConstraints = critical,CA:TRUE
                keyUsage = critical,keyCertSign,cRLSign
                subjectKeyIdentifier = hash
                """)
            try openssl(["req", "-x509", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                         "-keyout", "ca.key", "-out", "ca.pem", "-config", "ca.cnf", "-extensions", "ext"])
            try openssl(["x509", "-in", "ca.pem", "-outform", "DER", "-out", "ca.cer"])
            try? fm.removeItem(at: dir.appendingPathComponent("leaf.p12"))
        }

        let sans = (["DNS:\(hostName)", "DNS:localhost", "IP:127.0.0.1"] + ipv4Addresses.map { "IP:\($0)" }).joined(separator: ",")
        let oldSans = try? String(contentsOf: dir.appendingPathComponent("leaf.sans"), encoding: .utf8)
        if !has("leaf.p12") || oldSans != sans {
            try write("leaf.cnf", """
                [req]
                distinguished_name = dn
                prompt = no
                [dn]
                CN = \(hostName)
                """)
            try write("leaf.ext", """
                basicConstraints = CA:FALSE
                keyUsage = critical,digitalSignature,keyEncipherment
                extendedKeyUsage = serverAuth
                subjectAltName = \(sans)
                subjectKeyIdentifier = hash
                authorityKeyIdentifier = keyid
                """)
            let serial = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
            try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "leaf.key", "-out", "leaf.csr", "-config", "leaf.cnf"])
            // Apple refuses server certificates valid for more than 825 days.
            try openssl(["x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-set_serial", "0x" + serial,
                         "-sha256", "-days", "800", "-extfile", "leaf.ext", "-out", "leaf.pem"])
            try openssl(["pkcs12", "-export", "-out", "leaf.p12", "-inkey", "leaf.key", "-in", "leaf.pem",
                         "-certfile", "ca.pem", "-name", "Phone Link", "-passout", "pass:" + pass])
            try write("leaf.sans", sans)
        }

        let p12 = try Data(contentsOf: dir.appendingPathComponent("leaf.p12"))
        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: pass, kSecImportToMemoryOnly as String: true]
        let s = SecPKCS12Import(p12 as CFData, opts as CFDictionary, &items)
        guard s == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first,
              let idRef = first[kSecImportItemIdentity as String] else {
            throw AudioError(description: "could not load the certificate (\(s))")
        }
        return idRef as! SecIdentity
    }
}
