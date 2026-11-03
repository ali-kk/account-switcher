import AppKit
import SwiftUI
import UserNotifications

@main
struct ClaudeAccountBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Task { await Snapshot.write(model: model, to: CommandLine.arguments[i + 1]); exit(0) }
            return
        }
        Notifier.setUp(delegate: self)
        model.start()
    }

    // The "Switch" button on a limit notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == Notifier.switchAction,
              let target = response.notification.request.content.userInfo["target"] as? String else { return }
        await model.switchTo(target)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let usage = model.active?.usage
        if usage?.isLimited == true {
            Image(systemName: "exclamationmark.circle.fill")
        } else if let pct = usage?.five_hour?.utilization {
            Image(systemName: "person.2.circle")
            Text("\(Int(pct))%")
        } else {
            Image(systemName: "person.2.circle")
        }
    }
}
