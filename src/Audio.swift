// The two audio halves, both without a driver:
//  - SystemCapture: a Core Audio process tap on everything the Mac plays (minus this app),
//    read through a private aggregate device. Optionally mutes the Mac's speakers while read.
//  - PhoneMic: plays the phone's mic stream out of this process, taps this process (muted),
//    and publishes that tap as a public aggregate device — the "Phone Link Mic" other apps pick.
import Foundation
import CoreAudio
import AVFoundation
import os

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ val: inout T,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       qual: UnsafeRawPointer? = nil, qualSize: UInt32 = 0) -> OSStatus {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, qualSize, qual, &size, &val)
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var p = pid, obj = AudioObjectID(0)
        let s = withUnsafePointer(to: &p) {
            get(system, kAudioHardwarePropertyTranslatePIDToProcessObject, &obj, qual: $0, qualSize: UInt32(MemoryLayout<pid_t>.size))
        }
        return s == noErr && obj != 0 ? obj : nil
    }

    static func sampleRate(_ dev: AudioObjectID) -> Double {
        var r = Float64(0); _ = get(dev, kAudioDevicePropertyNominalSampleRate, &r); return r
    }

    static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var f = AudioStreamBasicDescription()
        return get(tap, kAudioTapPropertyFormat, &f) == noErr ? f : nil
    }

    /// Every process Core Audio knows about (anything that has opened audio).
    static func processes() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Channels in each input buffer of a device, e.g. [2, 2] for two interleaved stereo streams.
    static func inputBuffers(_ dev: AudioObjectID) -> [Int] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    static func pid(_ process: AudioObjectID) -> pid_t {
        var p = pid_t(-1); _ = get(process, kAudioProcessPropertyPID, &p); return p
    }

    static func isPlaying(_ process: AudioObjectID) -> Bool {
        var on = UInt32(0); _ = get(process, kAudioProcessPropertyIsRunningOutput, &on); return on != 0
    }

    static func makeAggregate(name: String, uid: String, tap: CATapDescription, isPrivate: Bool) -> AudioObjectID? {
        makeAggregate(name: name, uid: uid, taps: [tap], isPrivate: isPrivate)
    }

    static func makeAggregate(name: String, uid: String, taps: [CATapDescription], isPrivate: Bool) -> AudioObjectID? {
        let d: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: isPrivate,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: taps.map { [kAudioSubTapDriftCompensationKey: true,
                                                         kAudioSubTapUIDKey: $0.uuid.uuidString] },
        ]
        var agg = AudioObjectID(0)
        return AudioHardwareCreateAggregateDevice(d as CFDictionary, &agg) == noErr ? agg : nil
    }

    static func onDefaultOutputChange(_ block: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in block() }
    }
}

struct AudioError: Error, CustomStringConvertible { let description: String }

// MARK: - Mac sound → phone

final class SystemCapture {
    /// Called on the audio thread with interleaved stereo Int16 PCM.
    var onAudio: ((Data) -> Void)?
    private(set) var rate: Double = 48000
    private(set) var running = false
    /// The per-app groups the running capture was built with (each tapped on its own).
    private(set) var groups: [[AudioObjectID]] = []
    private var taps: [AudioObjectID] = [], aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    static let maxGroups = 32
    // Tap 0 is "everything else" (always full volume); tap i is groups[i-1]. Written on the main
    // thread, read on the audio thread; a 32-bit float store is atomic, so no lock is needed.
    private let gains = UnsafeMutablePointer<Float>.allocate(capacity: maxGroups + 1)

    init() { gains.initialize(repeating: 1, count: Self.maxGroups + 1) }

    /// Volume (0…1+) for groups[i], applied to what goes to the phone. Takes effect within ~10 ms.
    func setGain(group i: Int, _ g: Float) {
        guard i >= 0, i < Self.maxGroups else { return }
        gains[i + 1] = max(0, min(g, 4))
    }

