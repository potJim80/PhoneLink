// Which apps are making sound on the Mac, for the per-app volume sliders on the phone.
// Core Audio lists processes, not apps: Chrome plays from a "Google Chrome Helper", Firefox from
// "plugin-container", so each process is filed under the outermost .app it lives inside.
import AppKit
import CoreAudio

struct AppSound {
    let key: String                 // stable id, e.g. "com.google.Chrome"; volumes are saved under it
    let name: String
    var processes: [AudioObjectID]
    var playing: Bool
}

enum Apps {
    /// Everything that has opened audio right now (except `exclude`), grouped by app.
    static func current(excluding exclude: Set<AudioObjectID>) -> [String: AppSound] {
        var out: [String: AppSound] = [:]
        for obj in CA.processes() where !exclude.contains(obj) {
            let pid = CA.pid(obj)
            guard pid > 0, let (key, name) = identify(pid: pid) else { continue }
            let playing = CA.isPlaying(obj)
            if out[key] == nil { out[key] = AppSound(key: key, name: name, processes: [], playing: false) }
            out[key]!.processes.append(obj)
            out[key]!.playing = out[key]!.playing || playing
        }
        for k in out.keys { out[k]!.processes.sort() }
        return out
    }

    private static var cache: [pid_t: (String, String)?] = [:]

    static func identify(pid: pid_t) -> (key: String, name: String)? {
        if let c = cache[pid] { return c }
        let r = lookup(pid: pid)
        if cache.count > 500 { cache.removeAll() }
        cache[pid] = r
        return r
    }

    private static func lookup(pid: pid_t) -> (String, String)? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        // Safari, Mail and every other WebKit app play web audio from one shared system process.
        if path.contains("/com.apple.WebKit.GPU.xpc/") || path.contains("/com.apple.WebKit.WebContent") {
            return ("com.apple.WebKit", "Safari & web pages")
        }
        // Outermost .app in the path: ".../Google Chrome.app/.../Google Chrome Helper.app/..." → Chrome.
        if let r = path.range(of: ".app/") {
            let appPath = String(path[..<r.lowerBound]) + ".app"
            let bundle = Bundle(path: appPath)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
            return (bundle?.bundleIdentifier ?? appPath, name)
        }
        // A command-line tool (afplay, say…): its own name.
        let tool = (path as NSString).lastPathComponent
        if tool == "systemsoundserverd" { return ("system-sounds", "System sounds") }
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            return (app.bundleIdentifier ?? path, n)
        }
        return (path, tool)
    }
}
