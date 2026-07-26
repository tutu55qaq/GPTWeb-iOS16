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
        return true
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

