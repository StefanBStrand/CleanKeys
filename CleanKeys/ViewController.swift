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
        // Create the HID Manager
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        // Set the device matching to filter keyboards
        let matchingDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matchingDict as CFDictionary)

        
        // Open the HID Manager
        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            if openStatus != kIOReturnSuccess {
                showAlert("Failed to open HID Manager", "Error code: \(openStatus)")
                return
            }
            print("HID Manager opened successfully.")
        
        // Get the set of all HID devices
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            showAlert("Failed to get HID devices")
            return
        }
        
        // Filter the devices to get only keyboards
        keyboardDevices = devices.filter { device in
            guard let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int,
                  let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int else {
                return false
            }
            return usagePage == kHIDPage_GenericDesktop && usage == kHIDUsage_GD_Keyboard
        }
        
        if keyboardDevices?.isEmpty ?? true {
            showAlert("No keyboard devices found")
            return
        }


        // Close (disable) each keyboard device
        keyboardDevices?.forEach { device in
            let closeStatus = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if closeStatus != kIOReturnSuccess {
                showAlert("Failed to disable keyboard", "Error code: \(closeStatus)")
            } else {
                print("Keyboard device disabled: \(device)")
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
            let openStatus = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if openStatus != kIOReturnSuccess {
                showAlert("Failed to re-enable keyboard", "Error code: \(openStatus)")
            } else {
                print("Keyboard device re-enabled: \(device)")
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
 

