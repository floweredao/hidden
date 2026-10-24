//
//  ViewController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/24/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import Cocoa
import Carbon
import HotKey

class PreferencesViewController: NSViewController {
    
   
    //MARK: - Outlets
    @IBOutlet weak var checkBoxKeepLastState: NSButton!
    @IBOutlet weak var textFieldTitle: NSTextField!
    @IBOutlet weak var imageViewTop: NSImageView!
    
    @IBOutlet weak var statusBarStackView: NSStackView!
    @IBOutlet weak var arrowPointToHiddenImage: NSImageView!
    @IBOutlet weak var arrowPointToAlwayHiddenImage: NSImageView!
    @IBOutlet weak var lblAlwayHidden: NSTextField!
    
    
    
    @IBOutlet weak var checkBoxAutoHide: NSButton!
    @IBOutlet weak var checkBoxKeepInDock: NSButton!
    @IBOutlet weak var checkBoxLogin: NSButton!
    @IBOutlet weak var checkBoxShowPreferences: NSButton!
    @IBOutlet weak var checkBoxShowAlwaysHiddenSection: NSButton!
    
    @IBOutlet weak var checkBoxUseFullStatusbar: NSButton!
    @IBOutlet weak var timePopup: NSPopUpButton!
    
    @IBOutlet weak var btnClear: NSButton!
    @IBOutlet weak var btnShortcut: NSButton!

    @IBOutlet weak var checkBoxNotchOverflow: NSButton!

    // Why the login item could not be changed, right under its checkbox.
    private let loginErrorRow = NSStackView()

    public var listening = false {
        didSet {
            let isHighlight = listening
            
            DispatchQueue.main.async { [weak self] in
                self?.btnShortcut.highlight(isHighlight)
            }
        }
    }
    
