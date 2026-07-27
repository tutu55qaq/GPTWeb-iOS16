import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024,
            diskPath: "GPTWebURLCache"
        )

        WebSession.shared.prewarm()

        if let incomingURL = launchOptions?[.url] as? URL {
            IncomingDocumentRouter.shared.receive([incomingURL])
        }
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        IncomingDocumentRouter.shared.receive([url])
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class IncomingDocumentRouter {
    static let shared = IncomingDocumentRouter()

    private var receiver: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []
    private var recentlyReceived: [String: Date] = [:]

    private init() {}

    func register(receiver: @escaping ([URL]) -> Void) {
        self.receiver = receiver
        guard !pendingURLs.isEmpty else { return }

        let queuedURLs = pendingURLs
        pendingURLs.removeAll()
        receiver(queuedURLs)
    }

    @discardableResult
    func receive(_ urls: [URL]) -> Bool {
        let now = Date()
        recentlyReceived = recentlyReceived.filter {
            now.timeIntervalSince($0.value) < 3
        }

        let uniqueFileURLs = urls.filter { url in
            guard url.isFileURL else { return false }
            let key = url.standardizedFileURL.absoluteString
            guard recentlyReceived[key] == nil else { return false }
            recentlyReceived[key] = now
            return true
        }
        guard !uniqueFileURLs.isEmpty else { return false }

        if let receiver {
            receiver(uniqueFileURLs)
        } else {
            pendingURLs.append(contentsOf: uniqueFileURLs)
        }
        return true
    }
}

final class WebSession {
    static let shared = WebSession()

    let processPool = WKProcessPool()

    private var prewarmedWebView: WKWebView?

    private init() {}

    func prewarm() {
        guard prewarmedWebView == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        prewarmedWebView = webView

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.prewarmedWebView = nil
        }
    }
}