    /// Taps everything the Mac plays except `exclude`. Each entry of `groups` (one app's processes)
    /// gets its own tap, so it can have its own volume; the rest share one tap at full volume.
    func start(excluding exclude: [AudioObjectID], muteMac: Bool, groups: [[AudioObjectID]] = [], gains g: [Float] = []) throws {
        stop()
        let groups = Array(groups.filter { !$0.isEmpty }.prefix(Self.maxGroups))
        var descs = [CATapDescription(stereoGlobalTapButExcludeProcesses: exclude + groups.flatMap { $0 })]
        descs += groups.map { CATapDescription(stereoMixdownOfProcesses: $0) }
        for (i, desc) in descs.enumerated() {
            desc.muteBehavior = muteMac ? .mutedWhenTapped : .unmuted
            desc.isPrivate = true
            desc.name = "Phone Link capture \(i)"
            var id = AudioObjectID(0)
            guard AudioHardwareCreateProcessTap(desc, &id) == noErr else { stop(); throw AudioError(description: "could not tap the Mac's sound") }
            taps.append(id)
        }
        guard let agg = CA.makeAggregate(name: "Phone Link capture", uid: "local.phonelink.capture." + UUID().uuidString,
                                         taps: descs, isPrivate: true) else {
            stop(); throw AudioError(description: "could not open the Mac's sound")
        }
        aggID = agg
        self.groups = groups
        gains[0] = 1
        for i in 0..<groups.count { gains[i + 1] = i < g.count ? max(0, min(g[i], 4)) : 1 }
        rate = CA.tapFormat(taps[0]).map { $0.mSampleRate } ?? CA.sampleRate(agg)
        if rate <= 0 { rate = 48000 }
        // Which tap each input channel belongs to, in the order the aggregate lists them.
        var owner: [Int] = []
        for (t, id) in taps.enumerated() { owner += Array(repeating: t, count: max(1, Int(CA.tapFormat(id)?.mChannelsPerFrame ?? 2))) }
        let tapChannels = taps.map { max(1, Int(CA.tapFormat($0)?.mChannelsPerFrame ?? 2)) }
        log("capture: \(taps.count) tap(s), channels per tap \(tapChannels), input buffers \(CA.inputBuffers(agg))")

        var out = [Int16](repeating: 0, count: 8192)
        var mixL = [Float](repeating: 0, count: 4096), mixR = mixL
        var applied = [Float](repeating: 1, count: taps.count)      // gain at the end of the last block
        var target = applied
        let gains = self.gains
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { [weak self] _, inData, _, _, _ in
            guard let self, let cb = self.onAudio else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = abl.first, first.mData != nil else { return }
            var frames = Int(first.mDataByteSize) / 4 / max(Int(first.mNumberChannels), 1)
            for b in abl where b.mNumberChannels > 0 { frames = min(frames, Int(b.mDataByteSize) / 4 / Int(b.mNumberChannels)) }
            if frames == 0 { return }
            if out.count < frames * 2 { out = [Int16](repeating: 0, count: frames * 2) }
            if mixL.count < frames { mixL = [Float](repeating: 0, count: frames); mixR = mixL }
            // Ramp each tap's volume across the block so a slider move never clicks.
            for t in 0..<target.count { target[t] = gains[t] }
            mixL.withUnsafeMutableBufferPointer { l in mixR.withUnsafeMutableBufferPointer { r in
                SystemCapture.mix(abl, frames: frames, owner: owner, tapChannels: tapChannels, from: applied, to: target,
                                  left: l.baseAddress!, right: r.baseAddress!)
            } }
            for t in 0..<target.count { applied[t] = target[t] }
            @inline(__always) func s16(_ x: Float) -> Int16 { Int16(max(-1, min(1, x)) * 32767) }
            for i in 0..<frames { out[2*i] = s16(mixL[i]); out[2*i+1] = s16(mixR[i]) }
            cb(out.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(rebasing: $0[0..<frames*2])) })
        }
        guard status == noErr, AudioDeviceStart(agg, procID) == noErr else {
            stop(); throw AudioError(description: "could not start listening to the Mac's sound")
        }
        running = true
    }

    /// Adds every tap's input into one stereo pair, tap t at a volume going from from[t] to to[t]
    /// over the block. owner[c] = the tap that input channel c belongs to.
    static func mix(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int, owner: [Int], tapChannels: [Int],
                    from: [Float], to: [Float], left mixL: UnsafeMutablePointer<Float>, right mixR: UnsafeMutablePointer<Float>) {
        mixL.update(repeating: 0, count: frames); mixR.update(repeating: 0, count: frames)
        var ch = 0                                      // input channel index across all buffers
        for b in abl {
            let n = Int(b.mNumberChannels)
            defer { ch += n }
            guard n > 0, let p = b.mData?.assumingMemoryBound(to: Float.self), ch < owner.count else { continue }
            let t = owner[ch]
            let first = ch - (owner.firstIndex(of: t) ?? ch)   // which channel of its tap this buffer starts at
            let g0 = from[t], dg = (to[t] - g0) / Float(frames)
            if g0 == 0 && dg == 0 { continue }
            if tapChannels[t] == 1 {                     // mono tap: same on both sides
                for i in 0..<frames { let v = p[i * n] * (g0 + dg * Float(i)); mixL[i] += v; mixR[i] += v }
            } else if n >= 2 {                           // interleaved stereo
                for i in 0..<frames { let g = g0 + dg * Float(i); mixL[i] += p[i * n] * g; mixR[i] += p[i * n + 1] * g }
            } else if first == 0 {                       // planar left
                for i in 0..<frames { mixL[i] += p[i] * (g0 + dg * Float(i)) }
            } else {                                     // planar right
                for i in 0..<frames { mixR[i] += p[i] * (g0 + dg * Float(i)) }
            }
        }
    }

    func stop() {
        if aggID != 0 {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        taps.forEach { AudioHardwareDestroyProcessTap($0) }
        procID = nil; aggID = 0; taps = []; groups = []; running = false
    }
}

