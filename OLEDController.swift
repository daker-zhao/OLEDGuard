import Cocoa
import ScreenCaptureKit
import Combine
import CoreGraphics
import ApplicationServices

// MARK: - 💀 黑魔法区域 (修复后台光标隐藏失效)
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int, _ cid2: Int, _ key: CFString, _ value: CFTypeRef) -> Int
@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> Int

// MARK: - 📦 核心模型定义
struct ShortcutModel: Codable, Identifiable, Equatable {
    var id = UUID()
    var keyCode: UInt16
    var modifierRaw: UInt
    var readableString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifierRaw)
        var s = ""
        if flags.contains(.command) { s += "⌘ " }
        if flags.contains(.shift) { s += "⇧ " }
        if flags.contains(.option) { s += "⌥ " }
        if flags.contains(.control) { s += "⌃ " }
        s += KeyCodeHelper.name(for: keyCode)
        return s
    }
}

struct MaskPreset: Codable, Identifiable, Equatable {
    var id = UUID(); var name: String
    var topPadding: Double; var bottomPadding: Double
    var mTop: Double; var mBottom: Double; var mLeft: Double; var mRight: Double
}

struct VisionStatus {
    let isRelaxedOk: Bool; let isStrictOk: Bool; let isForcedOk: Bool; let isHugeChange: Bool
    let activeGridCount: Int // 传递活跃网格数
}

enum GuardStage { case relaxed, strict, forced }

// MARK: - 🎭 物理遮罩引擎
class MaskWindow: NSWindow {
    var restoreDelay: Double = 3.0
    private var trackingArea: NSTrackingArea?
    private var restoreTimer: Timer?
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.isReleasedWhenClosed = false; self.level = .statusBar + 1; self.backgroundColor = .black
        self.alphaValue = 1.0; self.isOpaque = false; self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; setupTracking()
    }
    private func setupTracking() {
        guard let view = self.contentView else { return }
        if let old = trackingArea { view.removeTrackingArea(old) }
        trackingArea = NSTrackingArea(rect: view.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        view.addTrackingArea(trackingArea!)
    }
    override func mouseEntered(with event: NSEvent) {
        restoreTimer?.invalidate(); restoreTimer = nil
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; self.animator().alphaValue = 0.0 }
        self.ignoresMouseEvents = true; startExitCheck()
    }
    private func startExitCheck() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.alphaValue > 0.1 { timer.invalidate(); return }
            if !NSPointInRect(NSEvent.mouseLocation, self.frame) { timer.invalidate(); self.scheduleRestore() }
        }
    }
    private func scheduleRestore() { if restoreTimer == nil { restoreTimer = Timer.scheduledTimer(withTimeInterval: restoreDelay, repeats: false) { [weak self] _ in self?.performRestore() } } }
    private func performRestore() { restoreTimer = nil; self.ignoresMouseEvents = false; NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.5; self.animator().alphaValue = 1.0 } }
}

@MainActor
class MaskEngine: ObservableObject {
    private var topWindow: MaskWindow?, bottomWindow: MaskWindow?, mTopWin: MaskWindow?, mBottomWin: MaskWindow?, mLeftWin: MaskWindow?, mRightWin: MaskWindow?
    private var currentTargetScreenID: CGDirectDisplayID?; private var lastArgs: MaskUpdateArgs?
    struct MaskUpdateArgs { let enableTop, enableBot, smart: Bool; let sysTp, sysBp, mT, mB, mL, mR, delay: Double }
    init() { Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } } }
    func update(target: NSScreen?, args: MaskUpdateArgs) {
        self.currentTargetScreenID = (target?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        self.lastArgs = args; refresh()
    }
    private func refresh() {
        guard let sid = currentTargetScreenID, let args = lastArgs, let live = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == sid }), let zero = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else { closeAll(); return }
        let zeroH = zero.frame.height
        var mbH: CGFloat = 0; var dockH: CGFloat = 0; var hasMB = false; var hasDock = false
        if let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
            for win in list {
                guard let bDict = win[kCGWindowBounds as String] as? [String: Any], let cgB = CGRect(dictionaryRepresentation: bDict as CFDictionary) else { continue }
                let nsB = CGRect(x: cgB.origin.x, y: zeroH - cgB.origin.y - cgB.height, width: cgB.width, height: cgB.height)
                if nsB.intersects(live.frame), let layer = win[kCGWindowLayer as String] as? Int, (layer == 24 || layer == 25) {
                    if nsB.height > 10 && nsB.maxY >= live.frame.maxY - 40 { hasMB = true; mbH = max(mbH, nsB.height) }
                }
            }
        }
        if let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            let axDock = AXUIElementCreateApplication(dockApp.processIdentifier); var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(axDock, kAXChildrenAttribute as CFString, &children) == .success, let children = children as? [AXUIElement] {
                for child in children {
                    var szRef: CFTypeRef?, posRef: CFTypeRef?; guard AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &szRef) == .success, AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success else { continue }
                    var sz = CGSize.zero, pos = CGPoint.zero; AXValueGetValue(szRef as! AXValue, .cgSize, &sz); AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
                    if sz.height > 200 || sz.height < 20 { continue }
                    let nsB = CGRect(x: pos.x, y: zeroH - pos.y - sz.height, width: sz.width, height: sz.height)
                    if nsB.intersects(live.frame) && nsB.minY <= live.frame.minY + 50 { hasDock = true; let safe = live.visibleFrame.minY - live.frame.minY; dockH = (args.smart && safe > 5) ? safe : sz.height; break }
                }
            }
        }
        let updateWin = { (win: inout MaskWindow?, rect: NSRect, show: Bool) in if show { if win == nil { win = MaskWindow(frame: rect) }; win?.setFrame(rect, display: true); win?.restoreDelay = args.delay; win?.orderFront(nil) } else { win?.close(); win = nil } }
        updateWin(&topWindow, NSRect(x: live.frame.origin.x, y: live.frame.maxY - (mbH + args.sysTp), width: live.frame.width, height: mbH + args.sysTp), args.enableTop && hasMB)
        updateWin(&bottomWindow, NSRect(x: live.frame.origin.x, y: live.frame.origin.y, width: live.frame.width, height: dockH + args.sysBp), args.enableBot && hasDock)
        updateWin(&mTopWin, NSRect(x: live.frame.origin.x, y: live.frame.maxY - args.mT, width: live.frame.width, height: args.mT), args.mT > 0)
        updateWin(&mBottomWin, NSRect(x: live.frame.origin.x, y: live.frame.origin.y, width: live.frame.width, height: args.mB), args.mB > 0)
        updateWin(&mLeftWin, NSRect(x: live.frame.origin.x, y: live.frame.origin.y, width: args.mL, height: live.frame.height), args.mL > 0)
        updateWin(&mRightWin, NSRect(x: live.frame.maxX - args.mR, y: live.frame.origin.y, width: args.mR, height: live.frame.height), args.mR > 0)
    }
    func closeAll() { [topWindow, bottomWindow, mTopWin, mBottomWin, mLeftWin, mRightWin].forEach { $0?.close() }; topWindow=nil; bottomWindow=nil; mTopWin=nil; mBottomWin=nil; mLeftWin=nil; mRightWin=nil }
}

