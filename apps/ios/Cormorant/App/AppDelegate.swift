import UIKit

/// Only here for CloudKit's silent pushes ("something changed in the cloud"), which iOS delivers to
/// the app delegate: the app syncs, in the background if that's where it is.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set once the browser has launched and can sync. Nil before that, and in builds that can't.
    var syncFromPush: (() async -> Void)?

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let syncFromPush else { return .noData }
        await syncFromPush()
        return .newData
    }
}
