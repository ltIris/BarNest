import AppKit
import CoreAudio

/**
 * @Author lt_xiaoyi
 * @Description 「此刻谁在向系统输出音频」——判断替身播放图标是否该出现，用这个。
 *
 * 为什么不能用 MediaRemote：
 * `MRMediaRemoteGetNowPlayingApplicationPID` 对网易云音乐这类**不自注册
 * Now Playing** 的播放器恒返回 0。实测它正在放歌时，系统菜单栏上那颗
 * `com.apple.menuextra.now-playing` 明明存在（x=1085、16pt 宽），
 * 但这个接口仍然报 0 —— 拿它当判据，结果就是「明明在放歌，播放图标永远不出现」。
 *
 * 所以判据换成音频层的事实：CoreAudio 的 process object 列表里，
 * `kAudioProcessPropertyIsRunningOutput = 1` 的进程就是真的在出声的那个 App。
 * 顺带还能拿到它的 pid / bundleID，点击时可以作为兜底（比如那颗系统项按不动时）。
 * @Version 1.0
 */
enum AudioActivity {
    /**
     * @Author lt_xiaoyi
     * @Description 记录音频输出进程及其应用标识。
     * @Version 1.0
     */
    struct Client {
        let pid: pid_t
        let bundleID: String?
    }

    /**
     * 正在输出音频、且属于「可见 App」的进程。
     *
     * 只看 `activationPolicy == .regular` 的进程：拒绝系统提示音（通知、输入法
     * 叮咚声由后台守护进程发出），否则随便响一声就冒出一颗播放图标。
     *
     * 返回顺序 = **最近开始出声的排前面**。多个播放器同时开着输出流时（比如
     * Apple Music 只是挂着没播、网易云刚按播放），谁「刚按了播放」才是用户眼里
     * 正在放歌的那个；只按 HAL 列表顺序取第一个，就会出现「明明在听网易云、
     * 播放入口却显示音乐」。
     */
    static func activeOutputClients() -> [Client] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var listSize = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &listSize) == noErr,
              listSize > 0 else { return [] }

        var objects = [AudioObjectID](repeating: 0,
                                      count: Int(listSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &listSize, &objects) == noErr else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [Client] = []
        var stillActive = Set<pid_t>()
        for object in objects {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &runningAddr, 0, nil,
                                             &runningSize, &running) == noErr,
                  running != 0 else { continue }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                  pid > 0, pid != ownPID else { continue }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            stillActive.insert(pid)
            // 第一次观测到它在出声 → 盖个时间戳；一直在出声就保留老时间戳。
            if startedAt[pid] == nil { startedAt[pid] = Date() }
            result.append(Client(pid: pid, bundleID: app.bundleIdentifier))
        }
        // 不再出声的进程把时间戳清掉，下次再播才是「刚刚开始」。
        for pid in startedAt.keys where !stillActive.contains(pid) {
            startedAt.removeValue(forKey: pid)
        }
        return result.sorted {
            (startedAt[$0.pid] ?? .distantPast) > (startedAt[$1.pid] ?? .distantPast)
        }
    }

    // 各进程「第一次被观测到在出声」的时刻，用来判断谁刚按的播放。
    private static var startedAt: [pid_t: Date] = [:]

    // 这个进程已经连续输出音频多久（秒）。用来过滤掉「启动音一声就没了」的假播放器。
    static func outputTenure(pid: pid_t) -> TimeInterval {
        guard let start = startedAt[pid] else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // 系统默认输出设备是否在出声（任何进程都算，作为兜底信号）。
    static func isOutputRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &runningAddr, 0, nil,
                                         &runningSize, &running) == noErr else { return false }
        return running != 0
    }
}

/**
 * @Author lt_xiaoyi
 * @Description 查询系统播放会话，辅助判断保留输出流的应用是否真的在播放。
 * @Version 1.0
 */
enum MediaRemoteQuery {
    /**
     * @Author lt_xiaoyi
     * @Description 记录播放会话的进程、播放状态和曲目信息状态。
     * @Version 1.0
     */
    struct State {
        let pid: pid_t
        let isPlaying: Bool
        // 系统 Now Playing 会话里有没有曲目信息。没有 = 系统里没有任何正在播放。
        let hasInfo: Bool
    }

    private typealias PidFn = @convention(c) (DispatchQueue, AnyObject) -> Void
    private typealias BoolFn = @convention(c) (DispatchQueue, AnyObject) -> Void

    private static let framework: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

    // 同步查询（每路 60ms 上限）。回调都在私有队列上，不会和自己死锁。
    static func state() -> State? {
        guard let handle = framework,
              let pidSym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID"),
              let playSym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying"),
              let infoSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")
        else { return nil }

        let getPID = unsafeBitCast(pidSym, to: PidFn.self)
        let getPlaying = unsafeBitCast(playSym, to: BoolFn.self)
        let getInfo = unsafeBitCast(infoSym, to: BoolFn.self)

        let queue = DispatchQueue(label: "notchtool.mediaremote.query")
        let pidSem = DispatchSemaphore(value: 0)
        let playSem = DispatchSemaphore(value: 0)
        let infoSem = DispatchSemaphore(value: 0)
        var rawPID: Int32 = 0
        var playing = false
        var hasInfo = false

        let pidBlock: @convention(block) (Int32) -> Void = { value in
            rawPID = value
            pidSem.signal()
        }
        let playBlock: @convention(block) (Bool) -> Void = { value in
            playing = value
            playSem.signal()
        }
        let infoBlock: @convention(block) (AnyObject?) -> Void = { value in
            if let dict = value as? [String: Any] {
                hasInfo = dict["kMRMediaRemoteNowPlayingInfoTitle"] != nil
                    || dict["kMRMediaRemoteNowPlayingInfoArtist"] != nil
            }
            infoSem.signal()
        }
        getPID(queue, pidBlock as AnyObject)
        getPlaying(queue, playBlock as AnyObject)
        getInfo(queue, infoBlock as AnyObject)

        guard pidSem.wait(timeout: .now() + 0.06) == .success,
              playSem.wait(timeout: .now() + 0.06) == .success,
              infoSem.wait(timeout: .now() + 0.06) == .success else { return nil }
        return State(pid: rawPID, isPlaying: playing, hasInfo: hasInfo)
    }
}
