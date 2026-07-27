import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private weak var browserController: WebViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let browserController = WebViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browserController
        window.tintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.42, green: 0.88, blue: 0.73, alpha: 1)
                : UIColor(red: 0.04, green: 0.55, blue: 0.43, alpha: 1)
        }
        window.makeKeyAndVisible()

        self.browserController = browserController
        self.window = window

        IncomingDocumentRouter.shared.register { [weak browserController] urls in
            browserController?.receiveDocuments(urls)
        }

        let incomingURLs = connectionOptions.urlContexts.map(\.url)
        if !incomingURLs.isEmpty {
            IncomingDocumentRouter.shared.receive(Array(incomingURLs))
        }
    }

    func scene(
        _ scene: UIScene,
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) {
        IncomingDocumentRouter.shared.receive(URLContexts.map(\.url))
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        browserController?.refreshIfNeeded()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        browserController?.prepareForBackground()
    }
}
