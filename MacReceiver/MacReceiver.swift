// The receiver (issues #82/#17): this Mac listens exactly like the iPhone
// does — Bonjour-advertised TCP listener, hello with its own panel size — and
// renders the incoming stream, so a spare Mac becomes a display for another
// Mac. The pipeline is the shared StreamReceiver core; this file is only the
// AppKit shell around it: lifecycle, the video window, cursor drawing, and
// keeping the machine awake while it serves as a screen. It ships as its own
// app (OpenSidecarMacReceiver target, macOS 12+) so old Macs can be displays,
// and inside the sender app, which then is one app for both roles.
//
// Each physical screen is its own receiver: one Bonjour service, port and
// window per screen, so a sender can use every screen of this Mac. The main
// screen keeps the install id, the plain name and port 9000.
//
// The one app also shows and hides the windows for KVM (Mac/KVM.swift),
// through `kvmVisible`. The receiver app leaves it nil.

import AppKit
import AVFoundation
import VideoToolbox
import Combine
import IOKit.pwr_mgt
import SwiftUI

@MainActor
final class ReceiverController: ObservableObject {
    static let shared = ReceiverController()

    // The main screen's receiver, for the panel. Nil whenever receiver mode
    // is off.
    @Published private(set) var receiver: StreamReceiver?
    // Summaries for views that don't observe the receiver itself (menu bar
    // icon, status bar): a sender is connected / frames are on screen, on
    // any screen.
    @Published private(set) var connected = false
    @Published private(set) var streaming = false

    var active: Bool { !screens.isEmpty }

    /// One receiver per physical screen.
    private(set) var screens: [ScreenReceiver] = []

    /// KVM (the one app only): nil shows each stream as the receiver app
    /// does; true shows every stream over its whole screen; false hides them.
    var kvmVisible: Bool? {
        didSet { if kvmVisible != oldValue { screens.forEach { $0.kvmChanged() } } }
    }

    /// What the receiver offers in hello; set before start().
    var powerActions = PowerControl.supported

    let fullscreenPreference = FullscreenPreference()
    private var sleepActivity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var screenSleepObservers: [NSObjectProtocol] = []

    private var fallbackName: String { Host.current().localizedName ?? "Mac" }
    fileprivate var advertisedName: String {
        let saved = UserDefaults.standard.string(forKey: "receiverName")
        return (saved?.isEmpty == false) ? saved! : fallbackName
    }

    /// Whether a Bonjour record is this Mac's own receiver. The install id
    /// matches only in the one app; the computer name also catches the
    /// separate receiver app running next to a sender on the same Mac.
    func isOwnService(id: String?, name: String?) -> Bool {
        let own = StreamReceiver.installID
        if let id, id == own || id.hasPrefix(own + ".") { return true }
        guard let name else { return false }
        return screens.contains { $0.receiver.serviceName == name }
            || name == fallbackName || name.hasPrefix(fallbackName + " (")
    }

