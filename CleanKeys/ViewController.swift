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
        
    }
    
    

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }


}

