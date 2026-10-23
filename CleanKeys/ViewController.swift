//
//  ViewController.swift
//  CleanKeys
//

import Cocoa
import ApplicationServices
import IOKit.hidsystem

class ViewController: NSViewController {
    private var disableTimer: Timer?
    private var countdownTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var unlockDeadline: ContinuousClock.Instant?
    private var isKeyboardDisabled = false
    private var isConfirmingLock = false
    // Temporary diagnostics: at most one callback message per event type per session.
    private var diagnosticEventTypes = Set<UInt32>()
    private var diagnosticSeconds: Int64?
    private var diagnosticSystemCategories = Set<String>()

    private func diagnostic(_ message: String) {
        #if DEBUG
        print("[CleanKeys tap] \(message)")
        #endif
    }

    @IBOutlet weak var countdownLabel: NSTextField!
    @IBOutlet weak var disableButton: NSButton!
    @IBOutlet weak var durationSlider: NSSlider!
    @IBOutlet weak var durationLabel: NSTextField!

    private let defaultDisableDurationKey = "defaultDisableDuration"
    private let initialDefaultDuration = 10
    private let maximumLockDuration = 25

    override func viewDidLoad() {
        super.viewDidLoad()
        countdownLabel.isHidden = true
        let savedDuration = UserDefaults.standard.integer(forKey: defaultDisableDurationKey)
        let initialDuration = min(max(savedDuration == 0 ? initialDefaultDuration : savedDuration, 5), maximumLockDuration)
        durationSlider.minValue = 5
        durationSlider.maxValue = Double(maximumLockDuration)
        durationSlider.integerValue = initialDuration
        durationLabel.stringValue = "Disable for \(initialDuration) seconds"

        NotificationCenter.default.addObserver(self, selector: #selector(unlockForNotification(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unlockForNotification(_:)),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unlockForNotification(_:)),
                                                          name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let window = view.window {
            NotificationCenter.default.addObserver(self, selector: #selector(unlockForNotification(_:)),
                                                   name: NSWindow.willCloseNotification, object: window)
        }
    }

    @IBAction func durationSliderChanged(_ sender: NSSlider) {
        let duration = selectedDuration
        durationLabel.stringValue = "Disable for \(duration) seconds"
        UserDefaults.standard.set(duration, forKey: defaultDisableDurationKey)
    }

    private var selectedDuration: Int {
        min(max(durationSlider.integerValue, 5), maximumLockDuration)
    }

    @IBAction func disableInput(_ sender: NSButton) {
        if isKeyboardDisabled {
            enableKeyboard(reason: "mouse button")
            return
        }
        guard !isConfirmingLock else { return }
        isConfirmingLock = true
        defer { isConfirmingLock = false }

        let alert = NSAlert()
        alert.messageText = "Disable Input"
        alert.informativeText = "This will disable your keyboard for \(selectedDuration) seconds. Do you want to proceed?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Disable")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        disableKeyboard()
    }

