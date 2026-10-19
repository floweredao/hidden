//
//  AboutViewController.swift
//  Hidden Bar
//
//  Created by phucld on 12/19/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import Cocoa

class AboutViewController: NSViewController {

    @IBOutlet weak var lblVersion: NSTextField!
    
    static func initWithStoryboard() -> AboutViewController {
        let vc = NSStoryboard(name:"Main", bundle: nil).instantiateController(withIdentifier: "aboutVC") as! AboutViewController
        return vc
    }
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        guard let version = Bundle.main.forkVersionNumber ?? Bundle.main.releaseVersionNumber,
                let buildNumber = Bundle.main.buildVersionNumber else { return }
        let build = [buildNumber, Bundle.main.gitCommit].compactMap { $0 }.joined(separator: " · ")
        lblVersion.stringValue += " \(version) (\(build))"
        #if HIDDENBAR_UPDATER
        addCheckForUpdatesButton()
        #endif
    }

    #if HIDDENBAR_UPDATER
    private func addCheckForUpdatesButton() {
        guard let updater = (NSApp.delegate as? AppDelegate)?.updaterController,
              let stack = lblVersion.superview as? NSStackView else { return }
        let button = NSButton(title: "Check for Updates…".localized, target: updater,
                              action: #selector(updater.checkForUpdates(_:)))
        button.bezelStyle = .rounded
        stack.addArrangedSubview(button)
    }
    #endif
    
}
