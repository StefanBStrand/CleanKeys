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
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
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
            disableKeyboard()
        }
    }
    
    func disableKeyboard() {
        // Create the HID Manager
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        // Set device matching to nil to get all devices
        IOHIDManagerSetDeviceMatching(manager, nil)
        
        // Open the HID Manager
        if IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
            showAlert("Failed to open HID Manager")
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
        
        // Use a shorter timer for initial testing
        disableTimer = Timer.scheduledTimer(timeInterval: 5.0, target: self, selector: #selector(enableKeyboard), userInfo: nil, repeats: false)
    }

    
    @objc func enableKeyboard() {
        keyboardDevices?.forEach { device in
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
                showAlert("Failed to re-enable keyboard")
            }}
        disableTimer?.invalidate()
    }
    
    
    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
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

