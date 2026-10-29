import AppKit

// KVM for two Macs that both run this app. One desk (every screen, the
// keyboard and the mouse) belongs to one Mac at a time: the owner. ⌃⌥⌘K on
// either Mac gives the desk to the other Mac.
//
// The owner streams to every screen of the other Mac and hides its own
// receiver windows. The other Mac shows those streams over its whole
// screens, catches its keyboard and mouse with an event tap, and sends them
// to the owner, which posts them as its own input.
//
// The messages are "kvm" control messages, in either direction of any
// session between the two Macs:
//   {"you": "own" | "show", "from": id, "screens": [names]}   the desk moved
//   {"from": id, "screens": [names]}                          the reply
//   {"e": "move", "dx", "dy"}  {"e": "btn", "b", "down", "clicks"}
//   {"e": "scroll", "dx", "dy"}  {"e": "key", "code", "down", "flags"}
//   {"e": "flags", "code", "flags"}  {"e": "release"}
// Only over the direct cable, like power actions (PROTOCOL.md 6.6): the keys
// travel in the clear, and anything on the LAN can reach a receiver.
// `defaults write com.peetzweg.opensidecar.mac.debug kvmOverWiFi -bool YES`
// (or `-kvmOverWiFi YES`) allows WiFi too.
@MainActor
final class KVM {
    static let shared = KVM()

    enum Owner: String { case me, peer }

    /// Who has the desk. Nil until the first switch: the app then works as
    /// it did before KVM.
    private(set) var owner = UserDefaults.standard.string(forKey: "kvmOwner").flatMap(Owner.init) {
        didSet { UserDefaults.standard.set(owner?.rawValue, forKey: "kvmOwner") }
    }
    // The other Mac's install id and screen names, from its messages: the
    // owner connects to those screens.
    private var peerID = UserDefaults.standard.string(forKey: "kvmPeer") {
        didSet { UserDefaults.standard.set(peerID, forKey: "kvmPeer") }
    }
    private var peerScreens = UserDefaults.standard.stringArray(forKey: "kvmPeerScreens") ?? [] {
        didSet { UserDefaults.standard.set(peerScreens, forKey: "kvmPeerScreens") }
    }

    private var tap: CFMachPort?
    private var capturing = false
    // The one session that carries this Mac's input, so the owner posts
    // each event once. Found again each second.
    private var channel: (([String: Any]) -> Void)?
    private var timer: Timer?
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<Int64> = []
    private var loggedOffCable = false

    private var allowsWiFi: Bool { UserDefaults.standard.bool(forKey: "kvmOverWiFi") }