// MARK: - 🧠 主控引擎
@MainActor
class OLEDController: NSObject, ObservableObject {
    private enum PrefKeys {
        static let enableRelaxedMode = "config_enableRelaxedMode"; static let enableStrictMode = "config_enableStrictMode"; static let enableForcedMode = "config_enableForcedMode"
        static let maxIdleX = "config_maxIdleX"; static let maxIdleY = "config_maxIdleY"; static let maxIdleZ = "config_maxIdleZ"
        static let sensitivityArea = "config_sensitivityArea"; static let patrolInterval = "config_patrolInterval"; static let wakeInterval = "config_wakeInterval"; static let resStage1 = "config_resStage1"
        static let targetScreenName = "TargetOLEDName"; static let isMonitoringEnabled = "IsMonitoring"; static let showStatusText = "config_showStatusText"
        static let maskTop = "config_maskTop"; static let maskBottom = "config_maskBottom"; static let maskLeft = "config_maskLeft"; static let maskRight = "config_maskRight"
        static let screenshotShortcuts = "config_screenshotShortcuts"; static let screenshotDelay = "config_screenshotDelay"
        static let enableOverlayTop = "config_enableOverlayTop"; static let enableOverlayBottom = "config_enableOverlayBottom"; static let overlayRestoreDelay = "config_overlayRestoreDelay"
        static let dockSmartBoundary = "config_dockSmartBoundary"; static let dockVisualPadding = "config_dockVisualPadding"; static let topVisualPadding = "config_topVisualPadding"
        static let maskPresets = "config_maskPresets"
        static let manualMaskTop = "config_manualMaskTop"; static let manualMaskBottom = "config_manualMaskBottom"; static let manualMaskLeft = "config_manualMaskLeft"; static let manualMaskRight = "config_manualMaskRight"
        static let deepSleepDelay = "config_deepSleepDelay"; static let deepSleepInterval = "config_deepSleepInterval"; static let deepSleepSensitivity = "config_deepSleepSensitivity"
        
        // 🔥 新增：5个滑块 + 5个开关的键名
        static let enableRelaxedGridLimit = "config_enableRelaxedGridLimit"; static let relaxedGridThreshold = "config_relaxedGridThreshold"
        static let enableStrictGridLimit = "config_enableStrictGridLimit"; static let strictGridThreshold = "config_strictGridThreshold"
        static let enableForcedGridLimit = "config_enableForcedGridLimit"; static let forcedGridThreshold = "config_forcedGridThreshold"
        static let enableStrictDual = "config_enableStrictDual"; static let strictDualThreshold = "config_strictDualThreshold"
        static let enableForcedDual = "config_enableForcedDual"; static let forcedDualThreshold = "config_forcedDualThreshold"
    }

    private var isRestoring: Bool = true
    @Published var statusMessage = "就绪"; @Published var countdownText = ""
    @Published var selectedScreen: NSScreen? { didSet { updateMaskState() } }
    @Published var savedTargetName: String?
    @Published var hasScreenAccess = false; @Published var hasAccessibilityAccess = false
    @Published var showStatusText = true { didSet { if !isRestoring { saveSettings(); updateUIState() } } }
    @Published var isMonitoringEnabled = true { didSet { updateUIState(); checkAndStartLoop(); if !isRestoring { saveSettings() } } }
    
