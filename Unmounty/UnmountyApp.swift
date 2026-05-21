//
//  UnmountyApp.swift
//  Unmounty
//
//  Created by Andriy Kupyna on 20.05.2026.
//

import AppKit
import SwiftUI

@main
struct UnmountyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let volumeMonitor = VolumeMonitor()
    private var statusItem: NSStatusItem?
    private var observationTasks: [Task<Void, Never>] = []
    private let popover = NSPopover()
    private let settingsPopover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = makeAppIconImage(size: 512)
        configurePopover()
        configureSettingsPopover()
        configureStatusItem()
        startObservationTasks()
        
        // Запобігаємо рекурсії макетування, запускаючи оновлення на наступному циклі
        DispatchQueue.main.async { [weak self] in
            self?.updatePresentation()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.isVisible = true

        if let button = item.button {
            button.image = makeAppIconImage(size: 18)
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Unmounty"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        statusItem = item
    }

    private func makeAppIconImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        let outerInset = size * 0.08
        let outerRect = NSRect(x: outerInset, y: outerInset, width: size - outerInset * 2, height: size - outerInset * 2)
        NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.08, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: outerRect).fill()

        let innerDiameter = size * 0.38
        let innerRect = NSRect(
            x: (size - innerDiameter) / 2,
            y: (size - innerDiameter) / 2,
            width: innerDiameter,
            height: innerDiameter
        )
        NSColor(calibratedRed: 0.0, green: 0.36, blue: 1.0, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: innerRect).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func startObservationTasks() {
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()

        // 1. Спостереження за змінами відображення інтерфейсу (виконуємо асинхронно)
        let interfaceNotifications: [Notification.Name] = [.appDisplaySettingsDidChange, .volumeMonitorDidChange]
        for name in interfaceNotifications {
            let task = Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    DispatchQueue.main.async {
                        self?.updatePresentation()
                    }
                }
            }
            observationTasks.append(task)
        }

        // 2. Спостереження за відкриттям налаштувань
        let settingsTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .openUnmountySettings) {
                self?.toggleSettingsPopover()
            }
        }
        observationTasks.append(settingsTask)

        // 3. Спостереження за кнопкою "Назад" з вікна налаштувань
        let backTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .showMainWindow) {
                self?.showMainWindow()
            }
        }
        observationTasks.append(backTask)

        // 4. Спостереження за переходом у режим сну
        let sleepTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification)
            for await _ in notifications {
                print("[AppDelegate] Mac переходить у сон. Автоматично відмонтовуємо диски...")
                await self?.ejectAllVolumesBeforeSleep()
            }
        }
        observationTasks.append(sleepTask)
    }

    private func ejectAllVolumesBeforeSleep() async {
        let volumes = DiskEjector.mountedTargetVolumes()
        for volume in volumes {
            do {
                print("[AppDelegate] Знайдено диск для вилучення: \(volume.name)")
                try await DiskEjector.unmount(volume)
                print("[AppDelegate] Успішно відмонтовано: \(volume.name)")
            } catch {
                print("[AppDelegate] Помилка вилучення \(volume.name): \(error.localizedDescription)")
            }
        }
    }

    private func showMainWindow() {
        guard let button = statusItem?.button else { return }
        settingsPopover.performClose(button)
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let currentLocale = AppLanguage(rawValue: raw)?.locale ?? .current
        volumeMonitor.refreshMountedVolumes(locale: currentLocale)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updatePresentation() {
        let mode = AppIconDisplayMode(rawValue: UserDefaults.standard.string(forKey: "appIconDisplayMode") ?? "") ?? .both
        let hideMenuBarIconWhenEmpty = UserDefaults.standard.bool(forKey: "hideMenuBarIconWhenEmpty")
        let hasMountedVolumes = !volumeMonitor.mountedVolumes.isEmpty

        switch mode {
        case .dock, .both:
            NSApplication.shared.setActivationPolicy(.regular)
        case .menuBar:
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        let usesMenuBar = mode == .menuBar || mode == .both
        let shouldHideForEmptyState = hideMenuBarIconWhenEmpty && !hasMountedVolumes && mode != .menuBar
        statusItem?.isVisible = usesMenuBar && !shouldHideForEmptyState

        // Оновлюємо динамічний розмір вікна при будь-якій зміні
        updatePopoverSize()
    }

    private func updatePopoverSize() {
        let width: CGFloat = 350
        let height: CGFloat
        
        if volumeMonitor.mountedVolumes.isEmpty {
            height = 238
        } else {
            let errorHeight: CGFloat = volumeMonitor.errorMessage != nil ? 32 : 0
            
            // Розрахунок: Шапка + Паддінги списку + кількість дисків * висоту рядка
            let rowHeight: CGFloat = 52
            let listPadding: CGFloat = 26
            let headerHeight: CGFloat = 46
            
            let calculatedHeight = headerHeight + errorHeight + listPadding + CGFloat(volumeMonitor.mountedVolumes.count) * rowHeight
            // Максимальне обмеження висоти у 450pt, далі увімкнеться ScrollView
            height = min(calculatedHeight, 450)
        }
        
        popover.contentSize = NSSize(width: width, height: height)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: 238)
        popover.contentViewController = NSHostingController(
            rootView: LocalizedViewWrapper {
                MenuBarContentView()
                    .environmentObject(self.volumeMonitor)
            }
        )
    }

    private func configureSettingsPopover() {
        settingsPopover.behavior = .transient
        settingsPopover.animates = true
        settingsPopover.contentSize = NSSize(width: 320, height: 215)
        settingsPopover.contentViewController = NSHostingController(
            rootView: LocalizedViewWrapper {
                SettingsView()
                    .environmentObject(self.volumeMonitor)
            }
        )
    }

    private func toggleSettingsPopover() {
        guard let button = statusItem?.button else { return }

        if settingsPopover.isShown {
            settingsPopover.performClose(button)
        } else {
            popover.performClose(button)
            settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            settingsPopover.performClose(sender)
            let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
            let currentLocale = AppLanguage(rawValue: raw)?.locale ?? .current
            volumeMonitor.refreshMountedVolumes(locale: currentLocale)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
