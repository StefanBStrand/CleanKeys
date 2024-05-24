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
    var devices: Set<IOHIDDevice>?
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
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        
        if IOHIDManagerOpen(manager!, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
            showAlert("Failed to open HID manager")
            return
        }
        
        let devices = IOHIDManagerCopyDevices(manager!) as? Set<IOHIDDevice>
        keyboardDevices = devices?.filter { device in
            guard let properties = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) else {
                return false
                
            }
            
            let usagePage = properties as! Int
            return usagePage == kHIDPage_GenericDesktop && (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as! Int == kHIDUsage_GD_Keyboard)
        }
        
    }
    
    

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }


}