    func start() {
        guard screens.isEmpty else { return }
        syncScreens()

        // The receiving Mac's own panel went dark (idle sleep, lid) — nobody
        // can see the stream, so tell the sender exactly like a locked
        // iPhone does; it drops its display and arms a reconnect. On wake
        // the listener comes back and the sender redials.
        let workspace = NSWorkspace.shared.notificationCenter
        screenSleepObservers = [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                  object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    Log.info("screens slept — announcing sleeping to the sender")
                    self?.screens.forEach { $0.receiver.enterSleep() }
                }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                  object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.screens.forEach { $0.receiver.ensureListening() } }
            },
        ]

        // Display-mode changes move the goalposts mid-session (the announced
        // panel is the sender's virtual-display size) — re-announce, the
        // sender rebuilds. The Mac analogue of iPhone rotation. A screen
        // plugged in or out gains or loses its receiver.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.syncScreens()
            }
        }
        Log.info("receiver mode started (advertising "
                 + screens.map { "\"\($0.receiver.serviceName)\"" }.joined(separator: ", ") + ")")
    }

    /// Leave receiver mode. `completion` fires once "closing" has gone out
    /// to every live sender (or a second has passed) — the quit path waits
    /// on it so the sender ends its session instead of retrying a dead peer.
    func stop(completion: (() -> Void)? = nil) {
        guard active else { completion?(); return }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        let workspace = NSWorkspace.shared.notificationCenter
        screenSleepObservers.forEach { workspace.removeObserver($0) }
        screenSleepObservers = []
        let group = DispatchGroup()
        for screen in screens {
            group.enter()
            screen.stop { group.leave() }
        }
        group.notify(queue: .main) { completion?() }
        screens = []
        receiver = nil
        connected = false
        streaming = false
        updateSleepAssertion(false)
        Log.info("receiver mode stopped")
    }

    /// Re-published name from the panel's text field. Empty falls back to the
    /// computer name (mirrors the iOS Settings behavior).
    func setAdvertisedName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "receiverName")
        screens.forEach { $0.receiver.setServiceName($0.name(for: advertisedName)) }
    }

    /// Bring the video windows (back) up — the panel button for when the
    /// user closed a window while the stream keeps running.
    func showWindow() {
        screens.forEach { $0.showWindow() }
    }

    /// One receiver per physical screen: a new screen gets one, a gone
    /// screen's one stops, the others re-announce their panel.
    private func syncScreens() {
        let now = Self.physicalScreens()
        for gone in screens where !now.contains(where: { $0.key == gone.key }) {
            Log.info("screen \(gone.key) gone — stopping its receiver")
            gone.stop(completion: nil)
        }
        screens.removeAll { unit in !now.contains { $0.key == unit.key } }
        for (displayID, key) in now {
            if let unit = screens.first(where: { $0.key == key }) {
                unit.displayID = displayID
                unit.announce()
                continue
            }
            // The first screen keeps the identity a sender already knows.
            let main = !screens.contains { $0.main }
            var port: UInt16 = 9000
            if !main {
                port = 9002
                while screens.contains(where: { $0.port == port }) { port += 2 }
            }
            let unit = ScreenReceiver(controller: self, key: key, displayID: displayID,
                                      main: main, port: port)
            screens.append(unit)
            if main { receiver = unit.receiver }
        }
        if let first = screens.first(where: { $0.main }) ?? screens.first { receiver = first.receiver }
        refresh()
    }

    /// Physical screens, the main one first: no virtual display this app made
    /// for its own sender, no mirror. The key stays the same across replugs.
    private static func physicalScreens() -> [(id: CGDirectDisplayID, key: String)] {
        var result: [(id: CGDirectDisplayID, key: String)] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  CGDisplayVendorNumber(id) != 0x5043,   // VirtualDisplay's vendor id
                  CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { continue }
            var key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            if result.contains(where: { $0.key == key }) { key += "-\(id)" }
            result.append((id, key))
        }
        return result
    }

    /// Called by each screen when its connection or stream changes.
    fileprivate func refresh() {
        connected = screens.contains { $0.receiver.connected }
        let nowStreaming = screens.contains { $0.streaming }
        if nowStreaming != streaming {
            streaming = nowStreaming
            updateSleepAssertion(nowStreaming)
        }
    }

    /// The sender asked this Mac to power off (PROTOCOL.md 6.6). Say
    /// "closing" first, so the sender ends the session instead of redialing
    /// a Mac that is going away.
    fileprivate func perform(_ action: PowerAction, via receiver: StreamReceiver) {
        Log.info("power \(action.rawValue): saying goodbye to the sender")
        switch action {
        case .shutdown:
            receiver.shutDown {
                DispatchQueue.main.async {
                    PowerControl.perform(.shutdown)
                    // An app with unsaved changes can cancel the shutdown:
                    // take the listener back so this Mac is a display again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                        self?.screens.forEach { $0.receiver.ensureListening() }
                    }
                }
            }
        }
    }

    // MARK: - Stay awake

    /// This Mac *is* the display while a sender streams — never let it doze,
    /// and wake it up when the stream starts. beginActivity only prevents
    /// *future* idle sleep; a spare Mac with no keyboard has usually gone
    /// dark by the time a sender connects, and frames into a black panel
    /// looked like nothing worked at all. Declaring user activity is what
    /// actually lights the display again.
    private func updateSleepAssertion(_ receiving: Bool) {
        if receiving, sleepActivity == nil {
            var assertionID = IOPMAssertionID(0)
            IOPMAssertionDeclareUserActivity(
                "OpenDisplay stream started" as CFString,
                kIOPMUserActiveLocal, &assertionID)
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "OpenDisplay is receiving a display stream")
        } else if !receiving, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}

// MARK: - One screen as a display

/// One physical screen of this Mac as a display: its receiver (listener,
/// Bonjour service, decoder) and its video window.
@MainActor
final class ScreenReceiver {
    let key: String
    let main: Bool
    let port: UInt16
    var displayID: CGDirectDisplayID
    let receiver: StreamReceiver
    private(set) var streaming = false