// MARK: - Phone mic → "Phone Link Mic"

/// Small jitter buffer: holds ~20 ms, drops the excess if the network bunches packets up.
final class JitterBuffer {
    private var buf: [Float]
    private var w = 0, r = 0                    // absolute counts
    private var priming = true
    private let lock = OSAllocatedUnfairLock()
    private(set) var rate: Double
    private var target: Int, ceiling: Int

    init(rate: Double) {
        self.rate = rate
        buf = [Float](repeating: 0, count: Int(rate * 2))
        target = Int(rate * 0.02); ceiling = Int(rate * 0.08)
    }

    func reset(rate newRate: Double? = nil) {
        lock.withLockUnchecked {
            if let nr = newRate, nr != rate {
                rate = nr; buf = [Float](repeating: 0, count: Int(nr * 2))
                target = Int(nr * 0.02); ceiling = Int(nr * 0.08)
            }
            w = 0; r = 0; priming = true
        }
    }

    func push(_ samples: UnsafeBufferPointer<Int16>) {
        lock.withLockUnchecked {
            let cap = buf.count
            for s in samples { buf[w % cap] = Float(s) / 32768; w += 1 }
            if w - r > cap { r = w - cap }
        }
    }

    func pull(into out: UnsafeMutablePointer<Float>, frames: Int) {
        lock.withLockUnchecked {
            let cap = buf.count
            var avail = w - r
            if priming {
                if avail >= target { priming = false } else { out.update(repeating: 0, count: frames); return }
            }
            if avail > ceiling { r = w - target; avail = target }
            let n = min(avail, frames)
            for i in 0..<n { out[i] = buf[(r + i) % cap] }
            r += n
            if n < frames { (out + n).update(repeating: 0, count: frames - n); priming = true }
        }
    }
}

final class PhoneMic {
    static let deviceName = "Phone Link Mic"
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    let jitter = JitterBuffer(rate: 48000)
    private(set) var processObject: AudioObjectID?
    private var tapID = AudioObjectID(0), aggID = AudioObjectID(0)

    func start() throws {
        connectSource(rate: jitter.rate)
        try engine.start()
        // The process object only exists once this process is using audio.
        for _ in 0..<40 where processObject == nil {
            processObject = CA.processObject(pid: getpid())
            if processObject == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard let me = processObject else { throw AudioError(description: "could not find this app in Core Audio") }
        let desc = CATapDescription(stereoMixdownOfProcesses: [me])
        desc.muteBehavior = .muted              // never heard on the Mac's speakers
        desc.isPrivate = false
        desc.name = "Phone Link Mic"
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { throw AudioError(description: "could not make the phone mic") }
        var agg = CA.makeAggregate(name: Self.deviceName, uid: "local.phonelink.mic", tap: desc, isPrivate: false)
        if agg == nil { agg = CA.makeAggregate(name: Self.deviceName, uid: "local.phonelink.mic." + UUID().uuidString, tap: desc, isPrivate: false) }
        guard let a = agg else { throw AudioError(description: "could not publish the phone mic") }
        aggID = a
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            try? self?.engine.start()
        }
    }

    /// Phone's mic sample rate; rebuilds the source node if it changed.
    func setRate(_ rate: Double) {
        guard rate > 0, rate != jitter.rate else { jitter.reset(); return }
        jitter.reset(rate: rate)
        engine.stop()
        connectSource(rate: rate)
        try? engine.start()
    }

    private func connectSource(rate: Double) {
        if let s = source { engine.disconnectNodeOutput(s); engine.detach(s) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let jb = jitter
        let s = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
            let b = UnsafeMutableAudioBufferListPointer(abl)
            if let p = b[0].mData?.assumingMemoryBound(to: Float.self) { jb.pull(into: p, frames: Int(frames)) }
            return noErr
        }
        engine.attach(s)
        engine.connect(s, to: engine.mainMixerNode, format: fmt)
        source = s
    }

    func stop() {
        engine.stop()
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }
}
