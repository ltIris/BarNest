import AppKit
import CoreAudio

/**
 * @Author lt_xiaoyi
 * @Description 检测系统当前是否有媒体在播放。
 *
 * 为什么必须有这个东西（实测结论，别再改回去）：
 * assessment mode（收纳断言）一旦激活，macOS 会把菜单栏上的「正在播放」
 * attached AV module 整体隐藏掉——这是框架里 `MBHideAttachedAVModuleAssertion`
 * 的固定行为。三组对照实验证明与参数无关：
 * · 不激活断言            → ▶ 正常显示
 * · allowedSystemItems 0..8  → ▶ 消失
 * · allowedSystemItems 0..64 → ▶ 消失
 * 往里塞 `com.apple.controlcenter.nowplaying` / `MediaRemoteUI` / `chronod`
 * 也完全没有作用。所以唯一可行方案是：真的有媒体在播时临时释放断言让 ▶ 回来，
 * 停止播放后再自动收起。
 * @Version 1.0
 */
@MainActor
final class MediaPlaybackMonitor {
    static let shared = MediaPlaybackMonitor()

    /**
     * 每次轮询都把「当前是否在播放」回调出去，由调用方决定怎么用。
     * 不做「只在变化时回调」——因为断言可能被别处重建，需要重新施加状态。
     */
    private var onState: ((Bool) -> Void)?
    private var timer: Timer?

    // 连续两次读数一致才切换，避免曲目间隙 / 短暂静音导致菜单栏来回闪。
    private var lastRaw: Bool?
    private var stable: Bool = false

    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private var getIsPlaying: GetIsPlayingFn?

    private init() {
        // MediaRemote 是系统私有框架，符号拿不到时退化为 CoreAudio 检测。
        if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
           let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getIsPlaying = unsafeBitCast(sym, to: GetIsPlayingFn.self)
        }
    }

    func start(onState: @escaping (Bool) -> Void) {
        self.onState = onState
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onState = nil
    }

    private func poll() {
        // 两路信号取「或」：
        //  · MediaRemote 能识别标准 Now Playing 会话（音乐/播客/浏览器）；
        //  · 但像抖音这类自绘播放窗口不一定注册到 MediaRemote，
        //    此时用「默认输出设备是否有音频流」兜住，避免漏判。
        let audioRunning = defaultOutputIsRunning()
        if let getIsPlaying {
            getIsPlaying(DispatchQueue.main) { [weak self] playing in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.accept(playing || audioRunning) }
                }
            }
        } else {
            accept(audioRunning)
        }
    }

    private func accept(_ raw: Bool) {
        if lastRaw == nil {
            lastRaw = raw
            stable = raw
        } else if lastRaw == raw {
            stable = raw          // 连续两次一致 → 确认，切换状态
        } else {
            lastRaw = raw         // 还在抖动（曲目间隙），先不改
        }
        // 每轮都下发一次期望状态：调用方那边是幂等的，
        // 这样即使断言被别处重建，下一轮也会自动补回来。
        onState?(stable)
    }

    /**
     * 退化方案：默认输出设备是否正在被使用（有音频流在跑）。
     * 会把提示音也算进去，所以优先用 MediaRemote。
     */
    private func defaultOutputIsRunning() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return false }

        var running = UInt32(0)
        var rsize = UInt32(MemoryLayout<UInt32>.size)
        var raddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        guard AudioObjectGetPropertyData(deviceID, &raddr, 0, nil, &rsize, &running) == noErr else { return false }
        return running != 0
    }
}
