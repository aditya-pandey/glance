import AppKit
import Carbon

public protocol HotkeyManagerDelegate: AnyObject {
    func switcherTriggered(sameAppOnly: Bool, reverse: Bool)
    func switcherStep(delta: Int)
    func switcherArrows(keyCode: UInt16)
    func switcherLockSticky(initialChar: String?)
    func switcherCloseSelected()
    func switcherCommitAndHide()
    func switcherCancel()
}

public final class HotkeyManager {
    public weak var delegate: HotkeyManagerDelegate?

    private var allWinRef: EventHotKeyRef?
    private var allWinRevRef: EventHotKeyRef?
    private var sameAppRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var activeEventTap: CFMachPort?
    private var activeRunLoopSource: CFRunLoopSource?

    public var isOverlayVisible: Bool = false
    public var isStickyMode: Bool = false

    public init() {}

    deinit {
        stopMonitoring()
    }

    /// Registers:
    /// - Option + Tab         -> Visual Window Grid (All Windows) / step forward
    /// - Option + Shift + Tab -> Step backward
    /// - Option + ~           -> Same-App Visual Window Grid (e.g. Chrome windows only)
    public func registerHotkeys() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData, let event = event else { return noErr }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1: mgr.handleTrigger(sameAppOnly: false, reverse: false)
                    case 2: mgr.handleTrigger(sameAppOnly: true, reverse: false)
                    case 3: mgr.handleTrigger(sameAppOnly: false, reverse: true)
                    default: break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        let optMod = UInt32(optionKey)
        let optShiftMod = UInt32(optionKey | shiftKey)

        // 1. Option + Tab (kVK_Tab = 0x30)
        RegisterEventHotKey(UInt32(kVK_Tab), optMod, EventHotKeyID(signature: OSType(0x57494E57), id: 1), GetApplicationEventTarget(), 0, &allWinRef)
        // 2. Option + ~ (kVK_ANSI_Grave = 0x32)
        RegisterEventHotKey(UInt32(kVK_ANSI_Grave), optMod, EventHotKeyID(signature: OSType(0x57494E57), id: 2), GetApplicationEventTarget(), 0, &sameAppRef)
        // 3. Option + Shift + Tab
        RegisterEventHotKey(UInt32(kVK_Tab), optShiftMod, EventHotKeyID(signature: OSType(0x57494E57), id: 3), GetApplicationEventTarget(), 0, &allWinRevRef)

