import Cocoa
import Combine
import Foundation
import ServiceManagement
import SwiftUI

// Вбудований словник локалізації для 100% надійності без сторонніх файлів в Xcode
private let translations: [String: [String: String]] = [
    "en": [
        "Auto": "Auto",
        "Dock": "Dock",
        "Menu": "Menu",
        "Both": "Both",
        "Settings": "Settings",
        "Launch at login": "Launch at login",
        "Language": "Language",
        "Icon": "Icon",
        "Hide Menu Bar icon when empty": "Hide Menu Bar icon when empty",
        "No drives found": "No drives found",
        "Connect a USB drive, SD card, or mount a disk image to see it here.": "Connect a USB drive, SD card, or mount a disk image to see it here.",
        "Back": "Back",
        "Eject all volumes": "Eject all volumes",
        "Refresh list": "Refresh list",
        "Quit": "Quit",
        "Could not eject %1$@: %2$@": "Could not eject %1$@: %2$@",
        "Could not change launch at login: %@": "Could not change launch at login: %@",
        "Eject %@": "Eject %@",
        "Network volume": "Network volume",
        "External drive": "External drive",
        "Disk image or ejectable volume": "Disk image or ejectable volume"
    ],
    "uk": [
        "Auto": "Авто",
        "Dock": "Док",
        "Menu": "Меню",
        "Both": "Обидва",
        "Settings": "Налаштування",
        "Launch at login": "Старт із macOS",
        "Language": "Мова",
        "Icon": "Іконка",
        "Hide Menu Bar icon when empty": "Ховати Меню без дисків",
        "No drives found": "Диски не знайдені",
        "Connect a USB drive, SD card, or mount a disk image to see it here.": "Підключіть USB-накопичувач, SD-карту або змонтуйте образ диска, щоб він зʼявився тут.",
        "Back": "Назад",
        "Eject all volumes": "Відмонтувати всі носії",
        "Refresh list": "Оновити список",
        "Quit": "Вийти",
        "Could not eject %1$@: %2$@": "Не вдалося відмонтувати %1$@: %2$@",
        "Could not change launch at login: %@", "Не вдалося змінити автозапуск: %@",
        "Eject %@": "Відмонтувати %@",
        "Network volume": "Мережевий том",
        "External drive": "Зовнішній носій",
        "Disk image or ejectable volume": "Образ диска або ejectable том"
    ]
]

// Розумний та надійний глобальний хелпер для миттєвої локалізації
func localized(_ key: String) -> String {
    let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    let targetLang: String
    if lang == "system" {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        targetLang = preferred.hasPrefix("uk") ? "uk" : "en"
    } else {
        targetLang = lang
    }
    
    return translations[targetLang]?[key] ?? key
}

struct MountedVolume: Identifiable {
    let id: String
    let url: URL
    let name: String
    let kind: String
    let icon: NSImage
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case uk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return localized("Auto")
        case .en:
            return "EN"
        case .uk:
            return "UA"
        }
    }
}

