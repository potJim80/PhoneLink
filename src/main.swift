// Phone Link — menu bar app. Plays the Mac's sound on an iPhone and turns the iPhone's mic
// into a Mac microphone ("Phone Link Mic"), over home Wi-Fi, through a page in the phone's browser.
// PHONELINK_HEADLESS=1 runs without the menu bar (for tests); PHONELINK_NO_MUTE=1 never mutes the Mac.
import AppKit
import CoreImage

final class Link {
    let server = Server()
    let capture = SystemCapture()
    let mic = PhoneMic()
    var muteMac = ProcessInfo.processInfo.environment["PHONELINK_NO_MUTE"] == nil
        && !UserDefaults.standard.bool(forKey: "macSpeakersToo")
    var phoneAddress: String?
    var micActive = false
    var onChange: (() -> Void)?
    // Per-app volume for the phone (1 = as the app plays it), saved by app across launches.
    private var appVolumes = (UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: Double] ?? [:]).mapValues { Float($0) }
    private var apps: [String: AppSound] = [:]
    private var shownApps: Set<String> = []     // apps that have played since the phone connected
    private var tappedKeys: [String] = []       // app per group of the running capture, in order
    private var lastAppsJSON = ""
    private var appTimer: Timer?
    private(set) var problem: String?

    var setupURL: String { "http://\(Certs.hostName):\(Server.httpPort)" }
    var appURL: String { "https://\(Certs.hostName):\(Server.httpsPort)" }

    func start() {
        do {
            let identity = try Certs.identity()
            try loadFiles()
            try mic.start()
            server.onPhoneConnected = { [weak self] addr in DispatchQueue.main.async { self?.phoneConnected(addr) } }
            server.onPhoneDisconnected = { [weak self] in DispatchQueue.main.async { self?.phoneGone() } }
            server.onText = { [weak self] t in DispatchQueue.main.async { self?.handle(t) } }
            server.onBinary = { [weak self] d in
                guard let self, self.micActive else { return }
                d.withUnsafeBytes { self.mic.jitter.push($0.bindMemory(to: Int16.self)) }
            }
            capture.onAudio = { [weak self] d in self?.server.sendBinary(d) }
            CA.onDefaultOutputChange { [weak self] in self?.restartCapture() }
            try server.start(identity: identity)
            log("ready — setup page \(setupURL)  app \(appURL)")
        } catch {
            problem = "\(error)"
            log("problem: \(error)")
        }
        onChange?()
    }

    private func loadFiles() throws {
        guard let page = Bundle.main.resourceURL?.appendingPathComponent("page") else { throw AudioError(description: "page folder missing") }
        func f(_ n: String, _ type: String) throws -> (Data, String) { (try Data(contentsOf: page.appendingPathComponent(n)), type) }
        let html = "text/html; charset=utf-8", js = "text/javascript; charset=utf-8"
        var setup = try f("setup.html", html)
        setup.0 = Data(String(decoding: setup.0, as: UTF8.self)
            .replacingOccurrences(of: "{{APP_URL}}", with: appURL)
            .replacingOccurrences(of: "{{HOST}}", with: Certs.hostName).utf8)
        server.httpFiles = ["/index.html": setup,
                            "/phonelink.cer": (try Data(contentsOf: Certs.caDER), "application/x-x509-ca-cert")]
        server.httpsFiles = ["/index.html": try f("index.html", html),
                             "/worklet.js": try f("worklet.js", js),
                             "/manifest.json": try f("manifest.json", "application/manifest+json"),
                             "/icon.png": try f("icon.png", "image/png"),
                             "/ok": (Data("ok".utf8), "text/plain")]
    }

    private func phoneConnected(_ addr: String) {
        phoneAddress = addr
        micActive = false
        mic.jitter.reset()
        lastAppsJSON = ""
        refreshApps(rebuild: false)
        restartCapture()
        appTimer?.invalidate()
        appTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshApps() }
        log("phone connected from \(addr)")
        onChange?()
    }

    private func phoneGone() {
        phoneAddress = nil
        micActive = false
        mic.jitter.reset()
        capture.stop()
        appTimer?.invalidate(); appTimer = nil
        shownApps = []
        log("phone disconnected")
        onChange?()
    }

    func restartCapture() {
        guard phoneAddress != nil else { return }
        let me = mic.processObject.map { [$0] } ?? []
        let keys = wantedTaps()
        do {
            do {
                try capture.start(excluding: me, muteMac: muteMac, groups: keys.map { apps[$0]!.processes },
                                  gains: keys.map { appVolumes[$0] ?? 1 })
                tappedKeys = keys
            } catch where !keys.isEmpty {
                log("per-app capture failed (\(error)); sharing one tap")
                try capture.start(excluding: me, muteMac: muteMac)
                tappedKeys = []
            }
            server.sendText(#"{"t":"hello","rate":\#(Int(capture.rate)),"ch":2,"macSpeakers":\#(!muteMac),"mic":"\#(PhoneMic.deviceName)"}"#)
        } catch {
            log("capture: \(error)")
            server.sendText(#"{"t":"error","text":"The Mac could not share its sound (\#(error))."}"#)
        }
    }

    /// Re-reads which apps are playing; tells the phone if the list changed, and rebuilds the
    /// capture if an app with its own volume gained or lost processes.
    private func refreshApps(rebuild: Bool = true) {
        apps = Apps.current(excluding: Set(mic.processObject.map { [$0] } ?? []))
        shownApps.formUnion(apps.values.filter(\.playing).map(\.key))
        shownApps.formUnion(apps.keys.filter { (appVolumes[$0] ?? 1) != 1 })
        let list = apps.values.filter { shownApps.contains($0.key) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let items = list.map { ["id": $0.key, "name": $0.name, "vol": Double(appVolumes[$0.key] ?? 1), "playing": $0.playing] as [String: Any] }
        if let d = try? JSONSerialization.data(withJSONObject: ["t": "apps", "list": items], options: [.sortedKeys]),
           let json = String(data: d, encoding: .utf8), json != lastAppsJSON {
            lastAppsJSON = json
            server.sendText(json)
        }
        guard rebuild, capture.running else { return }
        if wantedTaps() != tappedKeys || zip(tappedKeys, capture.groups).contains(where: { apps[$0.0]?.processes != $0.1 }) {
            restartCapture()
        }
    }

    /// Apps whose volume isn't 100% get their own tap; the rest share one. An app keeps its tap
    /// once it has one (dragging back to 100% shouldn't rebuild), until it stops using audio.
    private func wantedTaps() -> [String] {
        Set(apps.keys.filter { (appVolumes[$0] ?? 1) != 1 || tappedKeys.contains($0) }).sorted()
    }

    func setAppVolume(_ key: String, _ v: Float) {
        let v = max(0, min(v, 1))
        appVolumes[key] = v
        UserDefaults.standard.set(appVolumes.mapValues { Double($0) }, forKey: "appVolumes")
        if let i = tappedKeys.firstIndex(of: key) {
            capture.setGain(group: i, v)        // already has its own tap: just change the level
        } else if v != 1 {
            refreshApps()                       // needs its own tap first
        }
    }

    func setMacSpeakers(_ on: Bool) {
        muteMac = !on
        UserDefaults.standard.set(on, forKey: "macSpeakersToo")
        restartCapture()
        onChange?()
    }

    private func handle(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let t = obj["t"] as? String else { return }
        switch t {
        case "ping": server.sendText(#"{"t":"pong","id":\#(obj["id"] as? Int ?? 0)}"#)
        case "mic":
            mic.setRate((obj["rate"] as? Double) ?? 48000)
            micActive = true; onChange?()
        case "micOff": micActive = false; mic.jitter.reset(); onChange?()
        case "macSpeakers": setMacSpeakers(obj["on"] as? Bool ?? false)
        case "appVol": if let k = obj["id"] as? String, let v = obj["vol"] as? Double { setAppVolume(k, Float(v)) }
        default: break
        }
    }

    func shutdown() { capture.stop(); mic.stop(); server.stop() }
}

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(s)\n".utf8))
}

// MARK: - menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let link = Link()
    var item: NSStatusItem!
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        item.menu = menu
        link.onChange = { [weak self] in self?.refresh() }
        link.start()
        refresh()
    }

    func applicationWillTerminate(_ n: Notification) { link.shutdown() }

    func refresh() {
        let symbol = link.phoneAddress == nil ? "iphone" : "iphone.radiowaves.left.and.right"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Phone Link")
        item.button?.image?.isTemplate = true
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        func label(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i) }
        if let p = link.problem {
            label("Phone Link isn’t working:"); label(String(p.prefix(80)))
        } else if let a = link.phoneAddress {
            label("Connected to the phone (\(a))")
            label(link.micActive ? "Phone mic is on — pick “\(PhoneMic.deviceName)” in your call app" : "Phone mic is off")
        } else {
            label("Waiting for the phone")
        }
        m.addItem(.separator())
        label("Scan with the iPhone camera:")
        let qr = NSMenuItem()
        qr.view = qrPair([("Phone page", link.appURL), ("First time? Setup", link.setupURL)])
        m.addItem(qr)
        let copy = NSMenuItem(title: "Copy phone page address", action: #selector(copyAddress), keyEquivalent: "")
        copy.target = self; copy.toolTip = link.appURL
        m.addItem(copy)
        m.addItem(.separator())
        let sp = NSMenuItem(title: "Keep Mac speakers on too", action: #selector(toggleSpeakers), keyEquivalent: "")
        sp.target = self; sp.state = link.muteMac ? .off : .on
        m.addItem(sp)
        m.addItem(.separator())
        let q = NSMenuItem(title: "Quit Phone Link", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(q)
    }

    @objc func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.appURL, forType: .string)
    }

    @objc func toggleSpeakers() { link.setMacSpeakers(link.muteMac) }

    /// Side-by-side QR codes, each with a caption underneath.
    func qrPair(_ codes: [(String, String)]) -> NSView {
        let side: CGFloat = 170, pad: CGFloat = 16, gap: CGFloat = 16, captionH: CGFloat = 20
        let v = NSView(frame: NSRect(x: 0, y: 0, width: pad * 2 + side * CGFloat(codes.count) + gap * CGFloat(codes.count - 1),
                                     height: side + captionH + 12))
        for (i, (caption, url)) in codes.enumerated() {
            let x = pad + CGFloat(i) * (side + gap)
            let iv = NSImageView(frame: NSRect(x: x, y: captionH + 4, width: side, height: side))
            iv.image = qrImage(url, size: side)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.toolTip = url
            v.addSubview(iv)
            let t = NSTextField(labelWithString: caption)
            t.frame = NSRect(x: x, y: 0, width: side, height: captionH)
            t.alignment = .center
            t.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            t.textColor = .secondaryLabelColor
            v.addSubview(t)
        }
        return v
    }

    func qrImage(_ text: String, size: CGFloat) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scale = floor(size / out.extent.width)
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let margin = scale * 2
        let img = NSImage(size: NSSize(width: rep.size.width + margin * 2, height: rep.size.height + margin * 2))
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: img.size), xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(x: margin, y: margin, width: rep.size.width, height: rep.size.height))
        img.unlockFocus()
        return img
    }
}

if ProcessInfo.processInfo.environment["PHONELINK_HEADLESS"] != nil {
    let link = Link()
    link.start()
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let stop: () -> Void = { link.shutdown(); exit(0) }
    let s1 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main); s1.setEventHandler(handler: stop); s1.resume()
    let s2 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main); s2.setEventHandler(handler: stop); s2.resume()
    withExtendedLifetime([s1, s2]) { dispatchMain() }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
