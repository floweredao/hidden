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

    // Why the bar does not hide (see StatusBarController.hidingProblem), with
    // the action that fixes it. Hidden while hiding works.
    private let hidingStatusRow = NSStackView()
    private let hidingStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let hidingStatusButton = NSButton()

    // Why the login item could not be changed, right under its checkbox.
    private let loginErrorRow = NSStackView()

    // macOS 27 direct build only: what expanding shows (see setUpSystemIndicatorsCheckBox).
    private let checkBoxSystemIndicators = NSButton(checkboxWithTitle: "Show Focus and mic/camera indicators when expanded".localized,
                                                    target: nil, action: nil)

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
        setUpMenuBarItemsButton()
        setUpSystemIndicatorsCheckBox()
        setUpHidingStatusRow()
        // The ⌫ title alone is read as a symbol, not as what the button does.
        btnClear.setAccessibilityLabel("Clear Global Shortcut".localized)
        btnClear.toolTip = "Clear Global Shortcut".localized
        setUpLoginErrorRow()
        makeTextAndTargetsFlexible()
        // The shortcut is shown as the current keyboard layout types it.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(inputSourceChanged),
                                                            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateData), name: .prefsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateHidingStatus), name: .hidingStatusChanged, object: nil)
    }

    deinit {
        // Balance the viewDidLoad observer (PRs #335/#346).
        NotificationCenter.default.removeObserver(self, name: .prefsChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .hidingStatusChanged, object: nil)
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
        checkBoxSystemIndicators.state = Preferences.showsSystemIndicatorsWhenExpanded ? .on : .off
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

//MARK: - Menu Bar Items (sections without ⌘-drag)
extension PreferencesViewController {

    private var statusBarController: StatusBarController? {
        return (NSApp.delegate as? AppDelegate)?.statusBarController
    }

    // ⌘-drag needs a pointer, so where the engine allows it each app's section
    // can also be chosen here, by keyboard or VoiceOver. Placed right under the
    // always-hidden row, the setting it belongs with.
    fileprivate func setUpMenuBarItemsButton() {
        guard let statusBar = statusBarController, statusBar.supportsSectionAssignment,
              let row = checkBoxShowAlwaysHiddenSection.superview,
              let column = row.superview as? NSStackView,
              let index = column.arrangedSubviews.firstIndex(of: row) else { return }
        let button = NSButton(title: "Menu Bar Items…".localized, target: self, action: #selector(showMenuBarItems(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityHelp("Choose which section each app's menu bar icon is in, without dragging.".localized)
        column.insertArrangedSubview(button, at: index + 1)
    }

    // Only the assessment engine hides the Focus icon and the mic/camera capsule
    // while anything is hidden; this option makes it hide nothing when expanded
    // so they show. The allow-list engine never wires it (Focus and the capture
    // dot stay visible while collapsed), so the checkbox would do nothing there.
    // Placed under the always-hidden settings.
    fileprivate func setUpSystemIndicatorsCheckBox() {
        guard MenuBarEngineFactory.usesArrowAsBoundary,
              !MenuBarEngineFactory.usesMenuBarSettings,
              let row = checkBoxShowAlwaysHiddenSection.superview,
              let column = row.superview as? NSStackView,
              let rowIndex = column.arrangedSubviews.firstIndex(of: row) else { return }
        // After the Menu Bar Items… button when there is one.
        let menuBarItemsIndex = column.arrangedSubviews.firstIndex { ($0 as? NSButton)?.action == #selector(showMenuBarItems(_:)) }
        let index = (menuBarItemsIndex ?? rowIndex) + 1
        checkBoxSystemIndicators.target = self
        checkBoxSystemIndicators.action = #selector(systemIndicatorsChanged(_:))
        let help = "macOS hides these while any icon is hidden. When this is on, the always-hidden section also shows while expanded.".localized
        checkBoxSystemIndicators.toolTip = help
        checkBoxSystemIndicators.setAccessibilityHelp(help)
        checkBoxSystemIndicators.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        checkBoxSystemIndicators.state = Preferences.showsSystemIndicatorsWhenExpanded ? .on : .off
        column.insertArrangedSubview(checkBoxSystemIndicators, at: index)
    }

    @objc private func systemIndicatorsChanged(_ sender: NSButton) {
        Preferences.showsSystemIndicatorsWhenExpanded = sender.state == .on
    }

    // At the top of the settings column, so it is the first thing read.
    fileprivate func setUpHidingStatusRow() {
        guard let column = checkBoxLogin.superview as? NSStackView else { return }
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                              accessibilityDescription: "Warning".localized) ?? NSImage())
        icon.contentTintColor = .systemYellow
        icon.setContentHuggingPriority(.required, for: .horizontal)
        hidingStatusButton.bezelStyle = .rounded
        hidingStatusButton.target = self
        hidingStatusButton.action = #selector(fixHidingProblem(_:))
        hidingStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hidingStatusLabel.preferredMaxLayoutWidth = 300
        let text = NSStackView(views: [hidingStatusLabel, hidingStatusButton])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        hidingStatusRow.setViews([icon, text], in: .leading)
        hidingStatusRow.orientation = .horizontal
        hidingStatusRow.alignment = .top
        hidingStatusRow.spacing = 8
        column.insertArrangedSubview(hidingStatusRow, at: 0)
        updateHidingStatus()
    }

    @objc func updateHidingStatus() {
        guard let problem = statusBarController?.hidingProblem else {
            hidingStatusRow.isHidden = true
            return
        }
        hidingStatusLabel.stringValue = StatusBarController.describe(problem)
        hidingStatusButton.title = Self.hidingFixTitle(for: problem)
        hidingStatusRow.isHidden = false
    }

    static func hidingFixTitle(for problem: HidingUnavailableReason) -> String {
        // Same wording as the status item's context menu.
        switch problem {
        case .fileAccessNeeded: return "Grant Access…".localized
        case .accessibilityNeeded: return "Open Accessibility Settings…".localized
        default: return "Try Hiding Again".localized
        }
    }

    // The picture matches the original app: the hidden section is closed by a
    // visible | before the arrow, whichever engine runs.
    static func tutorialIconNames(alwaysHidden: Bool) -> [String] {
        alwaysHidden
            ? ["ico_1","ico_2","ico_3","ico_4","seprated_1","ico_5","ico_6","seprated","ico_collapse","ico_7"]
            : ["ico_1","ico_2","ico_3","seprated","ico_collapse","ico_4","ico_5","ico_6","ico_7"]
    }

    @objc private func fixHidingProblem(_ sender: NSButton) {
        guard let statusBar = statusBarController else { return }
        if statusBar.hidingProblem == .accessibilityNeeded {
            statusBar.openAccessibilitySettings()
        } else if statusBar.hidingProblem == .fileAccessNeeded {
            statusBar.grantAccess()
        } else {
            statusBar.retryHiding()
        }
    }

    @objc func showMenuBarItems(_ sender: Any?) {
        guard let statusBar = statusBarController else { return }
        presentAsSheet(MenuBarItemsViewController(statusBar: statusBar))
    }
}

// Lists the apps with menu bar icons, each with a pop-up for its section:
// where it was ⌘-dragged (the default), or Shown, Hidden or Always Hidden.
// Plain controls, so Tab, the arrow keys and VoiceOver reach every app.
final class MenuBarItemsViewController: NSViewController {
    private static let positionTag = -1

    private let statusBar: StatusBarController
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton()
    private let listContainer = FlippedView()
    private var grid: NSGridView?

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
        super.init(nibName: nil, bundle: nil)
        title = "Menu Bar Items".localized
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let titleLabel = NSTextField(labelWithString: "Menu Bar Items".localized)
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.setAccessibilityRole(.staticText)

        let info = NSTextField(wrappingLabelWithString: "Choose a section for each app. “By Position” follows where you ⌘-drag the icon in the menu bar.".localized)
        info.textColor = .secondaryLabelColor

        openSettingsButton.title = "Open Accessibility Settings…".localized
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openAccessibilitySettings)
        openSettingsButton.isHidden = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = listContainer
        scroll.translatesAutoresizingMaskIntoConstraints = false
        listContainer.translatesAutoresizingMaskIntoConstraints = false

        let refresh = NSButton(title: "Refresh".localized, target: self, action: #selector(reload))
        refresh.bezelStyle = .rounded
        let done = NSButton(title: "Done".localized, target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [refresh, NSView(), done])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, info, statusLabel, openSettingsButton, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            info.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 300),
            listContainer.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            listContainer.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            listContainer.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
    }

    // Esc closes the sheet, like Done.
    override func cancelOperation(_ sender: Any?) {
        done()
    }

    @objc private func done() {
        dismiss(nil)
    }

    @objc private func openAccessibilitySettings() {
        Util.openAccessibilitySettings()
    }

    @objc private func reload() {
        statusLabel.stringValue = "Reading menu bar items…".localized
        statusLabel.isHidden = false
        openSettingsButton.isHidden = true
        statusBar.readSections { [weak self] layout in
            self?.show(layout)
        }
    }

    private func show(_ layout: MenuBarLayout?) {
        grid?.removeFromSuperview()
        grid = nil
        guard AXIsProcessTrusted() else {
            statusLabel.stringValue = "Hidden Bar needs the Accessibility permission to read the menu bar. Allow it in System Settings > Privacy & Security > Accessibility.".localized
            openSettingsButton.isHidden = false
            return
        }
        let positions = layout?.sections ?? [:]
        let overrides = Preferences.sectionOverrides
        let bundles = Set(positions.keys).union(overrides.keys)
        guard !bundles.isEmpty else {
            statusLabel.stringValue = layout == nil
                ? "The menu bar could not be read. Try Refresh.".localized
                : "No other app has a menu bar icon right now.".localized
            return
        }
        statusLabel.stringValue = layout?.isCached == true
            ? "Showing the last arrangement; expand to refresh positions.".localized : ""
        statusLabel.isHidden = layout?.isCached != true

        let entries = bundles.map { (bundle: $0, name: Self.displayName(of: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let rows: [[NSView]] = entries.map { entry in
            let icon = NSImageView(image: Self.icon(of: entry.bundle))
            icon.setAccessibilityElement(false)
            let name = NSTextField(labelWithString: entry.name)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let popup = makePopup(bundle: entry.bundle, name: entry.name,
                                  position: positions[entry.bundle], override: overrides[entry.bundle])
            return [icon, name, popup]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).width = 20
        grid.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: listContainer.topAnchor),
            grid.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: listContainer.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
        ])
        self.grid = grid
        view.window?.recalculateKeyViewLoop()
        if let first = rows.first?.last {
            view.window?.makeFirstResponder(first)
        }
    }

    private func makePopup(bundle: String, name: String, position: MenuBarSection?, override: MenuBarSection?) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let where_ = position.map(Self.title(of:)) ?? "not in the menu bar now".localized
        popup.addItem(withTitle: String(format: "By Position (%@)".localized, where_))
        popup.lastItem?.tag = Self.positionTag
        var sections: [MenuBarSection] = [.visible, .hidden]
        if Preferences.alwaysHiddenSectionEnabled || override == .alwaysHidden {
            sections.append(.alwaysHidden)
        }
        for section in sections {
            popup.addItem(withTitle: Self.title(of: section))
            popup.lastItem?.tag = section.rawValue
        }
        popup.selectItem(withTag: override?.rawValue ?? Self.positionTag)
        popup.identifier = NSUserInterfaceItemIdentifier(bundle)
        popup.target = self
        popup.action = #selector(sectionChosen(_:))
        // VoiceOver reads the app's name, then the chosen section.
        popup.setAccessibilityLabel(name)
        return popup
    }

    @objc private func sectionChosen(_ sender: NSPopUpButton) {
        guard let bundle = sender.identifier?.rawValue else { return }
        var overrides = Preferences.sectionOverrides
        overrides[bundle] = MenuBarSection(rawValue: sender.selectedTag())
        Preferences.sectionOverrides = overrides
    }

    private static func title(of section: MenuBarSection) -> String {
        switch section {
        case .visible: return "Shown".localized
        case .hidden: return "Hidden".localized
        case .alwaysHidden: return "Always Hidden".localized
        }
    }

    private static func displayName(of bundle: String) -> String {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundle
    }

    private static func icon(of bundle: String) -> NSImage {
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

// Keeps the list pinned to the top of its scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
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
        
        
        let arrowIsBoundary = MenuBarEngineFactory.usesArrowAsBoundary
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
        describeBoundary(arrowIsBoundary)
    }
    
    func alwayHideStatusBar() {
        lblAlwayHidden.isHidden = false
        arrowPointToAlwayHiddenImage.isHidden = false
        statusBarStackView.removeAllSubViews()
        let imageWidth: CGFloat = 16
        
        
        let arrowIsBoundary = MenuBarEngineFactory.usesArrowAsBoundary
        let names = Self.tutorialIconNames(alwaysHidden: true)
        // Index 7 is the boundary in both: the arrow, or the | separator.
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
        describeBoundary(arrowIsBoundary)
    }

    // The line under the picture says how to move icons for this engine.
    private func describeBoundary(_ arrowIsBoundary: Bool) {
        guard arrowIsBoundary else { return }
        let text = statusBarController?.supportsSectionAssignment ?? false
            ? "In your Mac's menu bar, hold ⌘ and drag icons to the left of the arrow to hide them, or use Menu Bar Items… below."
            : "In your Mac's menu bar, hold ⌘ and drag icons to the left of the arrow to hide them."
        var caption = text.localized
        if Preferences.alwaysHiddenSectionEnabled {
            caption += " " + "Icons to the left of the first | are always hidden.".localized
        }
        textFieldTitle.stringValue = caption
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