    private func disableKeyboard() {
        guard !isKeyboardDisabled, eventTap == nil else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        diagnostic("permissions: accessibility=\(accessibilityTrusted), listenAccess=\(CGPreflightListenEventAccess()); mainThread=\(Thread.isMainThread)")
        diagnostic("executable=\(Bundle.main.executableURL?.path ?? "unknown")")
        guard accessibilityTrusted else {
            showAlert("Accessibility permission required",
                      "Allow CleanKeys in System Settings > Privacy & Security > Accessibility, then try again. If access is still unavailable, quit and reopen CleanKeys. The keyboard has not been disabled.")
            return
        }

        // Core Graphics has no named systemDefined case; AppKit/NX_SYSDEFINED is type 14.
        let systemDefinedMask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        let eventMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(systemDefinedMask) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        diagnosticEventTypes.removeAll()
        diagnosticSystemCategories.removeAll()
        diagnosticSeconds = nil
        diagnostic("creating session/headInsert/defaultTap; mask=\(eventMask) (keyDown/keyUp/flagsChanged/systemDefined)")
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, context in
                guard let context = context else {
                    #if DEBUG
                    print("[CleanKeys tap] callback missing context; passing event")
                    #endif
                    return Unmanaged.passUnretained(event)
                }
                let controller = Unmanaged<ViewController>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Fail open: never silently resume blocking after macOS disables the tap.
                    controller.diagnostic("callback: \(type == .tapDisabledByTimeout ? "tapDisabledByTimeout" : "tapDisabledByUserInput"); enabled=\(controller.eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)")
                    controller.enableKeyboard(reason: "tap disable notification")
                    return Unmanaged.passUnretained(event)
                }
                guard controller.isKeyboardDisabled,
                      let deadline = controller.unlockDeadline,
                      ContinuousClock.now < deadline else {
                    controller.diagnostic("callback passing event: locked=\(controller.isKeyboardDisabled), deadlinePresent=\(controller.unlockDeadline != nil)")
                    controller.enableKeyboard(reason: "callback inactive or deadline expired")
                    return Unmanaged.passUnretained(event)
                }
                if type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue) {
                    let category = controller.auxiliaryControlCategory(event)
                    let label = category ?? "unrelated/unsupported"
                    if controller.diagnosticSystemCategories.insert(label).inserted {
                        controller.diagnostic("systemDefined: \(label); \(category == nil ? "pass" : "drop")")
                    }
                    // Preserve other subtypes (including auxiliary mouse buttons) and unknown controls.
                    return category == nil ? Unmanaged.passUnretained(event) : nil
                }
                if type == .keyDown || type == .keyUp || type == .flagsChanged {
                    if controller.diagnosticEventTypes.insert(type.rawValue).inserted {
                        let name = type == .keyDown ? "keyDown" : (type == .keyUp ? "keyUp" : "flagsChanged")
                        controller.diagnostic("callback: \(name); returning nil (drop); mainThread=\(Thread.isMainThread), enabled=\(controller.eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)")
                    }
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            diagnostic("tapCreate returned nil")
            showAlert("Could not disable keyboard",
                      "macOS could not create the keyboard event tap. Check CleanKeys in System Settings > Privacy & Security > Accessibility and reopen the app if needed. The keyboard has not been disabled.")
            return
        }
        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            enableKeyboard(reason: "setup failure")
            showAlert("Could not disable keyboard", "The keyboard event source could not be created. The keyboard has not been disabled.")
            return
        }
        runLoopSource = source
        let duration = selectedDuration
        unlockDeadline = ContinuousClock.now.advanced(by: .seconds(duration))
        isKeyboardDisabled = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        diagnostic("installed source: valid=\(CFRunLoopSourceIsValid(source)), inMainCommonModes=\(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes)); tapIsEnabled=\(CGEvent.tapIsEnabled(tap: tap)); duration=\(duration)s")
        guard CGEvent.tapIsEnabled(tap: tap) else {
            enableKeyboard(reason: "setup failure")
            showAlert("Could not disable keyboard", "macOS did not enable the keyboard event tap. Check Accessibility permission and try again.")
            return
        }

        disableButton.title = "Enable Keys"
        updateCountdown()
        let countdown = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        countdownTimer = countdown
        RunLoop.main.add(countdown, forMode: .common)
        let unlock = Timer(timeInterval: TimeInterval(duration), repeats: false) { [weak self] _ in
            self?.enableKeyboard(reason: "automatic unlock timer")
        }
        disableTimer = unlock
        RunLoop.main.add(unlock, forMode: .common)
    }

    private func auxiliaryControlCategory(_ event: CGEvent) -> String? {
        guard let auxiliary = NSEvent(cgEvent: event), auxiliary.type == .systemDefined,
              auxiliary.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else { return nil }
        // NX auxiliary data1: high 16 bits are control type; bits 8–15 are down/up.
        // Match both transitions (and repeats), without logging or retaining the payload.
        let keyType = Int32((auxiliary.data1 >> 16) & 0xffff)
        let state = (auxiliary.data1 >> 8) & 0xff
        guard state == NX_KEYDOWN || state == NX_KEYUP else { return nil }
        switch keyType {
        case NX_KEYTYPE_PLAY, NX_KEYTYPE_NEXT, NX_KEYTYPE_PREVIOUS,
             NX_KEYTYPE_FAST, NX_KEYTYPE_REWIND:
            return "media playback"
        case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE:
            return "volume"
        case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
            return "display brightness"
        case NX_KEYTYPE_ILLUMINATION_UP, NX_KEYTYPE_ILLUMINATION_DOWN, NX_KEYTYPE_ILLUMINATION_TOGGLE:
            return "keyboard backlight"
        default:
            return nil
        }
    }

    private func updateCountdown() {
        guard isKeyboardDisabled, let deadline = unlockDeadline else { return }
        let now = ContinuousClock.now
        guard now < deadline else {
            enableKeyboard(reason: "countdown deadline reached")
            return
        }
        let remaining = now.duration(to: deadline).components
        let seconds = remaining.seconds + (remaining.attoseconds > 0 ? 1 : 0)
        if diagnosticSeconds != seconds {
            diagnosticSeconds = seconds
            diagnostic("countdown: \(seconds)s; locked=\(isKeyboardDisabled), tapIsEnabled=\(eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false), callbackTypesSeen=\(diagnosticEventTypes.count)")
        }
        countdownLabel.stringValue = "Disabling keyboard for \(seconds) seconds"
        countdownLabel.isHidden = false
    }

    @objc private func unlockForNotification(_ notification: Notification) {
        enableKeyboard(reason: "notification: \(notification.name.rawValue)")
    }

    private func enableKeyboard(reason: String) {
        diagnostic("unlock: \(reason); locked=\(isKeyboardDisabled), tapPresent=\(eventTap != nil)")
        cleanupLock()
        countdownLabel?.isHidden = true
        disableButton?.title = "Disable Keys"
    }

    private func cleanupLock() {
        if eventTap != nil {
            diagnostic("cleanup: disabling/invalidation of tap and stored source; invalidating timers")
        }
        isKeyboardDisabled = false
        unlockDeadline = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        runLoopSource = nil
        eventTap = nil
        disableTimer?.invalidate()
        disableTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    deinit {
        cleanupLock()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
