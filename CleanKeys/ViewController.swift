//
//  ViewController.swift
//  CleanKeys
//
//  Created by Stefan Boytchev on 21/05/2024.
//

import Cocoa
import IOKit.hid

class ViewController: NSViewController {
    
    var manager: IOHIDManager?
    var keyboardDevices: Set<IOHIDDevice>?
    var disableTimer: Timer?
    var countdownTimer: Timer?
    var remainingTime: Int = 5
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
                disableKeyboard()
            } else {
                showAlert("Permission required", "This app requires permission to monitor keyboard input. Please grant the necessary permissions in System Preferences.")
            }
        }
    }
    
    func requestInputMonitoringPermission() -> Bool {
        // Request input monitoring permission if not already granted
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options)
    }

    func disableKeyboard() {
        // Create the HID Manager
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        // Set device matching to nil to get all devices
        IOHIDManagerSetDeviceMatching(manager, nil)
        
        // Open the HID Manager
        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if openStatus != kIOReturnSuccess {
                showAlert("Failed to open HID Manager", "Error code: \(openStatus)")
                return
            }
        
        // Get the set of all HID devices
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            showAlert("Failed to get HID devices")
            return
        }
        
        // Filter the devices to get only keyboards
        keyboardDevices = devices.filter { device in
            guard let properties = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) else {
                return false
            }
            let usagePage = properties as! Int
            return usagePage == kHIDPage_GenericDesktop && (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as! Int == kHIDUsage_GD_Keyboard)
        }
        
        // Close (disable) each keyboard device
        keyboardDevices?.forEach { device in
            if IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
                showAlert("Failed to disable keyboard")
            }
        }
        
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
        keyboardDevices?.forEach { device in
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
                showAlert("Failed to re-enable keyboard")
            }
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