    //MARK: - VC Life cycle
    override func viewDidLoad() {
        super.viewDidLoad()
        updateData()
        loadHotkey()
        layOutTutorialArea()
        createTutorialView()
        // The row lives in the storyboard alongside the other Settings
        // checkboxes; hide it on hardware where the feature can't apply.
        // The containing stack view (detachesHiddenViews) reflows on its own.
        checkBoxNotchOverflow.isHidden = !NotchOverflowController.hasNotch
        // The ⌫ title alone is read as a symbol, not as what the button does.
        btnClear.setAccessibilityLabel("Clear Global Shortcut".localized)
        btnClear.toolTip = "Clear Global Shortcut".localized
        setUpLoginErrorRow()
        makeTextAndTargetsFlexible()
        // The shortcut is shown as the current keyboard layout types it.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(inputSourceChanged),
                                                            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateData), name: .prefsChanged, object: nil)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        (NSApp.delegate as? AppDelegate)?.statusBarController?.refreshArrangement()
    }

    deinit {
        // Balance the viewDidLoad observer (PRs #335/#346).
        NotificationCenter.default.removeObserver(self, name: .prefsChanged, object: nil)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    static func initWithStoryboard() -> PreferencesViewController {
        let vc = NSStoryboard(name:"Main", bundle: nil).instantiateController(withIdentifier: "prefVC") as! PreferencesViewController
        return vc
    }
    
    //MARK: - Actions
    @IBAction func loginCheckChanged(_ sender: NSButton) {
        let wanted = sender.state == .on
        Preferences.isAutoStart = wanted
        // On failure the pref reverts (the checkbox already snapped back via
        // prefsChanged); say why right under it, without blocking the window.
        loginErrorRow.isHidden = Preferences.isAutoStart == wanted
    }

    @objc private func inputSourceChanged() {
        loadHotkey()
    }

    @objc private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setUpLoginErrorRow() {
        guard let column = checkBoxLogin.superview as? NSStackView,
              let index = column.arrangedSubviews.firstIndex(of: checkBoxLogin) else { return }
        let message = NSTextField(wrappingLabelWithString: "Could not update the login item".localized + ". "
                                  + "Check System Settings > General > Login Items and make sure Hidden Bar is allowed.".localized)
        message.textColor = .systemRed
        message.preferredMaxLayoutWidth = 300
        let open = NSButton(title: "Open Login Items Settings…".localized, target: self, action: #selector(openLoginItemsSettings))
        open.bezelStyle = .rounded
        loginErrorRow.setViews([message, open], in: .leading)
        loginErrorRow.orientation = .vertical
        loginErrorRow.alignment = .leading
        loginErrorRow.spacing = 6
        loginErrorRow.isHidden = true
        column.insertArrangedSubview(loginErrorRow, at: index + 1)
    }

    // The storyboard fixes sizes for one language at the default text size:
    // the description wraps instead of clipping, and every checkbox and the
    // help button get room to hit (20pt rows, 28pt help target).
    private func makeTextAndTargetsFlexible() {
        if let cell = textFieldTitle.cell {
            cell.wraps = true
            cell.lineBreakMode = .byWordWrapping
            cell.usesSingleLineMode = false
        }
        textFieldTitle.maximumNumberOfLines = 0
        textFieldTitle.preferredMaxLayoutWidth = 560
        let checkBoxes: [NSButton] = [checkBoxLogin, checkBoxShowPreferences, checkBoxUseFullStatusbar,
                                      checkBoxShowAlwaysHiddenSection, checkBoxAutoHide, checkBoxNotchOverflow]
        for box in checkBoxes {
            box.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        }
        // The shortcut buttons are the only other targets small enough to miss.
        for button in [btnShortcut, btnClear] {
            button?.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        if let help = checkBoxShowAlwaysHiddenSection.superview?.subviews
            .compactMap({ $0 as? NSButton }).first(where: { $0.bezelStyle == .helpButton }) {
            help.setAccessibilityLabel("How to Use the Always Hidden Section".localized)
            NSLayoutConstraint.activate([
                help.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
                help.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            ])
        }
    }
    
    @IBAction func autoHideCheckChanged(_ sender: NSButton) {
        Preferences.isAutoHide = sender.state == .on
    }
    
    @IBAction func showPreferencesChanged(_ sender: NSButton) {
        Preferences.isShowPreference = sender.state == .on
    }
    
    
    @IBAction func showAlwaysHiddenSectionChanged(_ sender: NSButton) {
        Preferences.alwaysHiddenSectionEnabled = sender.state == .on
        createTutorialView()
    }
    @IBAction func useFullStatusBarOnExpandChanged(_ sender: NSButton) {
        Preferences.useFullStatusBarOnExpandEnabled = sender.state == .on
    }
    
    
    @IBAction func timePopupDidSelected(_ sender: NSPopUpButton) {
        let selectedIndex = sender.indexOfSelectedItem
        if let selectedInSecond = SelectedSecond(rawValue: selectedIndex)?.toSeconds() {
            Preferences.numberOfSecondForAutoHide = selectedInSecond
        }
    }
    
    // When the set shortcut button is pressed start listening for the new shortcut
    @IBAction func register(_ sender: Any) {
        listening = true
        view.window?.makeFirstResponder(nil)
    }
    
    // If the shortcut is cleared, clear the UI and tell AppDelegate to stop listening to the previous keybind.
    @IBAction func unregister(_ sender: Any?) {
        let appDelegate = NSApplication.shared.delegate as! AppDelegate
        appDelegate.hotKey = nil
        btnShortcut.title = "Set Shortcut".localized
        listening = false
        btnClear.isEnabled = false
        
        // Remove globalkey from userdefault
        Preferences.globalKey = nil
    }
    
    public func updateGlobalShortcut(_ event: NSEvent) {
        self.listening = false
        
        guard let characters = event.charactersIgnoringModifiers else {return}
        
        let newGlobalKeybind = GlobalKeybindPreferences(
            function: event.modifierFlags.contains(.function),
            control: event.modifierFlags.contains(.control),
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            capsLock: event.modifierFlags.contains(.capsLock),
            carbonFlags: event.modifierFlags.carbonFlags,
            characters: characters,
            keyCode: uint32(event.keyCode))
        
        Preferences.globalKey = newGlobalKeybind
        
        updateKeybindButton(newGlobalKeybind)
        btnClear.isEnabled = true
        
        let appDelegate = NSApplication.shared.delegate as! AppDelegate
        appDelegate.hotKey = HotKey(keyCombo: KeyCombo(carbonKeyCode: UInt32(event.keyCode), carbonModifiers: event.modifierFlags.carbonFlags))
    }
    
    public func updateModiferFlags(_ event: NSEvent) {
        let newGlobalKeybind = GlobalKeybindPreferences(
            function: event.modifierFlags.contains(.function),
            control: event.modifierFlags.contains(.control),
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            capsLock: event.modifierFlags.contains(.capsLock),
            carbonFlags: 0,
            characters: nil,
            keyCode: uint32(event.keyCode))
        
        updateModifierbindButton(newGlobalKeybind)
        
    }
    
    @objc private func updateData(){
        checkBoxUseFullStatusbar.state = Preferences.useFullStatusBarOnExpandEnabled ? .on : .off
        checkBoxLogin.state = Preferences.isAutoStart ? .on : .off
        checkBoxAutoHide.state = Preferences.isAutoHide ? .on : .off
        checkBoxShowPreferences.state = Preferences.isShowPreference ? .on : .off
        checkBoxShowAlwaysHiddenSection.state = Preferences.alwaysHiddenSectionEnabled ? .on : .off
        timePopup.selectItem(at: SelectedSecond.secondToPossition(seconds: Preferences.numberOfSecondForAutoHide))
        checkBoxNotchOverflow.state = Preferences.notchOverflowEnabled ? .on : .off
    }
    
    private func loadHotkey() {
        if let globalKey = Preferences.globalKey {
            updateKeybindButton(globalKey)
            updateClearButton(globalKey)
        }
    }
    
    // Set the shortcut button to show the keys to press
    private func updateKeybindButton(_ globalKeybindPreference : GlobalKeybindPreferences) {
        btnShortcut.title = globalKeybindPreference.description
        
        if globalKeybindPreference.description.count <= 1 {
            unregister(nil)
        }
    }
    
    // Set the shortcut button to show the modifier to press
      private func updateModifierbindButton(_ globalKeybindPreference : GlobalKeybindPreferences) {
          btnShortcut.title = globalKeybindPreference.description
          
          if globalKeybindPreference.description.isEmpty {
              unregister(nil)
          }
      }
    
    // If a keybind is set, allow users to clear it by enabling the clear button.
    private func updateClearButton(_ globalKeybindPreference : GlobalKeybindPreferences?) {
        btnClear.isEnabled = globalKeybindPreference != nil
    }
}

extension PreferencesViewController {
    // The picture matches the original app: the hidden section is closed by a
    // visible | before the arrow, whichever engine runs.
    static func tutorialIconNames(alwaysHidden: Bool) -> [String] {
        alwaysHidden
            ? ["ico_1","ico_2","ico_3","ico_4","seprated_1","ico_5","ico_6","seprated","ico_collapse","ico_7"]
            : ["ico_1","ico_2","ico_3","seprated","ico_collapse","ico_4","ico_5","ico_6","ico_7"]
    }

}

//MARK: - Notch Overflow Section
extension PreferencesViewController {

    @IBAction func notchOverflowCheckChanged(_ sender: NSButton) {
        Preferences.notchOverflowEnabled = sender.state == .on
    }

}

//MARK: - Show tutorial
extension PreferencesViewController {

    // The window uses a full-size content view, so the tutorial box runs under
    // the toolbar. The storyboard pins the mock menu bar 38pt below the box's
    // top, which sat clear of the old toolbar; the taller macOS 26+ toolbar
    // covers that spot, so pin it below the safe area instead. The window also
    // sizes itself to the Settings rows, which can be narrower than the
    // always-hidden tutorial (its leftmost label was cut off), so keep it wide
    // enough for the tutorial.
    private func layOutTutorialArea() {
        if let box = statusBarStackView.superview {
            box.constraints
                .filter { $0.firstItem === statusBarStackView && $0.firstAttribute == .top }
                .forEach { $0.isActive = false }
        }
        NSLayoutConstraint.activate([
            statusBarStackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 660)
        ])
    }
    
    func createTutorialView() {
        if Preferences.alwaysHiddenSectionEnabled {
            alwayHideStatusBar()
        }else {
            hideStatusBar()
        }
    }
    
    func hideStatusBar() {
        lblAlwayHidden.isHidden = true
        arrowPointToAlwayHiddenImage.isHidden = true
        statusBarStackView.removeAllSubViews()
        let imageWidth: CGFloat = 16
        
        
        let names = Self.tutorialIconNames(alwaysHidden: false)
        let images = names.map { imageName in
            NSImageView(image: NSImage(named: imageName)!)
        }
        
        
        for image in images {
            statusBarStackView.addArrangedSubview(image)
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: imageWidth),
                image.heightAnchor.constraint(equalToConstant: imageWidth)
                
            ])
            image.contentTintColor = .labelColor
        }
        let dateTimeLabel = NSTextField()
        dateTimeLabel.stringValue = Date.dateString() + " " + Date.timeString()
        dateTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        dateTimeLabel.isBezeled = false
        dateTimeLabel.isEditable = false
        dateTimeLabel.sizeToFit()
        dateTimeLabel.backgroundColor = .clear
        statusBarStackView.addArrangedSubview(dateTimeLabel)
       
        NSLayoutConstraint.activate([
            arrowPointToHiddenImage.centerXAnchor.constraint(equalTo: statusBarStackView.arrangedSubviews[3].centerXAnchor)
        ])
    }
    
    func alwayHideStatusBar() {
        lblAlwayHidden.isHidden = false
        arrowPointToAlwayHiddenImage.isHidden = false
        statusBarStackView.removeAllSubViews()
        let imageWidth: CGFloat = 16
        
        
        let names = Self.tutorialIconNames(alwaysHidden: true)
        let boundaryIndex = 7
        let images = names.map { imageName in
            NSImageView(image: NSImage(named: imageName)!)
        }
        
        
        for image in images {
            statusBarStackView.addArrangedSubview(image)
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: imageWidth),
                image.heightAnchor.constraint(equalToConstant: imageWidth)
                
            ])
            image.contentTintColor = .labelColor
        }
        let dateTimeLabel = NSTextField()
        dateTimeLabel.stringValue = Date.dateString() + " " + Date.timeString()
        dateTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        dateTimeLabel.isBezeled = false
        dateTimeLabel.isEditable = false
        dateTimeLabel.sizeToFit()
        dateTimeLabel.backgroundColor = .clear
        statusBarStackView.addArrangedSubview(dateTimeLabel)
        
        NSLayoutConstraint.activate([
            arrowPointToAlwayHiddenImage.centerXAnchor.constraint(equalTo: statusBarStackView.arrangedSubviews[4].centerXAnchor)
        ])
        NSLayoutConstraint.activate([
            arrowPointToHiddenImage.centerXAnchor.constraint(equalTo: statusBarStackView.arrangedSubviews[boundaryIndex].centerXAnchor)
        ])
    }

    @IBAction func btnAlwayHiddenHelpPressed(_ sender: NSButton) {
        self.showHowToUseAlwayHiddenPopover(sender: sender)
    }
    
    private func showHowToUseAlwayHiddenPopover(sender: NSButton) {
        let controller = NSViewController()
        let text = NSLocalizedString("Tutorial text", comment: "Step by step tutorial")
        // Wraps instead of running one line per paragraph, so long translations
        // and larger text stay inside the popover.
        let label = NSTextField(wrappingLabelWithString: text.trimmingCharacters(in: .whitespacesAndNewlines))
        label.preferredMaxLayoutWidth = 360
        let view = NSView()
        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            label.widthAnchor.constraint(equalToConstant: 360)
        ])
        controller.view = view
        
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = view.fittingSize
        
        popover.behavior = .transient
        popover.animates = true
        
        // Anchored to the help button's own bounds (the rect is in the button's
        // coordinates); AppKit moves it to another edge when there is no room.
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: NSRectEdge.maxX)
    }
}
