import Cocoa
import Combine
import Foundation
import ServiceManagement
import SwiftUI

struct MountedVolume: Identifiable {
    let id: String
    let url: URL
    let name: String
    let kind: String
    let icon: NSImage
}

enum AppIconDisplayMode: String, CaseIterable, Identifiable {
    case dock
    case menuBar
    case both

    var id: String { rawValue }

    func title(locale: Locale) -> String {
        switch self {
        case .dock:
            return String(localized: "Dock", locale: locale, comment: "Display mode: Dock only")
        case .menuBar:
            return String(localized: "Menu", locale: locale, comment: "Display mode: Menu bar only")
        case .both:
            return String(localized: "Both", locale: locale, comment: "Display mode: Both Dock and Menu bar")
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case uk

    var id: String { rawValue }

    func title(locale: Locale) -> String {
        switch self {
        case .system:
            return String(localized: "System", locale: locale, comment: "Language option: System default")
        case .en:
            return "English"
        case .uk:
            return "Українська"
        }
    }

    var locale: Locale? {
        switch self {
        case .system:
            return nil
        case .en:
            return Locale(identifier: "en")
        case .uk:
            return Locale(identifier: "uk")
        }
    }

    static func applyLanguage(_ languageRaw: String) {
        if languageRaw == AppLanguage.system.rawValue {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([languageRaw], forKey: "AppleLanguages")
        }
    }
}

struct LocalizedViewWrapper<Content: View>: View {
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue
    let content: () -> Content

    var body: some View {
        let language = AppLanguage(rawValue: appLanguageRaw) ?? .system
        let locale = language.locale ?? .current
        
        content()
            .environment(\.locale, locale)
            .id(appLanguageRaw)
    }
}

extension Notification.Name {
    static let volumeMonitorDidChange = Notification.Name("volumeMonitorDidChange")
    static let appDisplaySettingsDidChange = Notification.Name("appDisplaySettingsDidChange")
    static let openUnmountySettings = Notification.Name("openUnmountySettings")
    static let showMainWindow = Notification.Name("showMainWindow")
}

@MainActor
final class VolumeMonitor: ObservableObject {
    @Published private(set) var mountedVolumes: [MountedVolume] = []
    @Published var unmountingVolumeIDs = Set<String>()
    @Published var errorMessage: String?

    private var notificationTasks: [Task<Void, Never>] = []

    init() {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let initialLocale = AppLanguage(rawValue: raw)?.locale ?? .current
        refreshMountedVolumes(locale: initialLocale)
        startRealTimeMonitoring()
    }

    deinit {
        notificationTasks.forEach { $0.cancel() }
    }

    func refreshMountedVolumes(locale: Locale = .current) {
        mountedVolumes = DiskEjector.mountedTargetVolumes(locale: locale)
        NotificationCenter.default.post(name: .volumeMonitorDidChange, object: nil)
    }

    func unmount(_ volume: MountedVolume, locale: Locale = .current) {
        errorMessage = nil
        unmountingVolumeIDs.insert(volume.id)

        Task {
            do {
                try await DiskEjector.unmount(volume)
                refreshMountedVolumes(locale: locale)
            } catch {
                let format = String(localized: "Could not eject %1$@: %2$@", locale: locale, comment: "Error message when unmounting fails")
                errorMessage = String(format: format, volume.name, error.localizedDescription)
            }
            unmountingVolumeIDs.remove(volume.id)
        }
    }

    func unmountAll(locale: Locale = .current) {
        for volume in mountedVolumes {
            unmount(volume, locale: locale)
        }
    }

    private func startRealTimeMonitoring() {
        guard notificationTasks.isEmpty else { return }

        let notificationNames: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
            NSWorkspace.didWakeNotification
        ]

        notificationTasks = notificationNames.map { name in
            Task { @MainActor [weak self] in
                let notifications = NSWorkspace.shared.notificationCenter.notifications(named: name)
                for await _ in notifications {
                    let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
                    let currentLocale = AppLanguage(rawValue: raw)?.locale ?? .current
                    self?.refreshMountedVolumes(locale: currentLocale)
                }
            }
        }
    }
}

struct ContentView: View {
    var body: some View {
        MenuBarContentView()
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var volumeMonitor: VolumeMonitor
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage = volumeMonitor.errorMessage {
                StatusMessage(text: errorMessage)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
            }

            if volumeMonitor.mountedVolumes.isEmpty {
                emptyState
            } else {
                volumeList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Unmounty")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            IconButton(
                systemName: "eject.circle.fill",
                tint: .primary.opacity(volumeMonitor.mountedVolumes.isEmpty ? 0.28 : 0.72),
                help: String(localized: "Eject all volumes", locale: locale, comment: "Tooltip for eject all button")
            ) {
                volumeMonitor.unmountAll(locale: locale)
            }
            .disabled(volumeMonitor.mountedVolumes.isEmpty)

            IconButton(
                systemName: "gearshape.fill",
                tint: .primary.opacity(0.78),
                help: String(localized: "Settings", locale: locale, comment: "Tooltip for settings button")
            ) {
                NotificationCenter.default.post(name: .openUnmountySettings, object: nil)
            }

            IconButton(
                systemName: "arrow.clockwise",
                tint: .primary.opacity(0.78),
                help: String(localized: "Refresh list", locale: locale, comment: "Tooltip for reload button")
            ) {
                volumeMonitor.refreshMountedVolumes(locale: locale)
            }

            IconButton(
                systemName: "power", 
                tint: .red, 
                help: String(localized: "Quit", locale: locale, comment: "Tooltip for quit button")
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 26)

            ZStack(alignment: .bottomLeading) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 43, weight: .semibold))
                    .foregroundStyle(.secondary)

                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor), .secondary)
                    .offset(x: -5, y: 3)
            }

            VStack(spacing: 6) {
                Text("No drives found", comment: "Empty state title")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                Text("Connect a USB drive, SD card, or mount a disk image to see it here.", comment: "Empty state description")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 260)
            }

            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var volumeList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(volumeMonitor.mountedVolumes) { volume in
                    VolumeRow(volume: volume)
                        .environmentObject(volumeMonitor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var volumeMonitor: VolumeMonitor
    @Environment(\.locale) private var locale

    @AppStorage("appIconDisplayMode") private var appIconDisplayModeRaw = AppIconDisplayMode.both.rawValue
    @AppStorage("hideMenuBarIconWhenEmpty") private var hideMenuBarIconWhenEmpty = false
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue
    
    @State private var isLaunchAtLoginEnabled = false
    @State private var launchAtLoginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: {
                    NotificationCenter.default.post(name: .showMainWindow, object: nil)
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Back", locale: locale, comment: "Tooltip to return to main view"))

                Text("Settings", comment: "Settings title")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.bottom, 2)

            Toggle(isOn: $isLaunchAtLoginEnabled) {
                Text("Launch at login", comment: "Option to start app with macOS")
            }
            .toggleStyle(.checkbox)
            .onChange(of: isLaunchAtLoginEnabled) { newValue in
                setLaunchAtLogin(newValue)
            }

            HStack(spacing: 8) {
                Text("Icon", comment: "Label for app icon display mode setting")
                    .foregroundStyle(.secondary)

                Picker(String(localized: "Icon", locale: locale, comment: "Accessibility label for icon options"), selection: $appIconDisplayModeRaw) {
                    ForEach(AppIconDisplayMode.allCases) { mode in
                        Text(mode.title(locale: locale)).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .onChange(of: appIconDisplayModeRaw) { _ in
                NotificationCenter.default.post(name: .appDisplaySettingsDidChange, object: nil)
            }

            Toggle(isOn: $hideMenuBarIconWhenEmpty) {
                Text("Hide Menu Bar icon when empty", comment: "Option to hide status item if no drives are connected")
            }
            .toggleStyle(.checkbox)
            // Кнопка активна ТІЛЬКИ у режимі "Обидва" (both), оскільки в інших режимах це або безглуздо (Dock),
            // або небезпечно (Menu bar — оскільки додаток повністю зникне)
            .disabled(appIconDisplayModeRaw != AppIconDisplayMode.both.rawValue)
            .opacity(appIconDisplayModeRaw != AppIconDisplayMode.both.rawValue ? 0.45 : 1)
            .onChange(of: hideMenuBarIconWhenEmpty) { _ in
                NotificationCenter.default.post(name: .appDisplaySettingsDidChange, object: nil)
            }

            HStack(spacing: 8) {
                Text("Language", comment: "Label for language setting")
                    .foregroundStyle(.secondary)

                Picker(String(localized: "Language", locale: locale, comment: "Accessibility label for language options"), selection: $appLanguageRaw) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title(locale: locale)).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .onChange(of: appLanguageRaw) { newValue in
                AppLanguage.applyLanguage(newValue)
                let selectedLocale = AppLanguage(rawValue: newValue)?.locale ?? .current
                volumeMonitor.refreshMountedVolumes(locale: selectedLocale)
                NotificationCenter.default.post(name: .appDisplaySettingsDidChange, object: nil)
            }

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.primary.opacity(0.84))
        .padding(18)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .onAppear {
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ isEnabled: Bool) {
        let currentStatus = SMAppService.mainApp.status == .enabled
        guard isEnabled != currentStatus else { return }

        launchAtLoginError = nil

        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let format = String(localized: "Could not change launch at login: %@", locale: locale, comment: "Error message when launch configuration fails")
            launchAtLoginError = String(format: format, error.localizedDescription)
            
            // Відкочуємо стан чекбокса назад асинхронно
            DispatchQueue.main.async {
                self.isLaunchAtLoginEnabled = currentStatus
            }
        }
    }
}

private struct VolumeRow: View {
    @EnvironmentObject private var volumeMonitor: VolumeMonitor
    @Environment(\.locale) private var locale
    let volume: MountedVolume

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: volume.icon)
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(volume.kind)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: { volumeMonitor.unmount(volume, locale: locale) }) {
                if volumeMonitor.unmountingVolumeIDs.contains(volume.id) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary.opacity(0.72))
            .disabled(volumeMonitor.unmountingVolumeIDs.contains(volume.id))
            .help(String(localized: "Eject \(volume.name)", locale: locale, comment: "Tooltip for individual eject button"))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct IconButton: View {
    let systemName: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct StatusMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.red.opacity(0.9))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum DiskEjector {
    private static let resourceKeys: [URLResourceKey] = [
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsLocalKey,
        .volumeLocalizedNameKey
    ]

    static func mountedTargetVolumes(locale: Locale = .current) -> [MountedVolume] {
        guard let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: .skipHiddenVolumes
        ) else {
            print("[DiskEjector] Не вдалося отримати список дисків.")
            return []
        }

        return mountedVolumes.compactMap { volumeURL in
            if volumeURL.path == "/" { return nil }

            do {
                let resourceValues = try volumeURL.resourceValues(forKeys: Set(resourceKeys))
                let isRemovable = resourceValues.volumeIsRemovable ?? false
                let isEjectable = resourceValues.volumeIsEjectable ?? false
                let isLocal = resourceValues.volumeIsLocal ?? true

                guard isRemovable || isEjectable || !isLocal else { return nil }

                let volumeName = resourceValues.volumeLocalizedName ?? volumeURL.lastPathComponent
                let kind: String

                if !isLocal {
                    kind = String(localized: "Network volume", locale: locale, comment: "Type of disk volume")
                } else if isRemovable {
                    kind = String(localized: "External drive", locale: locale, comment: "Type of disk volume")
                } else {
                    kind = String(localized: "Disk image or ejectable volume", locale: locale, comment: "Type of disk volume")
                }

                return MountedVolume(
                    id: volumeURL.path,
                    url: volumeURL,
                    name: volumeName,
                    kind: kind,
                    icon: NSWorkspace.shared.icon(forFile: volumeURL.path)
                )
            } catch {
                print("[DiskEjector] Помилка під час перевірки диска \(volumeURL.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
    }

    static func unmount(_ volume: MountedVolume) async throws {
        let url = volume.url
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
    }
}
