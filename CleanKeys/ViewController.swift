//
//  ViewController.swift
//  CleanKeys
//

import Cocoa
import ApplicationServices
import IOKit.hidsystem
import OSLog

class ViewController: NSViewController {
    private var disableTimer: Timer?
    private var countdownTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var unlockDeadline: ContinuousClock.Instant?
    private var isKeyboardDisabled = false
    private var isConfirmingLock = false
    private static let logger = Logger(subsystem: "Devstrand.CleanKeys", category: "KeyboardLock")

    @IBOutlet weak var countdownLabel: NSTextField!
    @IBOutlet weak var disableButton: NSButton!
    @IBOutlet weak var durationSlider: NSSlider!
    @IBOutlet weak var durationLabel: NSTextField!
    @IBOutlet private weak var headingLabel: NSTextField!
    @IBOutlet private weak var supportingLabel: NSTextField!
    @IBOutlet private weak var keyboardIcon: NSImageView!
    @IBOutlet private weak var countdownProgress: NSProgressIndicator!

    private let defaultDisableDurationKey = "defaultDisableDuration"
    private let initialDefaultDuration = 10
    private let maximumLockDuration = 25

    override func viewDidLoad() {
        super.viewDidLoad()
        let savedDuration = UserDefaults.standard.integer(forKey: defaultDisableDurationKey)
        let initialDuration = min(max(savedDuration == 0 ? initialDefaultDuration : savedDuration, 5), maximumLockDuration)
        durationSlider.minValue = 5
        durationSlider.maxValue = Double(maximumLockDuration)
        durationSlider.integerValue = initialDuration
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        countdownLabel.setAccessibilityLabel("Time remaining")
        durationSlider.setAccessibilityLabel("Lock duration in seconds")
        keyboardIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        keyboardIcon.contentTintColor = .secondaryLabelColor
        keyboardIcon.setAccessibilityElement(false)
        disableButton.controlSize = .large
        disableButton.bezelStyle = .rounded
        disableButton.bezelColor = .controlAccentColor
        disableButton.font = .systemFont(ofSize: 15, weight: .semibold)
        countdownProgress.isIndeterminate = false
        countdownProgress.style = .bar
        countdownProgress.controlSize = .small
        countdownProgress.minValue = 0
        countdownProgress.setAccessibilityLabel("Lock time remaining")
        updatePresentation()

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
        updatePresentation()
        UserDefaults.standard.set(duration, forKey: defaultDisableDurationKey)
    }

    private var selectedDuration: Int {
        min(max(durationSlider.integerValue, 5), maximumLockDuration)
    }