enum AppIconDisplayMode: String, CaseIterable, Identifiable {
    case dock
    case menuBar
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dock:
            return localized("Dock")
        case .menuBar:
            return localized("Menu")
        case .both:
            return localized("Both")
        }
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
        refreshMountedVolumes()
        startRealTimeMonitoring()
    }

    deinit {
        notificationTasks.forEach { $0.cancel() }
    }

    func refreshMountedVolumes() {
        mountedVolumes = DiskEjector.mountedTargetVolumes()
        NotificationCenter.default.post(name: .volumeMonitorDidChange, object: nil)
    }

    func unmount(_ volume: MountedVolume) {
        errorMessage = nil
        unmountingVolumeIDs.insert(volume.id)

        Task {
            do {
                try await DiskEjector.unmount(volume)
                refreshMountedVolumes()
            } catch {
                let format = localized("Could not eject %1$@: %2$@")
                errorMessage = String(format: format, volume.name, error.localizedDescription)
            }
            unmountingVolumeIDs.remove(volume.id)
        }
    }

    func unmountAll() {
        for volume in mountedVolumes {
            unmount(volume)
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
                    self?.refreshMountedVolumes()
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
    // Підписуємо View на зміну мови, щоб воно миттєво перемальовувалося
    @AppStorage("appLanguage") private var appLanguage = "system"

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
        .frame(width: 350, height: 238)
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
                help: localized("Eject all volumes")
            ) {
                volumeMonitor.unmountAll()
            }
            .disabled(volumeMonitor.mountedVolumes.isEmpty)

            IconButton(
                systemName: "gearshape.fill",
                tint: .primary.opacity(0.78),
                help: localized("Settings")
            ) {
                NotificationCenter.default.post(name: .openUnmountySettings, object: nil)
            }

            IconButton(
                systemName: "arrow.clockwise",
                tint: .primary.opacity(0.78),
                help: localized("Refresh list")
            ) {
                volumeMonitor.refreshMountedVolumes()
            }

            IconButton(
                systemName: "power", 
                tint: .red, 
                help: localized("Quit")
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
                Text(localized("No drives found"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                Text(localized("Connect a USB drive, SD card, or mount a disk image to see it here."))
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
    @AppStorage("appIconDisplayMode") private var appIconDisplayModeRaw = AppIconDisplayMode.both.rawValue
    @AppStorage("hideMenuBarIconWhenEmpty") private var hideMenuBarIconWhenEmpty = false
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue
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
                .help(localized("Back"))

                Text(localized("Settings"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.bottom, 2)

            Toggle(isOn: launchAtLoginBinding) {
                Text(localized("Launch at login"))
            }
            .toggleStyle(.checkbox)

            // Рядок вибору мови програми
            HStack(spacing: 8) {
                Text(localized("Language"))
                    .foregroundStyle(.secondary)

                Picker(localized("Language"), selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.title).tag(lang.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack(spacing: 8) {
                Text(localized("Icon"))
                    .foregroundStyle(.secondary)

                Picker(localized("Icon"), selection: iconDisplayModeBinding) {
                    ForEach(AppIconDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            Toggle(isOn: hideMenuBarIconBinding) {
                Text(localized("Hide Menu Bar icon when empty"))
            }
            .toggleStyle(.checkbox)
            .disabled(appIconDisplayModeRaw == AppIconDisplayMode.menuBar.rawValue)
            .opacity(appIconDisplayModeRaw == AppIconDisplayMode.menuBar.rawValue ? 0.45 : 1)

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
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { isLaunchAtLoginEnabled },
            set: setLaunchAtLogin
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { appLanguageRaw },
            set: { newValue in
                appLanguageRaw = newValue
                // Надсилаємо сповіщення, щоб оновити інтерфейс головного вікна
                NotificationCenter.default.post(name: .appDisplaySettingsDidChange, object: nil)
            }
        )
    }

    private var iconDisplayModeBinding: Binding<String> {
        Binding(
            get: { appIconDisplayModeRaw },
            set: { newValue in
                appIconDisplayModeRaw = newValue
                NotificationCenter.default.post(name: .appDisplaySettingsDidChange, object: nil)
            }
        )
    }

    private var hideMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { hideMenuBarIconWhenEmpty },
            set: { newValue in
                hideMenuBarIconWhenEmpty = newValue
                NotificationCenter.default.post(name: .appDisplaySettingsDidChange, object: nil)
            }
        )
    }

    private func setLaunchAtLogin(_ isEnabled: Bool) {
        launchAtLoginError = nil

        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let format = localized("Could not change launch at login: %@", comment: "Error message when launch configuration fails")
            launchAtLoginError = String(format: format, error.localizedDescription)
        }
    }
}

private struct VolumeRow: View {
    @EnvironmentObject private var volumeMonitor: VolumeMonitor
    // Підписуємо рядки списку на зміну мови
    @AppStorage("appLanguage") private var appLanguage = "system"
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

            Button(action: { volumeMonitor.unmount(volume) }) {
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
            .help(String(format: localized("Eject %@"), volume.name))
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

    static func mountedTargetVolumes() -> [MountedVolume] {
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
                    kind = localized("Network volume")
                } else if isRemovable {
                    kind = localized("External drive")
                } else {
                    kind = localized("Disk image or ejectable volume")
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