        print("[Glance] Registered ⌥Tab (Visual Grid), ⌥~ (Current App), ⌥⇧Tab (Reverse)")
    }

    private func handleTrigger(sameAppOnly: Bool, reverse: Bool) {
        if isOverlayVisible {
            delegate?.switcherStep(delta: reverse ? -1 : 1)
        } else {
            isOverlayVisible = true
            isStickyMode = false
            startSessionMonitors()
            delegate?.switcherTriggered(sameAppOnly: sameAppOnly, reverse: reverse)
            if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
                endSession()
                delegate?.switcherCommitAndHide()
            }
        }
    }

    public func beginStickySession() {
        isOverlayVisible = true
        isStickyMode = true
        stopEventTap() // Allow normal text typing & Delete in sticky NSTextField
        if flagsMonitor == nil {
            startSessionMonitors()
        }
    }

    public func endSession() {
        isOverlayVisible = false
        isStickyMode = false
        stopSessionMonitors()
    }

    private func startSessionMonitors() {
        stopSessionMonitors()

        // When Accessibility is trusted & not in sticky search, use CGEventTap to swallow session keys cleanly
        if !isStickyMode && AXIsProcessTrusted() {
            installSessionEventTap()
        }

        let handleFlags: (NSEvent) -> Void = { [weak self] event in
            guard let self = self, self.isOverlayVisible, !self.isStickyMode else { return }
            if !event.modifierFlags.contains(.option) {
                self.endSession()
                self.delegate?.switcherCommitAndHide()
            }
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: handleFlags)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handleFlags(event)
            return event
        }

        let handleKeyDown: (NSEvent) -> Bool = { [weak self] event in
            guard let self = self, self.isOverlayVisible else { return false }

            // Esc cancels immediately
            if event.keyCode == 53 {
                self.endSession()
                self.delegate?.switcherCancel()
                return true
            }

            // Return commits immediately
            if event.keyCode == 36 && !self.isStickyMode {
                self.endSession()
                self.delegate?.switcherCommitAndHide()
                return true
            }

            // Tab while overlay is visible (even in sticky mode)
            if event.keyCode == 48 { // kVK_Tab
                let reverse = event.modifierFlags.contains(.shift)
                self.delegate?.switcherStep(delta: reverse ? -1 : 1)
                return true
            }

            // Close selected window with Q (while not typing in search) or Command+W
            if (event.modifierFlags.contains(.command) && event.keyCode == 13) // ⌘W
                || (!self.isStickyMode && event.keyCode == 12) { // Q while holding Option
                self.delegate?.switcherCloseSelected()
                return true
            }

            // Arrow keys (123 Left, 124 Right, 125 Down, 126 Up) when not captured by text editor
            if [123, 124, 125, 126].contains(event.keyCode) && !self.isStickyMode {
                self.delegate?.switcherArrows(keyCode: event.keyCode)
                return true
            }

            // Pressing '/' or any letter/digit transitions seamlessly into Sticky Search Mode!
            if !self.isStickyMode,
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               let raw = event.charactersIgnoringModifiers,
               let ch = raw.first,
               (ch == "/" || ch.isLetter || ch.isNumber) {
                self.isStickyMode = true
                self.stopEventTap()
                let seed: String? = (ch == "/") ? nil : String(ch)
                self.delegate?.switcherLockSticky(initialChar: seed)
                return true
            }

            return false
        }

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            if self.activeEventTap == nil {
                _ = handleKeyDown(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if self.activeEventTap != nil && !self.isStickyMode { return event }
            if handleKeyDown(event) { return nil }
            return event
        }
    }

    private func installSessionEventTap() {
        stopEventTap()
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: sessionEventTapCallback,
            userInfo: selfPtr
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.activeEventTap = tap
        self.activeRunLoopSource = source
    }

    fileprivate func handleTapEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = activeEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isOverlayVisible && !isStickyMode else {
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            // Never swallow flagsChanged so modifier keys never get stuck system-wide!
            if !event.flags.contains(.maskAlternate) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isOverlayVisible, !self.isStickyMode else { return }
                    self.endSession()
                    self.delegate?.switcherCommitAndHide()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            return nil // swallow keyUp while non-sticky overlay is active
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if keyCode == 53 { // Escape
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.endSession()
                self.delegate?.switcherCancel()
            }
            return nil
        }

        if keyCode == 36 { // Return
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.endSession()
                self.delegate?.switcherCommitAndHide()
            }
            return nil
        }

        if keyCode == 48 { // Tab (including repeats)
            let reverse = flags.contains(.maskShift)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.switcherStep(delta: reverse ? -1 : 1)
            }
            return nil
        }

        if [123, 124, 125, 126].contains(keyCode) { // Arrows
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.switcherArrows(keyCode: keyCode)
            }
            return nil
        }

        if keyCode == 12 || (flags.contains(.maskCommand) && keyCode == 13) { // Q or ⌘W
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.switcherCloseSelected()
            }
            return nil
        }

        // Letter/digit or '/' enters Sticky Search mode cleanly
        if !flags.contains(.maskCommand), !flags.contains(.maskControl),
           let nsEvt = NSEvent(cgEvent: event),
           let raw = nsEvt.charactersIgnoringModifiers,
           let ch = raw.first,
           (ch == "/" || ch.isLetter || ch.isNumber) {
            isStickyMode = true
            stopEventTap()
            let seed: String? = (ch == "/") ? nil : String(ch)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.switcherLockSticky(initialChar: seed)
            }
            return nil
        }

        return nil // swallow stray non-sticky keys so nothing leaks into app underneath
    }

    private func stopEventTap() {
        if let src = activeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            activeRunLoopSource = nil
        }
        if let tap = activeEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            activeEventTap = nil
        }
    }

    private func stopSessionMonitors() {
        stopEventTap()
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }

    public func stopMonitoring() {
        stopSessionMonitors()
        if let r = allWinRef { UnregisterEventHotKey(r); allWinRef = nil }
        if let r = allWinRevRef { UnregisterEventHotKey(r); allWinRevRef = nil }
        if let r = sameAppRef { UnregisterEventHotKey(r); sameAppRef = nil }
    }
}

private func sessionEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let mgr = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return mgr.handleTapEvent(proxy: proxy, type: type, event: event)
}
