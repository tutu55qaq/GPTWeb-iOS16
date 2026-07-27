import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [
            SFExtensionMessageKey: [
                "status": "ready",
                "scope": "chatgpt.com"
            ]
        ]
        context.completeRequest(
            returningItems: [response],
            completionHandler: nil
        )
    }
}