    func start() {
        StreamReceiver.onKVM = { [weak self] message, direct in self?.receive(message, direct: direct) }
        MacSender.onKVM = { [weak self] message, direct in self?.receive(message, direct: direct) }
        // The tap permission, the sessions and the streams change with no
        // one event to watch: look again each second.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { KVM.shared.refresh() }
        }
        refresh()
    }

    private func refresh() {
        if tap == nil { installTap() }
        ReceiverController.shared.kvmVisible = owner.map { $0 == .peer }
        channel = receiverChannels.first?.sendKVM ?? senderChannels.first?.sendKVM
        // Catch the input only while the owner's screens show here and a
        // session can carry it: never lock a Mac out of its own input.
        let capture = owner == .peer && ReceiverController.shared.streaming && channel != nil
        if capture != capturing { setCapturing(capture) }
    }

    // MARK: - Sessions with the other Mac

    /// The other Mac streams to this Mac's screens.
    private var receiverChannels: [StreamReceiver] {
        ReceiverController.shared.screens.map(\.receiver)
            .filter { $0.connected && (allowsWiFi || $0.onDirectCable) }
    }

    /// This Mac streams to the other Mac's screens.
    private var senderChannels: [MacSender] {
        SenderController.shared.sessions
            .filter { $0.deviceKind == "Mac" && !$0.failed }
            .map(\.sender)
            .filter { allowsWiFi || $0.onDirectCable }
    }

    private var identity: [String: Any] {
        ["from": StreamReceiver.installID,
         "screens": ReceiverController.shared.screens.map(\.receiver.serviceName)]
    }

    private func announce(_ you: String) {
        var message = identity
        message["you"] = you
        receiverChannels.forEach { $0.sendKVM(message) }
        senderChannels.forEach { $0.sendKVM(message) }
    }

    /// ⌃⌥⌘K: give the desk to the other Mac, or take it back.
    private func toggle() {
        if owner == .peer {
            owner = .me
            announce("show")
            Log.info("kvm: this Mac takes the desk back")
            connectPeerScreens()
        } else {
            guard !receiverChannels.isEmpty || !senderChannels.isEmpty else {
                Log.info("kvm: no session with the other Mac on the cable — the desk stays here")
                NSSound.beep()
                return
            }
            owner = .peer
            announce("own")
            Log.info("kvm: this Mac gives the desk to the other Mac")
        }
        refresh()
    }

    /// The owner streams to every screen of the other Mac.
    private func connectPeerScreens() {
        SenderController.shared.connectScreens(of: peerID, names: peerScreens)
    }

    private func receive(_ message: [String: Any], direct: Bool) {
        guard direct || allowsWiFi else {
            if !loggedOffCable {
                loggedOffCable = true
                Log.info("kvm: ignored messages from a session off the direct cable")
            }
            return
        }
        if let from = message["from"] as? String {
            peerID = from
            peerScreens = message["screens"] as? [String] ?? peerScreens
        }
        if let you = message["you"] as? String {
            owner = you == "own" ? .me : .peer
            Log.info("kvm: the other Mac gave the desk to " + (owner == .me ? "this Mac" : "itself"))
            // Reply with this Mac's identity, so the other Mac can stream here
            // when it takes the desk.
            receiverChannels.forEach { $0.sendKVM(identity) }
            senderChannels.forEach { $0.sendKVM(identity) }
            if owner == .me { connectPeerScreens() }
            refresh()
        } else if message["e"] != nil, owner == .me {
            inject(message)
        }
    }

    // MARK: - This Mac's input to the owner

    private func installTap() {
        guard AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .scrollWheel, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: kvmTapCallback, userInfo: nil) else {
            Log.info("kvm: no event tap")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        self.tap = tap
        Log.info("kvm: event tap on — ⌃⌥⌘K switches the desk")
    }

    private func setCapturing(_ on: Bool) {
        if !on { channel?(["e": "release"]) }
        capturing = on
        // The pointer stays still here; its moves go to the owner.
        CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1)
        if on {
            NSCursor.hide()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSCursor.unhide()
        }
        Log.info(on ? "kvm: keyboard and mouse go to the other Mac"
                    : "kvm: keyboard and mouse stay on this Mac")
    }

    /// The tap: ⌃⌥⌘K switches, and while capturing every other event goes
    /// to the owner instead of this Mac. Nil drops the event here.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        }
        let field = { (f: CGEventField) in event.getIntegerValueField(f) }
        if type == .keyDown || type == .keyUp, field(.keyboardEventKeycode) == 40,   // K
           event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            == [.maskControl, .maskAlternate, .maskCommand] {
            if type == .keyDown, field(.keyboardEventAutorepeat) == 0 { toggle() }
            return nil
        }
        guard capturing, let channel else { return event }
        switch type {
        case .keyDown, .keyUp:
            channel(["e": "key", "code": field(.keyboardEventKeycode), "down": type == .keyDown,
                     "flags": event.flags.rawValue])
        case .flagsChanged:
            channel(["e": "flags", "code": field(.keyboardEventKeycode), "flags": event.flags.rawValue])
        case .scrollWheel:
            channel(["e": "scroll", "dx": field(.scrollWheelEventPointDeltaAxis2),
                     "dy": field(.scrollWheelEventPointDeltaAxis1)])
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            channel(["e": "btn", "b": field(.mouseEventButtonNumber), "down": down,
                     "clicks": field(.mouseEventClickState)])
        default:   // moves and drags
            channel(["e": "move", "dx": field(.mouseEventDeltaX), "dy": field(.mouseEventDeltaY)])
        }
        return nil
    }

    // MARK: - The other Mac's input, here on the owner

    private func inject(_ m: [String: Any]) {
        let number = { (key: String) in (m[key] as? NSNumber)?.doubleValue ?? 0 }
        let flags = CGEventFlags(rawValue: (m["flags"] as? NSNumber)?.uint64Value ?? 0)
        let here = CGEvent(source: nil)?.location ?? .zero
        switch m["e"] as? String {
        case "move":
            let to = clamp(CGPoint(x: here.x + number("dx"), y: here.y + number("dy")), from: here)
            let held = buttonsDown.min()
            let type: CGEventType = switch held {
            case nil: .mouseMoved
            case 0?: .leftMouseDragged
            case 1?: .rightMouseDragged
            default: .otherMouseDragged
            }
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: to,
                                mouseButton: CGMouseButton(rawValue: UInt32(held ?? 0)) ?? .left)
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(number("dx")))
            event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(number("dy")))
            event?.post(tap: .cghidEventTap)
        case "btn":
            let button = Int64(number("b"))
            let down = m["down"] as? Bool ?? false
            postButton(button, down: down, clicks: Int64(max(1, number("clicks"))), at: here)
        case "scroll":
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: Int32(number("dy")), wheel2: Int32(number("dx")), wheel3: 0)?
                .post(tap: .cghidEventTap)
        case "key":
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(number("code")),
                                keyDown: m["down"] as? Bool ?? false)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        case "flags":
            postFlags(flags, code: CGKeyCode(number("code")))
        case "release":
            // The other Mac stopped sending: no modifier or button stays held.
            postFlags([], code: 55)
            for button in buttonsDown { postButton(button, down: false, clicks: 1, at: here) }
        default:
            break
        }
    }

    private func postButton(_ button: Int64, down: Bool, clicks: Int64, at point: CGPoint) {
        if down { buttonsDown.insert(button) } else { buttonsDown.remove(button) }
        let type: CGEventType = switch (button, down) {
        case (0, true): .leftMouseDown
        case (0, false): .leftMouseUp
        case (1, true): .rightMouseDown
        case (1, false): .rightMouseUp
        case (_, true): .otherMouseDown
        case (_, false): .otherMouseUp
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                            mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)
        event?.setIntegerValueField(.mouseEventButtonNumber, value: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clicks)
        event?.post(tap: .cghidEventTap)
    }

    private func postFlags(_ flags: CGEventFlags, code: CGKeyCode) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        event?.type = .flagsChanged
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// Keep the pointer on a screen: at an outer edge it stops, as with a
    /// real mouse.
    private func clamp(_ point: CGPoint, from: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 0, nil, &count)
        if count > 0 { return point }
        var display = CGDirectDisplayID()
        CGGetDisplaysWithPoint(from, 1, &display, &count)
        guard count > 0 else { return from }
        let bounds = CGDisplayBounds(display)
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }
}

private func kvmTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    MainActor.assumeIsolated {
        KVM.shared.handle(type, event).map { Unmanaged.passUnretained($0) }
    }
}