    @Published var enableRelaxedMode = true { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var enableStrictMode = true { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var enableForcedMode = true { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var maxIdleX = 10.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var maxIdleY = 20.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var maxIdleZ = 25.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var sensitivityArea = 1.5 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var patrolInterval = 5.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var resStage1 = 64 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var wakeInterval = 0.5 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var deepSleepDelay = 300.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var deepSleepInterval = 2.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var deepSleepSensitivity = 3.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    
    // 🔥🔥 新增：5组阈值参数 (门槛 + 双轨)
    @Published var enableRelaxedGridLimit = false { didSet { if !isRestoring { saveSettings() } } }
    @Published var relaxedGridThreshold = 2.0 { didSet { if !isRestoring { saveSettings() } } }
    
    @Published var enableStrictGridLimit = false { didSet { if !isRestoring { saveSettings() } } }
    @Published var strictGridThreshold = 6.0 { didSet { if !isRestoring { saveSettings() } } }
    
    @Published var enableForcedGridLimit = false { didSet { if !isRestoring { saveSettings() } } }
    @Published var forcedGridThreshold = 10.0 { didSet { if !isRestoring { saveSettings() } } }
    
    @Published var enableStrictDual = false { didSet { if !isRestoring { saveSettings() } } }
    @Published var strictDualThreshold = 8.0 { didSet { if !isRestoring { saveSettings() } } }
    
    @Published var enableForcedDual = false { didSet { if !isRestoring { saveSettings() } } }
    @Published var forcedDualThreshold = 14.0 { didSet { if !isRestoring { saveSettings() } } }

    @Published var maskTop = 20.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var maskBottom = 20.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var maskLeft = 10.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var maskRight = 10.0 { didSet { if !isRestoring { saveSettings(); restartMonitoring() } } }
    @Published var enableOverlayTop = false { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var enableOverlayBottom = false { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var overlayRestoreDelay = 3.0 { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var dockSmartBoundary = true { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var dockVisualPadding = 0.0 { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var topVisualPadding = 0.0 { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var manualMaskTop = 0.0 { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var manualMaskBottom = 0.0 { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var manualMaskLeft = 0.0 { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var manualMaskRight = 0.0 { didSet { if !isRestoring { saveSettings(); updateMaskState() } } }
    @Published var maskPresets: [MaskPreset] = [] { didSet { if !isRestoring { saveSettings() } } }
    
    private let maskEngine = MaskEngine()
    @Published var isScreenshotActive = false
    @Published var screenshotShortcuts: [ShortcutModel] = []
    @Published var screenshotDelay = 10.0 { didSet { if !isRestoring { saveSettings() } } }
    @Published var isHotkeyIntercepting = false; var eventTap: CFMachPort?
    private var screenshotTimer: Timer?; private var globalKeyMonitor: Any?; private var localKeyMonitor: Any?
    var currentRes = 64;
    var totalIdleSeconds = 0.0 // ⚠️ 注意：仅用于 UI 显示，不再参与逻辑判断
    private var totalBlackSeconds = 0.0
    private var timeSinceLastVisionCheck = 0.0;
    var currentStage: GuardStage = .relaxed
    private var lastPhysicalInputTime = Date(); private var lastMouseLocation = NSPoint.zero
    private var lastVisionActiveTime = Date.distantPast; private var uiFlashToggle = false
    private var loopTask: Task<Void, Never>?; private var lastFrameData: Data?
    private var blackWindow: NSWindow?; private var globalMouseMonitor: Any?, localMouseMonitor: Any?
    private var isCursorHidden = false; private var targetDisplayID: CGDirectDisplayID = 0
    private let softNoiseFloor: Int32 = 2; private let hardNoiseFloor: Int32 = 40

    override init() {
        super.init()
        _ = CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        self.isRestoring = true; loadSettings(); checkPermissions(); self.isRestoring = false
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.handleTopologyChange(); self?.updateMaskState() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateMaskState() } }
        startMouseMonitoring(); setupGlobalKeyMonitoring(); handleTopologyChange(); updateUIState(); checkAndStartLoop()
    }
    
    private func updateMaskState() {
        let args = MaskEngine.MaskUpdateArgs(enableTop: enableOverlayTop, enableBot: enableOverlayBottom, smart: dockSmartBoundary, sysTp: topVisualPadding, sysBp: dockVisualPadding, mT: manualMaskTop, mB: manualMaskBottom, mL: manualMaskLeft, mR: manualMaskRight, delay: overlayRestoreDelay)
        maskEngine.update(target: selectedScreen, args: args)
    }
    private func restartMonitoring() { if blackWindow != nil { resetProtection() }; totalIdleSeconds = 0; totalBlackSeconds = 0; timeSinceLastVisionCheck = 0; currentStage = .relaxed; lastPhysicalInputTime = Date(); lastVisionActiveTime = Date(); checkAndStartLoop(); updateUIState() }
    func checkPermissions() { hasScreenAccess = CGPreflightScreenCaptureAccess(); hasAccessibilityAccess = AXIsProcessTrusted() }
    func startHotkeyCapture() {
        guard hasAccessibilityAccess else { requestAccessibilityPermission(); return }
        self.isHotkeyIntercepting = true
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let ctrl = Unmanaged<OLEDController>.fromOpaque(refcon).takeUnretainedValue()
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
                var nsFlags: NSEvent.ModifierFlags = []
                if flags.contains(.maskCommand) { nsFlags.insert(.command) }
                if flags.contains(.maskShift) { nsFlags.insert(.shift) }
                if flags.contains(.maskAlternate) { nsFlags.insert(.option) }
                if flags.contains(.maskControl) { nsFlags.insert(.control) }
                DispatchQueue.main.async {
                    let newS = ShortcutModel(keyCode: UInt16(keyCode), modifierRaw: nsFlags.rawValue)
                    if !ctrl.screenshotShortcuts.contains(where: { $0.keyCode == newS.keyCode && $0.modifierRaw == newS.modifierRaw }) { ctrl.screenshotShortcuts.append(newS) }
                    ctrl.stopHotkeyCapture()
                }
                return nil
            }
            return Unmanaged.passRetained(event)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: callback, userInfo: userInfo) {
            self.eventTap = tap; let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes); CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    func stopHotkeyCapture() { self.isHotkeyIntercepting = false; if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); eventTap = nil } }
    func requestScreenRecordingPermission() { Task { let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true); if let display = content?.displays.first { let cfg = SCStreamConfiguration(); cfg.width = 10; cfg.height = 10; _ = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg) }; checkPermissions(); updateUIState() } }
    func requestAccessibilityPermission() { let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]; _ = AXIsProcessTrustedWithOptions(options as CFDictionary); let mask = CGEventMask(1 << CGEventType.keyDown.rawValue); if let dummy = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _,_,e,_ in Unmanaged.passUnretained(e) }, userInfo: nil) { CFMachPortInvalidate(dummy) }; if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }; checkPermissions(); updateUIState() }

    private func checkScreenChange(screen: NSScreen, currentSensitivity: Double) async throws -> VisionStatus {
            let deadStatus = VisionStatus(isRelaxedOk: false, isStrictOk: false, isForcedOk: false, isHugeChange: false, activeGridCount: 0)
            if isScreenshotActive && !NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) { return deadStatus }
            let deviceID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == deviceID }) else { return deadStatus }
            
            // 遮罩区域计算
            let mTop = Double(display.height) * (maskTop / 100.0), mBottom = Double(display.height) * (maskBottom / 100.0)
            let mLeft = Double(display.width) * (maskLeft / 100.0), mRight = Double(display.width) * (maskRight / 100.0)
            let safeW = max(100, Double(display.width) - mLeft - mRight), safeH = max(100, Double(display.height) - mTop - mBottom)
            
            let config = SCStreamConfiguration(); config.width = currentRes; config.height = currentRes; config.pixelFormat = kCVPixelFormatType_32BGRA
            config.sourceRect = CGRect(x: mLeft, y: mTop, width: safeW, height: safeH); config.showsCursor = false
            var exclude: [SCWindow] = []
            if let bw = blackWindow, let scW = content.windows.first(where: { $0.windowID == CGWindowID(bw.windowNumber) }) { exclude.append(scW) }
            
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: exclude), configuration: config)
            guard let dp = image.dataProvider, let raw = dp.data else { return deadStatus }
            let curData = Data(referencing: raw); defer { lastFrameData = curData }
            guard let old = lastFrameData, old.count == curData.count else { return deadStatus }
            
            var hard = 0, soft = 0, gridPixelCounts = [Int: Int](), res = currentRes
            
            curData.withUnsafeBytes { cP in old.withUnsafeBytes { oP in
                guard let c = cP.baseAddress?.assumingMemoryBound(to: UInt8.self), let o = oP.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                
                // 遍历像素
                for i in stride(from: 0, to: curData.count, by: 4) {
                    let diff = abs(Int32(c[i])-Int32(o[i])) + abs(Int32(c[i+1])-Int32(o[i+1])) + abs(Int32(c[i+2])-Int32(o[i+2]))
                    if diff > softNoiseFloor {
                        soft += 1
                        if diff > hardNoiseFloor { hard += 1 }
                        
                        // 🔥🔥 [修改 1] 6x6 网格坐标映射算法
                        // 使用乘法 (idx * 6 / res) 确保在任何分辨率(如64/128)下都能均匀映射到 0~5，避免除法整除的边界误差
                        let idx = i / 4
                        let gx = ((idx % res) * 6) / res
                        let gy = ((idx / res) * 6) / res
                        
                        // 🔥🔥 [修改 2] 6x6 网格索引计算 (gy * 6 + gx)
                        gridPixelCounts[gy * 6 + gx, default: 0] += 1
                    }
                }
            }}
            
            let K: Double = 0.81 / max(0.01, (safeW / Double(display.width)) * (safeH / Double(display.height)))
            let relaxed = (soft > Int(Double(res * res) * (currentSensitivity / 100.0) * K)) || (hard > Int(5.0 * K))
            
            var activeGrids = Set<Int>()
            
            // 🔥🔥 [修改 3] 单格阈值计算 (总面积 / 36 * 10%)
            // 4x4 是 /16，这里改为 /36.0 以适应更精细的网格
            let threshold = Int((Double(res * res) / 36.0) * 0.10)
            
            for (idx, count) in gridPixelCounts { if count > threshold { activeGrids.insert(idx) } }
            
            // 🔥🔥 [修改 4] 严格模式中心判定
            // 6x6 网格的中心四个格子坐标是 (2,2), (2,3), (3,2), (3,3)
            // 对应索引值：
            // 2*6+2=14, 2*6+3=15
            // 3*6+2=20, 3*6+3=21
            let strict = activeGrids.count >= 2 || !activeGrids.isDisjoint(with: [14, 15, 20, 21])
            
            // 强制模式判定 (建议维持 >= 8，在 36 格中 8 格占比约 22%，比 4x4 时的 50% 更容易触发，符合"不够"的需求)
            let forced = activeGrids.count >= 8
            
            let isHugeChange = soft > Int(Double(res * res) * 0.50)
            
            return VisionStatus(isRelaxedOk: relaxed, isStrictOk: strict, isForcedOk: forced, isHugeChange: isHugeChange, activeGridCount: activeGrids.count)
        }
    func startLoop() {
        loopTask?.cancel(); loopTask = Task {
            while !Task.isCancelled {
                // 动态频率
                let isDeep = (blackWindow != nil && totalBlackSeconds >= deepSleepDelay)
                let sleepTime = (blackWindow == nil) ? patrolInterval : (isDeep ? deepSleepInterval : wakeInterval)
                let actualSleep = max(0.1, sleepTime)
                try? await Task.sleep(nanoseconds: UInt64(actualSleep * 1_000_000_000))
                
                if blackWindow == nil {
                    // 仅用于UI显示的累加，核心逻辑用 Date() 计算
                } else {
                    totalBlackSeconds += actualSleep
                }
                
                let currentSens = isDeep ? deepSleepSensitivity : sensitivityArea
                await performVisionCheck(sens: currentSens)
                
                await MainActor.run { self.uiFlashToggle.toggle(); self.updateUIState() }
            }
        }
    }

    // 🔥🔥🔥 [1.7.9 完美逻辑版] 动态时间轴 + 当前标准优先晋升 + 拒绝假死
        private func performVisionCheck(sens: Double) async {
            guard let screen = selectedScreen, hasScreenAccess else { return }
            do {
                // 1. 获取视觉信号
                let vStatus = try await checkScreenChange(screen: screen, currentSensitivity: sens)
                if vStatus.isHugeChange { handlePhysicalActivity(); return }

                // =========================================================
                // 🧱 第一步：构建动态时间轴 & 确定目标 (Target Stage)
                // 完美支持 7 种模式任意组合，关闭即删除时间段
                // =========================================================
                
                let physicalIdle = Date().timeIntervalSince(lastPhysicalInputTime)
                
                // 1.1 计算各阶段的"有效时长" (没开就是 0)
                let durRelaxed = enableRelaxedMode ? maxIdleX : 0
                let durStrict = enableStrictMode ? maxIdleY : 0
                let durForced = enableForcedMode ? maxIdleZ : 0
                
                // 1.2 计算时间轴里程碑
                let limit1 = durRelaxed
                let limit2 = limit1 + durStrict
                let limit3 = limit2 + durForced
                
                // 1.3 确定理论落点
                var targetStage: GuardStage = .relaxed
                
                if blackWindow == nil {
                    if physicalIdle < limit1 {
                        targetStage = .relaxed
                    } else if physicalIdle < limit2 {
                        targetStage = .strict
                    } else if physicalIdle < limit3 {
                        targetStage = .forced
                    } else {
                        // 封顶逻辑：时间耗尽，停留在最高开启模式
                        if enableForcedMode { targetStage = .forced }
                        else if enableStrictMode { targetStage = .strict }
                        else { targetStage = .relaxed }
                    }
                } else {
                    targetStage = currentStage // 黑屏时保持身份
                }
                
                // =========================================================
                // 👁️ 第二步：视觉考核 (Check Pass)
                // 🔥 关键修复：晋升时使用"当前标准"，稳定时使用"目标标准"
                // =========================================================

                var isPass = false
                
                // 核心逻辑：如果你正在申请晋升，我应该用你现在的身份(current)来考核你是否"活着"。
                // 如果你活着，我就让你进下一关。进了下一关，再用新规矩管你。
                // 这样防止了"因为达不到新规矩而被旧规矩处死"的冤案。
                let stageForRules = (currentStage != targetStage) ? currentStage : targetStage
                
                // 特殊情况：如果黑屏，强制使用当前身份（因为 targetStage 在黑屏时可能不准确或被锁死）
                let finalCheckStage = (blackWindow != nil) ? currentStage : stageForRules
                
                switch finalCheckStage {
                case .relaxed:
                    // 宽松标准：关开关->灵敏度；开开关->网格
                    if enableRelaxedGridLimit {
                        isPass = vStatus.activeGridCount >= Int(relaxedGridThreshold)
                    } else {
                        isPass = vStatus.isRelaxedOk
                    }
                case .strict:
                    if enableStrictGridLimit {
                        isPass = vStatus.activeGridCount >= Int(strictGridThreshold)
                    } else {
                        isPass = vStatus.isRelaxedOk
                    }
                case .forced:
                    if enableForcedGridLimit {
                        isPass = vStatus.activeGridCount >= Int(forcedGridThreshold)
                    } else {
                        isPass = vStatus.isRelaxedOk
                    }
                }
                
                // =========================================================
                // 分支 A: 屏幕黑着 (申请复活)
                // =========================================================
                if blackWindow != nil {
                    if !isPass { return }
                    
                    // 宽松复活逻辑
                    if currentStage == .relaxed {
                        handlePhysicalActivity()
                        return
                    }
                    
                    // 严格/强制复活逻辑 (双轨)
                    var dualThreshold = Int.max
                    var dualEnabled = false
                    if currentStage == .strict {
                        dualEnabled = enableStrictDual; dualThreshold = Int(strictDualThreshold)
                    } else if currentStage == .forced {
                        dualEnabled = enableForcedDual; dualThreshold = Int(forcedDualThreshold)
                    }
                    
                    if dualEnabled && vStatus.activeGridCount > dualThreshold {
                        handlePhysicalActivity() // 大动静
                    } else {
                        resetProtection()
                        // 醒来重置物理时间：回到 targetStage 的起点
                        if currentStage == .strict {
                            lastPhysicalInputTime = Date() - limit1
                        } else if currentStage == .forced {
                            lastPhysicalInputTime = Date() - limit2
                        }
                        lastVisionActiveTime = Date()
                        await MainActor.run {
                            self.totalIdleSeconds = 0
                            self.updateUIState()
                        }
                    }
                    return
                }

                // =========================================================
                // 分支 B: 屏幕亮着 (处理晋升/续命/处决)
                // =========================================================
                
                if isPass {
                    // ✅ 视觉活跃 -> 晋升或续命
                    
                    let isPromoting = (currentStage != targetStage)
                    
                    if isPromoting {
                        await MainActor.run {
                            self.currentStage = targetStage
                            self.updateUIState()
                        }
                    }
                    
                    // 重置视觉倒计时 (免死金牌)
                    lastVisionActiveTime = Date()
                    await MainActor.run { self.totalIdleSeconds = 0 }
                    
                    // 封顶锁死逻辑 (防止物理时间溢出)
                    let isAtCeiling = (targetStage == .relaxed && !enableStrictMode && !enableForcedMode) ||
                                      (targetStage == .strict && !enableForcedMode) ||
                                      (targetStage == .forced)
                    
                    if isAtCeiling {
                        if targetStage == .relaxed {
                            lastPhysicalInputTime = Date()
                        } else if targetStage == .strict {
                            lastPhysicalInputTime = Date() - limit1
                        } else if targetStage == .forced {
                            lastPhysicalInputTime = Date() - limit2
                        }
                    }
                    
                } else {
                    // ❌ 视觉不活跃
                    // 只有在这里，才去检查是否该处决。
                    // 只要 isPass 为真（哪怕是宽松标准），上面代码就会重置 timer，这里就不会跑进来。
                    
                    let currentVisualIdle = Date().timeIntervalSince(lastVisionActiveTime)
                    
                    var currentLimit = maxIdleX
                    switch currentStage {
                    case .relaxed: currentLimit = maxIdleX
                    case .strict: currentLimit = maxIdleY
                    case .forced: currentLimit = maxIdleZ
                    }
                    
                    if currentVisualIdle >= currentLimit {
                        handleScreenOff()
                    } else {
                        // 时间未到，更新UI
                        await MainActor.run { self.totalIdleSeconds = currentVisualIdle }
                    }
                }
                
            } catch { }
        }
    func handleScreenOff() { if let s = selectedScreen { lastFrameData = nil; showBlack(on: s) } }
    // 🔥🔥🔥 [修复重置逻辑] 动态回到"第一开启模式"，而非强制回宽松
        func handlePhysicalActivity() {
            // 1. 重置物理时间锚点
            lastPhysicalInputTime = Date()
            
            // 2. 重置计数器
            totalIdleSeconds = 0
            totalBlackSeconds = 0
            
            // 3. 🔥 关键修复：根据开启的模式，决定"起点"是谁
            // 既然键鼠动了，就应该回到用户定义的"第一阶段"，而不是写死的宽松模式
            if enableRelaxedMode {
                currentStage = .relaxed
            } else if enableStrictMode {
                currentStage = .strict
            } else {
                currentStage = .forced
            }
            
            // 4. 重置视觉时间
            lastVisionActiveTime = Date()
            
            // 5. 恢复屏幕 (如果是黑屏状态)
            if blackWindow != nil {
                resetProtection()
            }
            
            // 6. 刷新 UI
            updateUIState()
        }
    func checkAndStartLoop() { if isMonitoringEnabled && hasScreenAccess && selectedScreen != nil { startLoop() } else { loopTask?.cancel(); loopTask = nil } }
    func updateUIState() {
        if !hasScreenAccess { countdownText = "权限"; return }; if selectedScreen == nil { countdownText = "断联"; return }
        if !showStatusText { countdownText = "" } else {
            if isScreenshotActive { countdownText = "SNAP" } else if !isMonitoringEnabled { countdownText = "暂停" } else if blackWindow != nil { countdownText = (totalBlackSeconds >= deepSleepDelay) ? "深度" : "浅睡" }
            else {
                var limit = maxIdleX; var name = "宽松"
                switch currentStage { case .relaxed: limit = maxIdleX; name = "宽松"; case .strict: limit = maxIdleY; name = "严格"; case .forced: limit = maxIdleZ; name = "强制" }
                let rem = Int(max(0, limit - totalIdleSeconds))
                let isActive = Date().timeIntervalSince(lastVisionActiveTime) <= (patrolInterval + 1.0)
                countdownText = (isActive && uiFlashToggle) ? "活跃" : "\(name):\(rem)s"
            }
        }
        statusMessage = isScreenshotActive ? "截图保护中" : (blackWindow != nil ? "保护运行中" : "监控中")
    }
    func resetProtection() { blackWindow?.orderOut(nil); blackWindow = nil; timeSinceLastVisionCheck = 0; totalBlackSeconds = 0; if isCursorHidden { CGDisplayShowCursor(targetDisplayID != 0 ? targetDisplayID : CGMainDisplayID()); isCursorHidden = false }; updateUIState() }
    func showBlack(on screen: NSScreen) { guard blackWindow == nil else { return }; self.targetDisplayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID(); let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false); w.backgroundColor = .black; w.level = .screenSaver; w.orderFront(nil); w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; if NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) { CGDisplayHideCursor(self.targetDisplayID); isCursorHidden = true }; blackWindow = w; totalBlackSeconds = 0; updateUIState() }
    
    private func setupGlobalKeyMonitoring() { let handler: (NSEvent) -> Void = { [weak self] event in Task { @MainActor in self?.handleKeyDown(event) } }; globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler); localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in handler(event); return event } }
    private func handleKeyDown(_ event: NSEvent) { if isHotkeyIntercepting { return }; if isScreenshotActive { if event.keyCode == 36 || event.keyCode == 53 { exitScreenshotMode(); return } }; if let s = selectedScreen, let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value, let main = NSScreen.main, let mId = (main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value, id == mId { handlePhysicalActivity() }; let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue; if screenshotShortcuts.contains(where: { $0.keyCode == event.keyCode && $0.modifierRaw == flags }) { enterScreenshotMode() } }
    func exitScreenshotMode() { isScreenshotActive = false; screenshotTimer?.invalidate(); screenshotTimer = nil; updateUIState() }
    private func enterScreenshotMode() { isScreenshotActive = true; screenshotTimer?.invalidate(); screenshotTimer = Timer.scheduledTimer(withTimeInterval: screenshotDelay, repeats: false) { [weak self] _ in Task { @MainActor in self?.exitScreenshotMode() } }; updateUIState() }
    private func startMouseMonitoring() { let h: (NSEvent) -> Void = { [weak self] event in Task { @MainActor in self?.handleMouseEvent(event) } }; globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .scrollWheel], handler: h); localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { e in h(e); return e } }
    private func handleMouseEvent(_ event: NSEvent) {
        guard isMonitoringEnabled, let screen = selectedScreen else { return }; let loc = NSEvent.mouseLocation, f = screen.frame
        if blackWindow != nil && targetDisplayID != 0 { if NSMouseInRect(loc, f, false) { if !isCursorHidden { CGDisplayHideCursor(targetDisplayID); isCursorHidden = true } } else { if isCursorHidden { CGDisplayShowCursor(targetDisplayID); isCursorHidden = false } } }
        if NSMouseInRect(loc, f, false) { let safe = CGRect(x: f.origin.x + f.width*(maskLeft/100), y: f.origin.y + f.height*(maskBottom/100), width: f.width*(1-(maskLeft+maskRight)/100), height: f.height*(1-(maskTop+maskBottom)/100)); if NSMouseInRect(loc, safe, false) { if event.type == .scrollWheel { if abs(event.deltaY) > 0 || abs(event.deltaX) > 0 { handlePhysicalActivity() } } else if hypot(loc.x - lastMouseLocation.x, loc.y - lastMouseLocation.y) > 1.0 { lastMouseLocation = loc; handlePhysicalActivity() } } }
    }
    
    func saveCurrentAsPreset(name: String) { maskPresets.append(MaskPreset(name: name, topPadding: topVisualPadding, bottomPadding: dockVisualPadding, mTop: manualMaskTop, mBottom: manualMaskBottom, mLeft: manualMaskLeft, mRight: manualMaskRight)); saveSettings() }
    func applyPreset(_ preset: MaskPreset) { self.topVisualPadding = preset.topPadding; self.dockVisualPadding = preset.bottomPadding; self.manualMaskTop = preset.mTop; self.manualMaskBottom = preset.mBottom; self.manualMaskLeft = preset.mLeft; self.manualMaskRight = preset.mRight; updateMaskState() }
    func deletePreset(_ preset: MaskPreset) { maskPresets.removeAll(where: { $0.id == preset.id }); saveSettings() }
    
    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(isMonitoringEnabled, forKey: PrefKeys.isMonitoringEnabled); d.set(showStatusText, forKey: PrefKeys.showStatusText)
        d.set(enableRelaxedMode, forKey: PrefKeys.enableRelaxedMode); d.set(enableStrictMode, forKey: PrefKeys.enableStrictMode); d.set(enableForcedMode, forKey: PrefKeys.enableForcedMode)
        d.set(maxIdleX, forKey: PrefKeys.maxIdleX); d.set(maxIdleY, forKey: PrefKeys.maxIdleY); d.set(maxIdleZ, forKey: PrefKeys.maxIdleZ)
        d.set(sensitivityArea, forKey: PrefKeys.sensitivityArea); d.set(patrolInterval, forKey: PrefKeys.patrolInterval); d.set(resStage1, forKey: PrefKeys.resStage1)
        d.set(maskTop, forKey: PrefKeys.maskTop); d.set(maskBottom, forKey: PrefKeys.maskBottom); d.set(maskLeft, forKey: PrefKeys.maskLeft); d.set(maskRight, forKey: PrefKeys.maskRight)
        if let data = try? JSONEncoder().encode(screenshotShortcuts) { d.set(data, forKey: PrefKeys.screenshotShortcuts) }
        if let name = savedTargetName { d.set(name, forKey: PrefKeys.targetScreenName) }
        d.set(enableOverlayTop, forKey: PrefKeys.enableOverlayTop); d.set(enableOverlayBottom, forKey: PrefKeys.enableOverlayBottom); d.set(overlayRestoreDelay, forKey: PrefKeys.overlayRestoreDelay)
        d.set(dockSmartBoundary, forKey: PrefKeys.dockSmartBoundary); d.set(dockVisualPadding, forKey: PrefKeys.dockVisualPadding); d.set(topVisualPadding, forKey: PrefKeys.topVisualPadding)
        d.set(manualMaskTop, forKey: PrefKeys.manualMaskTop); d.set(manualMaskBottom, forKey: PrefKeys.manualMaskBottom); d.set(manualMaskLeft, forKey: PrefKeys.manualMaskLeft); d.set(manualMaskRight, forKey: PrefKeys.manualMaskRight)
        if let data = try? JSONEncoder().encode(maskPresets) { d.set(data, forKey: PrefKeys.maskPresets) }
        d.set(wakeInterval, forKey: PrefKeys.wakeInterval); d.set(deepSleepDelay, forKey: PrefKeys.deepSleepDelay)
        d.set(deepSleepInterval, forKey: PrefKeys.deepSleepInterval); d.set(deepSleepSensitivity, forKey: PrefKeys.deepSleepSensitivity)
        
        // 🔥 保存5+5参数
        d.set(enableRelaxedGridLimit, forKey: PrefKeys.enableRelaxedGridLimit); d.set(relaxedGridThreshold, forKey: PrefKeys.relaxedGridThreshold)
        d.set(enableStrictGridLimit, forKey: PrefKeys.enableStrictGridLimit); d.set(strictGridThreshold, forKey: PrefKeys.strictGridThreshold)
        d.set(enableForcedGridLimit, forKey: PrefKeys.enableForcedGridLimit); d.set(forcedGridThreshold, forKey: PrefKeys.forcedGridThreshold)
        d.set(enableStrictDual, forKey: PrefKeys.enableStrictDual); d.set(strictDualThreshold, forKey: PrefKeys.strictDualThreshold)
        d.set(enableForcedDual, forKey: PrefKeys.enableForcedDual); d.set(forcedDualThreshold, forKey: PrefKeys.forcedDualThreshold)
    }
    private func loadSettings() {
        let d = UserDefaults.standard
        isMonitoringEnabled = d.bool(forKey: PrefKeys.isMonitoringEnabled); showStatusText = d.object(forKey: PrefKeys.showStatusText) as? Bool ?? true
        enableRelaxedMode = d.object(forKey: PrefKeys.enableRelaxedMode) as? Bool ?? true; enableStrictMode = d.object(forKey: PrefKeys.enableStrictMode) as? Bool ?? true; enableForcedMode = d.object(forKey: PrefKeys.enableForcedMode) as? Bool ?? false
        maxIdleX = d.object(forKey: PrefKeys.maxIdleX) as? Double ?? 10.0; maxIdleY = d.object(forKey: PrefKeys.maxIdleY) as? Double ?? 20.0; maxIdleZ = d.object(forKey: PrefKeys.maxIdleZ) as? Double ?? 25.0
        enableOverlayTop = d.bool(forKey: PrefKeys.enableOverlayTop); enableOverlayBottom = d.bool(forKey: PrefKeys.enableOverlayBottom); overlayRestoreDelay = d.object(forKey: PrefKeys.overlayRestoreDelay) as? Double ?? 3.0
        dockSmartBoundary = d.object(forKey: PrefKeys.dockSmartBoundary) as? Bool ?? true; dockVisualPadding = d.double(forKey: PrefKeys.dockVisualPadding); topVisualPadding = d.double(forKey: PrefKeys.topVisualPadding)
        manualMaskTop = d.double(forKey: PrefKeys.manualMaskTop); manualMaskBottom = d.double(forKey: PrefKeys.manualMaskBottom); manualMaskLeft = d.double(forKey: PrefKeys.manualMaskLeft); manualMaskRight = d.double(forKey: PrefKeys.manualMaskRight)
        if let data = d.data(forKey: PrefKeys.maskPresets), let list = try? JSONDecoder().decode([MaskPreset].self, from: data) { maskPresets = list }
        if d.object(forKey: PrefKeys.sensitivityArea) != nil {
            sensitivityArea = d.double(forKey: PrefKeys.sensitivityArea); patrolInterval = d.double(forKey: PrefKeys.patrolInterval); resStage1 = d.integer(forKey: PrefKeys.resStage1); currentRes = resStage1
            maskTop = d.double(forKey: PrefKeys.maskTop); maskBottom = d.double(forKey: PrefKeys.maskBottom); maskLeft = d.double(forKey: PrefKeys.maskLeft); maskRight = d.double(forKey: PrefKeys.maskRight); savedTargetName = d.string(forKey: PrefKeys.targetScreenName)
            if let data = d.data(forKey: PrefKeys.screenshotShortcuts), let list = try? JSONDecoder().decode([ShortcutModel].self, from: data) { screenshotShortcuts = list }
            wakeInterval = d.double(forKey: PrefKeys.wakeInterval); if wakeInterval == 0 { wakeInterval = 0.5 }
            deepSleepDelay = d.double(forKey: PrefKeys.deepSleepDelay); if deepSleepDelay == 0 { deepSleepDelay = 300.0 }
            deepSleepInterval = d.double(forKey: PrefKeys.deepSleepInterval); if deepSleepInterval == 0 { deepSleepInterval = 2.0 }
            deepSleepSensitivity = d.double(forKey: PrefKeys.deepSleepSensitivity); if deepSleepSensitivity == 0 { deepSleepSensitivity = 3.0 }
            
            // 🔥 读取5+5参数
            if d.object(forKey: PrefKeys.enableRelaxedGridLimit) != nil {
                enableRelaxedGridLimit = d.bool(forKey: PrefKeys.enableRelaxedGridLimit); relaxedGridThreshold = d.double(forKey: PrefKeys.relaxedGridThreshold)
                enableStrictGridLimit = d.bool(forKey: PrefKeys.enableStrictGridLimit); strictGridThreshold = d.double(forKey: PrefKeys.strictGridThreshold)
                enableForcedGridLimit = d.bool(forKey: PrefKeys.enableForcedGridLimit); forcedGridThreshold = d.double(forKey: PrefKeys.forcedGridThreshold)
                enableStrictDual = d.bool(forKey: PrefKeys.enableStrictDual); strictDualThreshold = d.double(forKey: PrefKeys.strictDualThreshold)
                enableForcedDual = d.bool(forKey: PrefKeys.enableForcedDual); forcedDualThreshold = d.double(forKey: PrefKeys.forcedDualThreshold)
            }
        }
    }
    
    private func handleTopologyChange() {
        let all = NSScreen.screens
        if let name = savedTargetName, let new = all.first(where: { $0.localizedName == name }) {
            selectedScreen = new
            if blackWindow != nil { resetProtection(); showBlack(on: new) }
        } else { resetProtection(); selectedScreen = nil }
        updateUIState(); checkAndStartLoop()
    }
    
    func saveSelection(screen: NSScreen) { selectedScreen = screen; savedTargetName = screen.localizedName; saveSettings(); restartMonitoring() }
}

struct KeyCodeHelper {
    static func name(for code: UInt16) -> String {
        let map: [UInt16: String] = [0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"Enter", 37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"Tab", 49:"Space", 50:"`", 51:"Delete", 53:"Esc", 123:"←", 124:"→", 125:"↓", 126:"↑"]
        return map[code] ?? "#\(code)"
    }
}
