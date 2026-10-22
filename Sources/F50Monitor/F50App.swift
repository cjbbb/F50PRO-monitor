import AppKit
import F50Core
import SwiftUI
import Combine

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var fetcher: F50Fetcher!
    private var initialSetupWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let smsNotificationManager = SMSNotificationManager()
    private let menuBarSpeedView = MenuBarSpeedView(frame: .zero)
    private var menuBarIcon: NSImage?
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Menu bar only app, no dock icon
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        fetcher = F50Fetcher()
        
        // 1. Setup Popover
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        
        let hostingController = NSHostingController(
            rootView: F50PopoverView(fetcher: fetcher)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        // Resolve the initial SwiftUI layout before the first click opens the popover.
        DispatchQueue.main.async { [weak hostingController] in
            guard let hostingController else { return }
            _ = hostingController.view.fittingSize
            hostingController.view.layoutSubtreeIfNeeded()
        }

        
        // 2. Setup a compact menu bar item with stable-width digits.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.alignment = .center
            let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.image = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right",
                accessibilityDescription: "F50 Monitor"
            )?.withSymbolConfiguration(symbolConfiguration)
            menuBarIcon = button.image
            menuBarSpeedView.isHidden = true
            button.addSubview(menuBarSpeedView)
            button.imagePosition = .imageLeading
            button.title = ""
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        if F50Configuration.needsInitialSetup {
            showInitialSetup()
        }

        // 3. Observe Status & Settings Changes to Update Menu Bar Text
        Publishers.CombineLatest(fetcher.$status, fetcher.$displayMode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, mode in
                Task<Void, Never> { @MainActor in
                    guard let self else { return }
                    self.updateMenuBarText(status: status, mode: mode)
                }
            }
            .store(in: &cancellables)

        fetcher.$status
            .compactMap { status in
                status.isOnline ? status.smsUnreadCount : nil
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unreadCount in
                Task<Void, Never> { @MainActor in
                    guard let self else { return }
                    self.smsNotificationManager.updateUnreadCount(unreadCount)
                }
            }
            .store(in: &cancellables)

        smsNotificationManager.requestAuthorizationIfNeeded()
    }

    private func showInitialSetup() {
        let controller = NSHostingController(rootView: InitialSetupView(fetcher: fetcher) { [weak self] in
            self?.initialSetupWindow?.close()
            self?.initialSetupWindow = nil
        })
        let window = NSWindow(contentViewController: controller)
        window.title = "F50 Monitor"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        initialSetupWindow = window
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        fetcher.fetchData()
    }

    private func compactMenuBarValue(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "")
    }
    
    private func updateMenuBarText(status: F50Status, mode: MenuBarDisplayMode) {
        guard let button = statusItem.button else { return }
        statusItem.length = NSStatusItem.variableLength
        menuBarSpeedView.isHidden = true
        button.image = menuBarIcon
        button.setAccessibilityLabel(nil)

        guard status.isOnline else {
            if mode == .iconOnly {
                button.title = ""
            } else {
                button.title = "离线"
            }
            button.toolTip = "F50 Monitor (未连接后台)"
            return
        }

        switch mode {
        case .iconOnly:
            button.title = ""
            button.toolTip = "F50 Monitor (\(status.networkType) · \(status.carrier))\n下载: \(F50Status.formatSpeed(status.dlSpeed))  上传: \(F50Status.formatSpeed(status.ulSpeed))"

        case .dailyUsage:
            button.title = compactMenuBarValue(F50Status.formatBytes(status.dailyTotal))
            button.toolTip = "F50 Monitor: 当日已用流量"

        case .speeds:
            let upload = F50Status.formatSpeed(status.ulSpeed)
            let download = F50Status.formatSpeed(status.dlSpeed)
            let width = menuBarSpeedView.update(upload: upload, download: download)
            button.title = ""
            button.image = nil
            statusItem.length = width + 12
            menuBarSpeedView.frame = NSRect(
                x: 6, y: (button.bounds.height - 22) / 2, width: width, height: 22
            )
            menuBarSpeedView.autoresizingMask = [.minYMargin, .maxYMargin]
            menuBarSpeedView.isHidden = false
            button.toolTip = "F50 Monitor\n上传（红）: \(upload)\n下载（蓝）: \(download)"
            button.setAccessibilityLabel("F50 Monitor，上传 \(upload)，下载 \(download)")

        case .cpuMem:
            if status.cpuUsage > 0 || status.memUsage > 0 {
                button.title = String(format: "CPU%.0f%% 内存%.0f%%", status.cpuUsage, status.memUsage)
            } else {
                button.title = "↓\(compactMenuBarValue(F50Status.formatSpeed(status.dlSpeed)))"
            }
            button.toolTip = "F50 Monitor: 硬件负载"

        case .temperature:
            if status.temperature > 0 {
                button.title = String(format: "%.1f℃", status.temperature)
            } else {
                button.title = status.networkType
            }
            button.toolTip = "F50 Monitor: 芯片温度"

        case .devices:
            button.title = "Wi-Fi \(status.connectedDevices)台"
            button.toolTip = "F50 Monitor: Wi-Fi 连接设备数 (\(status.connectedDevices) 台)"

        case .traffic:
            let packageUsed = status.monthlyTotal
            if status.trafficLimit > 0 {
                button.title = "\(compactMenuBarValue(F50Status.formatBytes(packageUsed)))/\(compactMenuBarValue(F50Status.formatBytes(status.trafficLimit)))"
            } else {
                button.title = "已用\(compactMenuBarValue(F50Status.formatBytes(packageUsed)))"
            }
            button.toolTip = "F50 Monitor: 套餐流量 (已用: \(F50Status.formatBytes(packageUsed)) / 总量: \(status.trafficLimit > 0 ? F50Status.formatBytes(status.trafficLimit) : "不限"))"
        }
    }
}