    private unowned let controller: ReceiverController
    private var window: NSWindow?
    // The window is the borderless KVM one, not the normal one.
    private var kvmWindow = false
    private var cancellables = Set<AnyCancellable>()
    private var windowObservers: [NSObjectProtocol] = []
    private var windowCloseTimer: DispatchWorkItem?

    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    init(controller: ReceiverController, key: String, displayID: CGDirectDisplayID,
         main: Bool, port: UInt16) {
        self.controller = controller
        self.key = key
        self.displayID = displayID
        self.main = main
        self.port = port
        // Legacy senders understand only this rectangle; new senders also
        // receive it as an H.264 capability and intersect it with their own
        // codec constraints. 4096x2304 is the practical H.264 hardware-decode
        // ceiling measured across Intel and Apple-silicon Macs, rather than an
        // iMac-model exception.
        //
        // With a hardware HEVC decoder we also offer HEVC up to 5120x2880, so
        // 4K and 5K panels can be sent 1:1 (the sender prefers HEVC). 5K is the
        // largest raster measured live, on the oldest such Mac tested (a 2017
        // Intel iMac); larger panels get a 5K stream scaled to fit.
        //
        // Both are landscape limits; `announce` swaps them for a portrait
        // panel (PROTOCOL.md 6.5), so a rotated 5K is not shrunk (#324).
        receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                  deviceKind: "Mac",
                                  fallbackServiceName: Host.current().localizedName ?? "Mac",
                                  maxEncodeWide: Self.h264Limit.width,
                                  maxEncodeHigh: Self.h264Limit.height,
                                  hevcCapability: Self.hevcLimit.map {
                                      VideoCapability(codec: "hevc", maxWidth: $0.width,
                                                      maxHeight: $0.height, maxFrameRate: 60)
                                  })
        if !main { receiver.advertisedID = StreamReceiver.installID + "." + key }
        receiver.serviceName = name(for: controller.advertisedName)
        announce()
        receiver.powerActions = controller.powerActions
        receiver.onPowerAction = { [weak self] action in
            guard let self else { return }
            self.controller.perform(action, via: self.receiver)
        }
        receiver.start(port: port)

