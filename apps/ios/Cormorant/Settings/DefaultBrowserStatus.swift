import Observation
import OSLog
import UIKit

/// Whether Cormorant is the system's default browser.
///
/// `UIApplication.isDefault(_:)` answers about four times a year, so the last answer is kept in the
/// app-group defaults and the system is asked only when that answer is missing or a quarter old, or
/// when the user comes back from Default Apps. A web URL handed over by another app is free proof:
/// iOS sends those only to the default browser.
@MainActor
@Observable
final class DefaultBrowserStatus {
    struct Answer: Codable, Equatable {
        var isDefault: Bool
        var date: Date
    }

    private enum Key {
        static let answer = "defaultBrowserAnswer"
        static let retryDate = "defaultBrowserRetryDate"
    }

    /// Four answers a year: one a quarter keeps a stale answer from lingering without using them up.
    private static let staleAfter: TimeInterval = 91 * 24 * 60 * 60

    /// The last known answer; nil until the system has answered or a web URL has arrived, and again
    /// after a visit to Default Apps that the system wouldn't answer for.
    private(set) var answer: Answer? {
        didSet { if isLive { AppGroupStorage.save(answer, key: Key.answer) } }
    }

    /// The system is rate-limiting until this date.
    private(set) var retryDate: Date? {
        didSet { if isLive { AppGroupStorage.save(retryDate, key: Key.retryDate) } }
    }

    /// False for UI tests: nothing is saved and the system is never asked, so runs don't use up its
    /// answers or depend on earlier ones.
    @ObservationIgnored private let isLive: Bool

    /// Default Apps was opened from Settings; ask again when the app is back in front.
    @ObservationIgnored private var checksOnReturn = false

    init(isLive: Bool = true) {
        self.isLive = isLive
        guard isLive else { return }
        answer = AppGroupStorage.load(Answer.self, key: Key.answer)
        retryDate = AppGroupStorage.load(Date.self, key: Key.retryDate)
    }

    /// Asks the system if the last answer is missing or a quarter old.
    func checkIfStale() {
        guard answer.map({ Date.now.timeIntervalSince($0.date) > Self.staleAfter }) ?? true else { return }
        check()
    }

    func openDefaultAppsSettings() {
        guard let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) else { return }
        Task {
            if await UIApplication.shared.open(url) { checksOnReturn = true }
        }
    }

    func didBecomeActive() {
        guard checksOnReturn else { return }
        checksOnReturn = false
        // The user may have changed it; an answer the system won't refresh can't be shown as current.
        if !check() { answer = nil }
    }

    /// Another app handed Cormorant an http(s) URL, which iOS only does for the default browser.
    func didReceiveWebURL() {
        answer = Answer(isDefault: true, date: .now)
    }

    /// Asks the system. False if it couldn't answer.
    @discardableResult
    private func check() -> Bool {
        guard isLive else { return false }
        if let retryDate, retryDate > .now { return false }
        do {
            answer = Answer(isDefault: try UIApplication.shared.isDefault(.webBrowser), date: .now)
            retryDate = nil
            return true
        } catch let error as UIApplication.CategoryDefaultError where error.code == .rateLimited {
            retryDate = error.userInfo[UIApplication.CategoryDefaultError.retryAvailableDateErrorKey] as? Date
            Logger.app.notice("Default-browser check rate-limited until \(self.retryDate?.description ?? "unknown", privacy: .public)")
        } catch {
            Logger.app.error("Default-browser check failed: \(error, privacy: .public)")
        }
        return false
    }
}
