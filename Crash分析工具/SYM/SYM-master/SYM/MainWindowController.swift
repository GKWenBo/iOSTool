// The MIT License (MIT)
//
// Copyright (c) 2017 - 2018 zqqf16
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Cocoa

extension NSImage {
    static let alert: NSImage = #imageLiteral(resourceName: "alert")
    static let symbol: NSImage = #imageLiteral(resourceName: "symbol")
}

class MainWindowController: NSWindowController {
    // Toolbar buttons
    @IBOutlet weak var symButton: NSButton!
    //@IBOutlet weak var deviceButton: NSButton!
    //@IBOutlet weak var statusBar: StatusBar!
    @IBOutlet weak var downloadButton: DownloadButton!
    @IBOutlet weak var dsymButton: NSPopUpButton!
    @IBOutlet weak var deviceItem: NSToolbarItem!
    
    @IBOutlet weak var indicator: NSProgressIndicator!

    @IBOutlet weak var dsymMenu: NSMenu!
    @IBOutlet weak var dsymMenuItemName: NSMenuItem!
    @IBOutlet weak var dsymMenuItemReveal: NSMenuItem!
    @IBOutlet weak var dsymMenuItemDownload: NSMenuItem!
    
    
    var isSymbolicating: Bool = false {
        didSet {
            DispatchQueue.main.async {
                if (self.isSymbolicating) {
                    self.indicator.startAnimation(nil)
                    self.indicator.isHidden = false
                } else {
                    self.indicator.stopAnimation(nil)
                    self.indicator.isHidden = true
                }
            }
        }
    }
    
    // Dsym
    private var monitor = DsymFileMonitor()
    private var downloader = DsymDownloader()

    private var dsymFile: DsymFile? {
        didSet {
            DispatchQueue.main.async {
                if self.dsymFile != nil {
                    self.dsymMenuItemName.image = .symbol
                    self.dsymButton.title = self.dsymFile!.name
                    self.dsymMenuItemReveal.isEnabled = true
                } else {
                    self.dsymMenuItemName.image = .alert
                    self.dsymButton.title = "dSYM file not found"
                    self.dsymMenuItemReveal.isEnabled = false
                }
            }
        }
    }

    // Crash
    var crashContentViewController: ContentViewController! {
        if let vc = self.contentViewController as? ContentViewController {
            return vc
        }
        return nil
    }
    
    var crashDocument: CrashDocument? {
        return self.document as? CrashDocument
    }
    
    var crashInfo: CrashInfo? {
        return self.crashDocument?.crashInfo
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        self.windowFrameAutosaveName = "MainWindow"
        self.deviceItem.isEnabled = SYMDeviceMonitor.shared().deviceConnected

        NotificationCenter.default.addObserver(self, selector: #selector(updateDeviceButton(_:)), name: NSNotification.Name.SYMDeviceMonitor, object: nil)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder:coder)
        self.monitor.delegate = self
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        self.monitor.stop()
        if let document = self.crashDocument {
            document.notificationCenter.removeObserver(self)
        }
    }
    
    override var document: AnyObject? {
        didSet {
            self.dsymFile = nil;
            guard let document = document as? CrashDocument else {
                return
            }
            self.crashContentViewController.document = document
            document.notificationCenter.addObserver(self, selector: #selector(updateCrashInfo(_:)), name: .crashInfoUpdated, object: nil)
            document.notificationCenter.addObserver(self, selector: #selector(crashDidSymbolicated(_:)), name: .crashSymbolicated, object: nil)
            self.updateCrashInfo(nil)
        }
    }
    
    // MARK: Notifications
    @objc func updateCrashInfo(_ notification: Notification?) {
        self.dsymFile = nil
        self.monitor.update(uuid: self.crashInfo?.uuid, bundleID: self.crashInfo?.bundleID)
    }
    
    @objc func updateDeviceButton(_ notification: Notification) {
        self.deviceItem.isEnabled = SYMDeviceMonitor.shared().deviceConnected
    }
    
    @objc func crashDidSymbolicated(_ notification: Notification) {
        self.isSymbolicating = false
    }

    // MARK: - Symbolicate
    func autoSymbolicate() {
        if NSUserDefaultsController.shared.defaults.bool(forKey: "autoSymbolicate") {
            DispatchQueue.main.async {
                self.symbolicate(nil)
            }
        }
    }
    
    // MARK: IBActions
    @IBAction func symbolicate(_ sender: AnyObject?) {
        let content = self.crashDocument?.textStorage.string ?? ""
        if content.strip().isEmpty {
            return
        }
        
        self.isSymbolicating = true
        self.crashDocument?.symbolicate(withDsymPath: self.dsymFile?.binaryPath)
    }
    
    @IBAction func chooseDsymFile(_ sender: Any) {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.beginSheetModal(for: self.window!) { [weak openPanel] (result) in
            guard result == .OK, let url = openPanel?.url else {
                return
            }
            
            let path = url.path
            let name = url.lastPathComponent
            let uuid = self.crashInfo?.uuid ?? ""
            self.dsymFile = DsymFile(name: name, path: path, binaryPath: path, uuids: [uuid])
        }
    }
    
    @IBAction func showInFinder(_ sender: Any) {
        guard let dsymFile = self.dsymFile else {
            return
        }
        
        let storyboard = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: nil)
        let vc = storyboard.instantiateController(withIdentifier: "DsymInfoViewController") as! DsymInfoViewController
        vc.dsymFile = dsymFile
        
        self.contentViewController?.presentAsSheet(vc)
    }
    
    @IBAction func downloadDsym(_ sender: Any) {
        guard let doc = self.crashDocument, let crashInfo = doc.crashInfo else {
            return
        }
        
        DsymDownloader.shared.download(crashInfo: crashInfo, fileURL: doc.fileURL)
    }
}

// MARK: - DsymFileMonitorDelegate
extension MainWindowController: DsymFileMonitorDelegate {
    func dsymFileMonitor(_ monitor: DsymFileMonitor, didFindDsymFile dsymFile: DsymFile) {
        let firstTime = (self.dsymFile == nil)
        self.dsymFile = dsymFile
        if firstTime {
            self.autoSymbolicate()
        }
    }
}

// MARK: - NSMenuDelegate
extension MainWindowController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu == self.dsymMenu {
            self.dsymMenuItemDownload.isEnabled = self.crashInfo != nil && DsymDownloader.shared.canDownload()
            self.dsymMenuItemReveal.isEnabled = self.dsymFile != nil
        }
    }
}

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        return item.isEnabled
    }
}