        receiver.$connected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.controller.refresh() }
            .store(in: &cancellables)
        // Streaming = connected and the video format is known — that's when
        // the window has something to show (and when to take it down again).
        receiver.$connected.combineLatest(receiver.$videoSize)
            .map { $0 && $1 != .zero }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] streaming in
                guard let self else { return }
                self.streaming = streaming
                self.controller.refresh()
                self.updateWindow()
            }
            .store(in: &cancellables)
    }

    /// The main screen advertises the plain name; another screen adds its
    /// own name, so the sender's list tells them apart.
    func name(for base: String) -> String {
        main ? base : "\(base) (\(screen?.localizedName ?? key))"
    }

    func stop(completion: (() -> Void)?) {
        cancellables.removeAll()
        receiver.stop(completion: completion)
        closeWindow()
    }

    /// The panel this screen offers as a display: its current framebuffer.
    /// A Retina panel announces its @2x pixels, which maps 1:1 onto the
    /// sender's @2x HiDPI virtual display.
    ///
    /// Minus the menu-bar/notch strip: native full screen never covers it on
    /// notched panels (the fullscreen window is the screen shrunk by
    /// safeAreaInsets.top — zero on notch-less displays). Announcing the
    /// full panel would letterbox full screen on every side AND render the
    /// remote menu bar physically behind the notch; announcing the safe
    /// rect makes full screen exactly 1:1.
    ///
    /// Legacy fields (deprecated, read by older senders): the panel's
    /// *point* size at 2x, so a non-Retina panel still gets its point
    /// geometry from a sender that only builds 2x displays.
    ///
    /// `hello.panel` (PROTOCOL.md 6.7) carries the facts instead: physical
    /// pixels of the native mode (minus the notch strip), the real backing
    /// scale, and the current "looks like" size, from which the sender
    /// decides the desktop (1x for a non-Retina panel, #344).
    func announce() {
        guard let screen else { return }
        let legacyScale = max(screen.backingScaleFactor, 2)
        let inset = screen.safeAreaInsets.top
        let height = screen.frame.height - inset
        if let mode = CGDisplayCopyDisplayMode(displayID), mode.refreshRate > 0 {
            receiver.setDisplayMaxFrameRate(Int(mode.refreshRate.rounded()))
        } else {
            receiver.setDisplayMaxFrameRate(60)
        }

        let portrait = screen.frame.height > screen.frame.width
        let native = Self.nativePixels(of: displayID)
            ?? PanelSize(width: Int(screen.frame.width * screen.backingScaleFactor),
                         height: Int(screen.frame.height * screen.backingScaleFactor))
        // A rotated display reports a rotated frame; orient the native mode
        // like it.
        let long = max(native.width, native.height), short = min(native.width, native.height)
        let nativeWide = portrait ? short : long
        let nativeHigh = portrait ? long : short
        let strip = screen.frame.height > 0
            ? Int((inset * CGFloat(nativeHigh) / screen.frame.height).rounded()) : 0
        let panel = PanelAnnouncement(pixelsWide: nativeWide, pixelsHigh: nativeHigh - strip,
                                      scale: Double(screen.backingScaleFactor),
                                      pointsWide: Int(screen.frame.width),
                                      pointsHigh: Int(height))

        func oriented(_ size: PanelSize) -> PanelSize {
            portrait ? PanelSize(width: size.height, height: size.width) : size
        }
        let h264 = oriented(Self.h264Limit)
        let limitsChanged = receiver.setDecodeLimits(
            maxEncodeWide: h264.width, maxEncodeHigh: h264.height,
            hevc: Self.hevcLimit.map(oriented).map {
                VideoCapability(codec: "hevc", maxWidth: $0.width, maxHeight: $0.height,
                                maxFrameRate: 60)
            })
        receiver.setPanel(pixelsWide: Int(screen.frame.width * legacyScale),
                          pixelsHigh: Int(height * legacyScale),
                          scale: Double(legacyScale),
                          panel: panel, limitsChanged: limitsChanged)
    }

    /// Landscape decode limits; see `init`.
    private static let h264Limit = PanelSize(width: 4096, height: 2304)
    private static let hevcLimit: PanelSize? = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        ? PanelSize(width: 5120, height: 2880) : nil

    /// The panel's physical pixels: its native mode, not the current mode,
    /// whose pixel size is the backing store (6400x3600 at a scaled 5K mode).
    private static func nativePixels(of display: CGDirectDisplayID) -> PanelSize? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode],
              !modes.isEmpty else { return nil }
        // IOGraphicsTypes.h. Not every Mac sets the native flag (a 2017 iMac
        // on macOS 13 does not), but the default mode always runs at the
        // panel's pixels; failing both, the largest 1x mode is the panel.
        let nativeFlag: UInt32 = 0x0200_0000   // kDisplayModeNativeFlag
        let defaultFlag: UInt32 = 0x0000_0004  // kDisplayModeDefaultFlag
        let byArea: (CGDisplayMode, CGDisplayMode) -> Bool = {
            $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
        }
        let mode = modes.first(where: { $0.ioFlags & nativeFlag != 0 })
            ?? modes.first(where: { $0.ioFlags & defaultFlag != 0 })
            ?? modes.filter({ $0.pixelWidth == $0.width }).max(by: byArea)
            ?? modes.max(by: byArea)!
        return PanelSize(width: mode.pixelWidth, height: mode.pixelHeight)
    }

    // MARK: - Video window

    /// Show, hide or take down the window for the stream and the KVM state.
    func updateWindow() {
        guard streaming else { scheduleCloseWindow(); return }
        if controller.kvmVisible == false {
            window?.orderOut(nil)
        } else {
            showWindow()
        }
    }

    /// The KVM window and the normal window are different kinds: switching
    /// between KVM and no KVM builds the window again.
    func kvmChanged() {
        if window != nil, kvmWindow != (controller.kvmVisible != nil) { closeWindow() }
        updateWindow()
    }

    /// Bring the video window (back) up.
    func showWindow() {
        guard streaming || window != nil, controller.kvmVisible != false else { return }
        windowCloseTimer?.cancel()
        windowCloseTimer = nil
        if controller.kvmVisible == true {
            showKVMWindow()
            return
        }
        var created = false
        if window == nil {
            let w = NSWindow(contentRect: initialContentRect(video: receiver.videoSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "OpenDisplay"
            w.contentView = ReceiverVideoView(receiver: receiver)
            w.isReleasedWhenClosed = false
            w.collectionBehavior.insert(.fullScreenPrimary)
            // On this screen, so full screen also opens on it.
            if let frame = screen?.visibleFrame {
                w.setFrameOrigin(NSPoint(x: frame.midX - w.frame.width / 2,
                                         y: frame.midY - w.frame.height / 2))
            } else {
                w.center()
            }
            window = w
            kvmWindow = false
            observeFullscreenChoice(of: w)
            created = true
        }
        // Resizes keep the stream's shape; re-set on every show because a
        // reconnect can arrive with new dimensions in the same window.
        if receiver.videoSize != .zero { window?.contentAspectRatio = receiver.videoSize }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Only a freshly built window takes the preference: an existing one
        // is already where the user put it, and toggling it mid-animation
        // would undo the transition.
        if created, controller.fullscreenPreference.wantsFullscreen, let window {
            window.toggleFullScreen(nil)
        }
    }

    /// KVM: a borderless window over the whole screen, above the menu bar,
    /// so a switch shows or hides it at once, with no full screen animation.
    private func showKVMWindow() {
        guard let screen else { return }
        if window == nil {
            let w = KVMWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            // The stream fills the screen below the notch strip (see announce).
            let video = ReceiverVideoView(receiver: receiver)
            video.frame = NSRect(x: 0, y: 0, width: screen.frame.width,
                                 height: screen.frame.height - screen.safeAreaInsets.top)
            video.autoresizingMask = [.width, .height]
            container.addSubview(video)
            w.contentView = container
            window = w
            kvmWindow = true
        }
        window?.setFrame(screen.frame, display: true)
        window?.orderFrontRegardless()
    }

    /// The stream stopped. A sender moving the session to a better transport
    /// can drop the old link a moment before the new one is adopted, so wait
    /// briefly before taking the window down: rebuilding it would replay the
    /// fullscreen transition, and a toggle during the old window's animation
    /// is refused.
    private func scheduleCloseWindow() {
        windowCloseTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.closeWindow() }
        windowCloseTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: timer)
    }

    private func closeWindow() {
        windowCloseTimer?.cancel()
        windowCloseTimer = nil
        // Our own teardown is not the user's choice: stop listening first so
        // closing a fullscreen window doesn't record "windowed".
        stopObservingWindow()
        window?.close()
        window = nil
    }

    /// Remember the user's green-button choice for every future window. A
    /// user close drops the window before its fullscreen exit is reported;
    /// the panel's button then builds a fresh one with the preference.
    private func observeFullscreenChoice(of window: NSWindow) {
        let center = NotificationCenter.default
        let observe = { (name: Notification.Name, apply: @escaping @MainActor (ScreenReceiver) -> Void) in
            // Synchronous on .main: a close must stop observing before the
            // fullscreen exit it causes is delivered.
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { apply(self) } }
            }
        }
        windowObservers = [
            observe(NSWindow.didEnterFullScreenNotification) {
                $0.controller.fullscreenPreference.wantsFullscreen = true
            },
            observe(NSWindow.didExitFullScreenNotification) {
                $0.controller.fullscreenPreference.wantsFullscreen = false
            },
            observe(NSWindow.willCloseNotification) {
                $0.stopObservingWindow()
                $0.window = nil
            },
        ]
    }

    private func stopObservingWindow() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
    }

    /// Windowed at ~70% of the screen; fullscreen returns here when the user
    /// leaves it.
    private func initialContentRect(video: CGSize) -> NSRect {
        let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let size = video == .zero ? CGSize(width: 960, height: 600) : video
        let scale = min(0.7 * visible.width / size.width,
                        0.7 * visible.height / size.height, 1)
        return NSRect(x: 0, y: 0,
                      width: size.width * scale, height: size.height * scale)
    }
}

