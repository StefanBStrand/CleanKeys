//
//  ViewController.swift
//  CleanKeys
//
//  Created by Stefan Boytchev on 21/05/2024.
//

import Cocoa
import IOKit.hid

class ViewController: NSViewController {
    
    var disableTimer: Timer?
    var countdownTimer: Timer?
    var remainingTime: Int = 5
    var eventTap: CFMachPort?
    @IBOutlet weak var countdownLabel: NSTextField!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Initialize the countdown label
        countdownLabel.isHidden = true
    }
    
    @IBAction func disableInput(_ sender: NSButtonCell) {
        let alert = NSAlert()
        alert.messageText = "Disable Input"
        alert.informativeText = "This will disable your keyboard for 5 seconds. Do you want to proceed?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Disable")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if requestInputMonitoringPermission() {
                print("Permission granted, proceeding to disable keyboard")
                disableKeyboard()
            } else {
                showAlert("Permission required", "This app requires permission to monitor keyboard input. Please grant the necessary permissions in System Preferences.")
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
        remainingTime = 5
        countdownLabel.stringValue = "Disabling keyboard for \(remainingTime) seconds"
        countdownLabel.isHidden = false
        countdownTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateCountdown), userInfo: nil, repeats: true)
        
        // Use a timer to re-enable the keyboard after 5 seconds
        disableTimer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(enableKeyboard), userInfo: nil, repeats: false)
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
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0), .commonModes)
            self.eventTap = nil
        }
        
        disableTimer?.invalidate()
        countdownLabel.isHidden = true
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
}


