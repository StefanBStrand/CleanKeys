//
//  ViewController.swift
//  CleanKeys
//
//  Created by Stefan Boytchev on 21/05/2024.
//

import IOKit.hid
import Cocoa
import Carbon

class ViewController: NSViewController {
    
    var disableTimer: Timer?
    var countdownTimer: Timer?
    var remainingTime: Int = 5
    var eventTap: CFMachPort?
    var globalMonitor: Any?
    var isKeyboardDisabled = false
    
    @IBOutlet weak var countdownLabel: NSTextField!
    @IBOutlet weak var disableButton: NSButton!
    @IBOutlet weak var durationSlider: NSSlider!
    @IBOutlet weak var durationLabel: NSTextField!
    
    let defaultDisableDurationKey = "defaultDisableDuration"
    let initialDefaultDuration = 10 // Default value for the first time the app starts
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Initialize the countdown label
        countdownLabel.isHidden = true
        
        // Set default value if it's the first launch
        let savedDuration = UserDefaults.standard.integer(forKey: defaultDisableDurationKey)
        let initialDuration = savedDuration != 0 ? savedDuration : initialDefaultDuration
        durationSlider.minValue = 5
        durationSlider.maxValue = 25
        durationSlider.doubleValue = Double(initialDuration)
        durationLabel.stringValue = "Disable for \(initialDuration) seconds"

        // Check if the button outlet is properly set
        if disableButton == nil {
            print("disableButton outlet is nil in viewDidLoad")
        } else {
            print("disableButton outlet is properly connected in viewDidLoad")
        }
        
        registerGlobalHotkey()
    }
    
    
    @IBAction func durationSliderChanged(_ sender: NSSlider) {
        let selectedDuration = Int(sender.doubleValue)
        durationLabel.stringValue = "Disable for \(selectedDuration) seconds"
        
        // Save the selected duration
        UserDefaults.standard.set(selectedDuration, forKey: defaultDisableDurationKey)
        }
    
    
    @IBAction func disableInput(_ sender: NSButton) {
        DispatchQueue.main.async {
            if self.isKeyboardDisabled {
                self.enableKeyboard()
            } else {
                let selectedDuration = Int(self.durationSlider.doubleValue)
                let alert = NSAlert()
                alert.messageText = "Disable Input"
                alert.informativeText = "This will disable your keyboard for \(selectedDuration) seconds. Do you want to proceed?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Disable")
                alert.addButton(withTitle: "Cancel")
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    self.handleGlobalHotkey()
                    sender.title = "Enable Keys"
                }
            }
        }
    }
    
    
    
    func registerGlobalHotkey() {
        let keyCode = UInt16(kVK_ANSI_D) // Replace with the desired keycode
        let modifierFlags: NSEvent.ModifierFlags = [.command, .shift] // Replace with desired modifiers

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == keyCode && event.modifierFlags.contains(modifierFlags) {
                self?.handleGlobalHotkey()
            }
        }
    }
    
    func handleGlobalHotkey() {
        DispatchQueue.main.async {
            if self.requestInputMonitoringPermission() {
                print("Permission granted, proceeding to disable keyboard")
                self.showAppWindow() // Ensure the app window is visible
                self.disableKeyboard()
                
                // Update the button title
                self.disableButton.title = "Enable Keys"
            } else {
                self.showAlert("Permission required", "This app requires permission to monitor keyboard input. Please grant the necessary permissions in System Preferences.")
            }
        }
    }
    
    func showAppWindow() {
        DispatchQueue.main.async {
            if let window = self.view.window {
                if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
                    window.setFrameOrigin(NSPoint(x: screen.frame.midX - window.frame.width / 2, y: screen.frame.midY - window.frame.height / 2))
                }
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
    
    func requestInputMonitoringPermission() -> Bool {
        // Request input monitoring permission if not already granted
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let permissionsGranted = AXIsProcessTrustedWithOptions(options)
        print("Input monitoring permission granted: \(permissionsGranted)")
        return permissionsGranted
    }

    func disableKeyboard() {
        print("Disabling keyboard...")
        
        // Set up an event tap to intercept and ignore keyboard events
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, eventType, event, refcon) -> Unmanaged<CGEvent>? in
                if eventType == .keyDown || eventType == .keyUp {
                    // Ignore the event
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        
        guard let eventTap = eventTap else {
            showAlert("Failed to create event tap")
            return
        }
        
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        // Show the countdown label and start the countdown timer
        remainingTime = Int(durationSlider.doubleValue) // Use the selected duration from the slider
        countdownLabel.stringValue = "Disabling keyboard for \(remainingTime) seconds"
        countdownLabel.isHidden = false
        countdownTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateCountdown), userInfo: nil, repeats: true)
        
        // Use a timer to re-enable the keyboard after the selected duration
        disableTimer = Timer.scheduledTimer(timeInterval: TimeInterval(remainingTime), target: self, selector: #selector(enableKeyboard), userInfo: nil, repeats: false)
        
        isKeyboardDisabled = true
        print("Keyboard disabled, button title should be 'Enable Keys'")
    }
    
    @objc func updateCountdown() {
        remainingTime -= 1
        if remainingTime > 0 {
            countdownLabel.stringValue = "Disabling keyboard for \(remainingTime) seconds"
        } else {
            countdownLabel.stringValue = "Re-enabling keyboard..."
            countdownTimer?.invalidate()
        }
    }
    
    @objc func enableKeyboard() {
        print("Enabling keyboard...")
        
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0), .commonModes)
            self.eventTap = nil
        }
        
        disableTimer?.invalidate()
        countdownLabel.isHidden = true
        
        DispatchQueue.main.async {
            print("Updating button title to 'Disable Keys'")
            if let button = self.disableButton {
                button.title = "Disable Keys"
                self.view.layoutSubtreeIfNeeded()
                print("Button title is now: \(button.title)")
            } else {
                print("disableButton is nil")
            }
        }
        
        isKeyboardDisabled = false
        print("Keyboard enabled, button title should be 'Disable Keys'")
    }
    
    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    deinit {
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
}