/// A borderless window can't become key by default; the KVM window must, so
/// its blank cursor applies.
private final class KVMWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Video view (AppKit sibling of the iOS VideoLayerView)

/// NSView hosting the AVSampleBufferDisplayLayer plus the local cursor-echo
/// layer. The sender hides the real cursor from capture and streams its
/// position/sprite on the control channel — without drawing it here the
/// extended desktop would have no visible pointer.
final class ReceiverVideoView: NSView {
    private weak var receiver: StreamReceiver?
    private let displayLayer: AVSampleBufferDisplayLayer
    private var videoSizeObserver: AnyCancellable?

    private let cursorLayer: CALayer = {
        let layer = CALayer()
        layer.isHidden = true
        layer.zPosition = 10
        // Position updates arrive at 120Hz — implicit animations would
        // smear the cursor behind every move.
        layer.actions = ["position": NSNull(), "contents": NSNull(),
                         "bounds": NSNull(), "hidden": NSNull()]
        return layer
    }()
    private var cursorNormSize = CGSize.zero
    private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
    private var cursorVisible = false

    init(receiver: StreamReceiver) {
        self.receiver = receiver
        self.displayLayer = receiver.displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // AVSBDL aspect-fits internally (videoGravity) — give it full bounds.
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        layer?.addSublayer(cursorLayer)

        receiver.onCursor = { [weak self] x, y, visible in
            self?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak self] image, anchor, normSize in
            self?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        // Replay the sprite/position that arrived before this view existed —
        // the sender re-sends them only on change, so without this the
        // cursor stays invisible until it happens to change shape.
        if let sprite = receiver.cursorSprite {
            setCursorSprite(sprite.image, anchor: sprite.anchor, normSize: sprite.normSize)
        }
        let state = receiver.cursorState
        moveCursor(x: state.x, y: state.y, visible: state.visible)
        // videoSize arrives after the format description — re-fit the layers.
        videoSizeObserver = receiver.$videoSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsLayout = true }

