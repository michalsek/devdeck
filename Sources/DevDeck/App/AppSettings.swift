import Foundation
import ServiceManagement

/// App-level settings that aren't peon-ping's.
@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var lastError: String?
    @Published var menuBarIcon: MenuBarIcon {
        didSet { UserDefaults.standard.set(menuBarIcon.rawValue, forKey: "menuBarIcon") }
    }
    /// Your hold on a device ends after this many minutes without input on the Mac; 0 never.
    @Published var holdReleaseMinutes: Int {
        didSet { UserDefaults.standard.set(holdReleaseMinutes, forKey: "holdReleaseMinutes") }
    }
    /// Post a notification when an agent's call has to wait.
    @Published var notifyWaits: Bool {
        didSet { UserDefaults.standard.set(notifyWaits, forKey: "notifyWaits") }
    }
    /// Show who drives a simulator or emulator on the device, through the companion app.
    @Published var deviceMarkers: Bool {
        didSet { UserDefaults.standard.set(deviceMarkers, forKey: "deviceMarkers") }
    }
    /// Where agents may test Android apps.
    @Published var androidTesting: AndroidTesting {
        didSet { UserDefaults.standard.set(androidTesting.rawValue, forKey: "androidTesting") }
    }

    enum AndroidTesting: String, CaseIterable, Identifiable {
        case anyDevice, phonesOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .anyDevice: "Emulators and phones"
            case .phonesOnly: "Only physical phones"
            }
        }
    }

    init() {
        menuBarIcon = UserDefaults.standard.string(forKey: "menuBarIcon").flatMap(MenuBarIcon.init) ?? .dashboard
        deviceMarkers = UserDefaults.standard.object(forKey: "deviceMarkers") as? Bool ?? true
        holdReleaseMinutes = UserDefaults.standard.object(forKey: "holdReleaseMinutes") as? Int ?? 10
        notifyWaits = UserDefaults.standard.object(forKey: "notifyWaits") as? Bool ?? true
        androidTesting = UserDefaults.standard.string(forKey: "androidTesting").flatMap(AndroidTesting.init) ?? .anyDevice
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = "Open at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