    @IBAction func disableInput(_ sender: NSButton) {
        if isKeyboardDisabled {
            enableKeyboard()
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

        guard accessibilityTrusted else {
            ViewController.logger.error("Accessibility permission unavailable; keyboard lock not started.")
            showAlert("Accessibility permission required",
                      "Allow CleanKeys in System Settings > Privacy & Security > Accessibility, then try again. If access is still unavailable, quit and reopen CleanKeys. The keyboard has not been disabled.")
            return
        }

        // Core Graphics has no named systemDefined case; AppKit/NX_SYSDEFINED is type 14.
        let systemDefinedMask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        let eventMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(systemDefinedMask) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, context in
                guard let context = context else {
                    return Unmanaged.passUnretained(event)
                }
                let controller = Unmanaged<ViewController>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Fail open: never silently resume blocking after macOS disables the tap.
                    if type == .tapDisabledByTimeout {
                        ViewController.logger.error("Event tap disabled by timeout; ending keyboard lock.")
                    } else {
                        ViewController.logger.error("Event tap disabled by user input; ending keyboard lock.")
                    }

                    controller.enableKeyboard()
                    return Unmanaged.passUnretained(event)
                }
                guard controller.isKeyboardDisabled,
                      let deadline = controller.unlockDeadline,
                      ContinuousClock.now < deadline else {
                    controller.enableKeyboard()
                    return Unmanaged.passUnretained(event)
                }
                if type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue) {
                    let category = controller.auxiliaryControlCategory(event)
                    // Preserve other subtypes (including auxiliary mouse buttons) and unknown controls.
                    return category == nil ? Unmanaged.passUnretained(event) : nil
                }
                if type == .keyDown || type == .keyUp || type == .flagsChanged {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ViewController.logger.error("Could not create keyboard event tap.")
            showAlert("Could not disable keyboard",
                      "macOS could not create the keyboard event tap. Check CleanKeys in System Settings > Privacy & Security > Accessibility and reopen the app if needed. The keyboard has not been disabled.")
            return
        }
        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            ViewController.logger.error("Could not create keyboard event-tap run-loop source.")
            enableKeyboard()
            showAlert("Could not disable keyboard", "The keyboard event source could not be created. The keyboard has not been disabled.")
            return
        }
        runLoopSource = source
        let duration = selectedDuration
        unlockDeadline = ContinuousClock.now.advanced(by: .seconds(duration))
        isKeyboardDisabled = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        guard CGEvent.tapIsEnabled(tap: tap) else {
            ViewController.logger.error("macOS did not enable the keyboard event tap.")
            enableKeyboard()
            showAlert("Could not disable keyboard", "macOS did not enable the keyboard event tap. Check Accessibility permission and try again.")
            return
        }

        updatePresentation()
        updateCountdown()
        let countdown = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        countdownTimer = countdown
        RunLoop.main.add(countdown, forMode: .common)
        let unlock = Timer(timeInterval: TimeInterval(duration), repeats: false) { [weak self] _ in
            self?.enableKeyboard()
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
            enableKeyboard()
            return
        }
        let remaining = now.duration(to: deadline).components
        let remainingSeconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        // Presentation only: reuse the existing deadline and 0.25-second countdown updates.
        countdownProgress.doubleValue = min(countdownProgress.maxValue, max(0, remainingSeconds))
        let seconds = remaining.seconds + (remaining.attoseconds > 0 ? 1 : 0)
        countdownLabel.stringValue = "\(seconds) \(seconds == 1 ? "second" : "seconds") remaining"
        countdownLabel.setAccessibilityValue(countdownLabel.stringValue)
        countdownLabel.isHidden = false
    }

    @objc private func unlockForNotification(_: Notification) {
        enableKeyboard()
    }

    private func enableKeyboard() {
        cleanupLock()
        updatePresentation()
    }

    // Presentation mirrors the existing lock state; it never starts or stops a session.
    private func updatePresentation() {
        guard isViewLoaded else { return }
        headingLabel.stringValue = isKeyboardDisabled ? "Keyboard Locked" : "CleanKeys"
        supportingLabel.stringValue = isKeyboardDisabled
            ? "Your keyboard is temporarily locked."
            : "Temporarily block keys while you clean."
        durationSlider.isEnabled = !isKeyboardDisabled
        durationSlider.isHidden = isKeyboardDisabled
        durationLabel.isHidden = isKeyboardDisabled
        countdownProgress.isHidden = !isKeyboardDisabled
        if isKeyboardDisabled {
            countdownProgress.maxValue = Double(selectedDuration)
            countdownProgress.doubleValue = countdownProgress.maxValue
        } else {
            countdownProgress.doubleValue = 0
        }
        durationLabel.stringValue = "Lock for \(selectedDuration) seconds"
        durationLabel.textColor = isKeyboardDisabled ? .secondaryLabelColor : .labelColor
        disableButton.title = isKeyboardDisabled ? "Unlock Keyboard" : "Lock Keyboard"
        disableButton.setAccessibilityHelp(isKeyboardDisabled
            ? "Click to restore keyboard input immediately."
            : "Temporarily block keyboard input for the selected duration.")
        // Keep the countdown's fixed-height slot in both states so Unlock never moves.
        countdownLabel.isHidden = false
        if !isKeyboardDisabled {
            countdownLabel.stringValue = ""
            countdownLabel.setAccessibilityValue(nil)
        }
    }

    private func cleanupLock() {
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