        // The shared perf HUD (same as iOS), toggled by "showAnalytics".
        // Sized with autoresizing, not Auto Layout: an NSHostingView reports
        // its SwiftUI content's intrinsic size, and pinned edge-to-edge with
        // required constraints that size drove the *window*, which collapsed
        // to 0 × titlebar with the HUD hidden. Springs and struts never feed
        // back into the window, on any macOS the app supports.
        let overlay = OverlayHostingView(rootView: ReceiverPerfOverlay(receiver: receiver))
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: blankCursor)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        updateCursorLayout()
        CATransaction.commit()
    }

    /// Aspect-fit rect of the video inside the view (same math as iOS).
    private func videoRect() -> CGRect? {
        guard let video = receiver?.videoSize, video != .zero,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func moveCursor(x: Double, y: Double, visible: Bool) {
        cursorNorm = CGPoint(x: x, y: y)
        cursorVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible || cursorLayer.contents == nil
        updateCursorLayout()
        CATransaction.commit()
    }

    private func setCursorSprite(_ image: CGImage, anchor: CGPoint, normSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image
        // The wire anchor is the hotspot from the image's TOP-left; AppKit
        // layer unit coords run bottom-up — flip y once here.
        cursorLayer.anchorPoint = CGPoint(x: anchor.x, y: 1 - anchor.y)
        cursorNormSize = normSize
        cursorLayer.isHidden = !cursorVisible
        updateCursorLayout()
        CATransaction.commit()
    }

    private func updateCursorLayout() {
        guard let rect = videoRect(), cursorNormSize != .zero else { return }
        cursorLayer.bounds = CGRect(x: 0, y: 0,
                                    width: cursorNormSize.width * rect.width,
                                    height: cursorNormSize.height * rect.height)
        // Video-space y grows downward, view coords grow upward — flip.
        cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                       y: rect.maxY - cursorNorm.y * rect.height)
    }
}

// MARK: - Performance overlay host

// This Mac's own pointer over the video reads as a second, dead cursor on
// what acts as a monitor — blank it there. The streamed sender cursor
// (cursorLayer) is the pointer that matters. File-scope so both the video
// view and the overlay above it use the same cursor.
private let blankCursor: NSCursor = {
    let size = NSSize(width: 1, height: 1)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.set()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return NSCursor(image: image, hotSpot: .zero)
}()

/// The shared PerfOverlay pinned to the bottom of the video, driven by the
/// same "showAnalytics" default the iOS app uses (toggled in the panel).
struct ReceiverPerfOverlay: View {
    @ObservedObject var receiver: StreamReceiver
    @AppStorage("showAnalytics") private var showAnalytics = false

    var body: some View {
        if showAnalytics {
            VStack {
                Spacer()
                PerfOverlay(stats: receiver.perf, videoSize: receiver.videoSize)
                    .padding(.bottom, 10)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Full-bleed, non-interactive layer above the video. Subclassed only so the
/// blank-cursor rect covers the HUD area too.
private final class OverlayHostingView: NSHostingView<ReceiverPerfOverlay> {
    required init(rootView: ReceiverPerfOverlay) {
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: blankCursor)
    }
}

private struct PanelSize {
    let width: Int
    let height: Int
}
