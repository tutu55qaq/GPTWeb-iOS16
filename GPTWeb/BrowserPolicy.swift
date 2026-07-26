import Foundation

enum BrowserPolicy {
    static let homeURL = URL(string: "https://chatgpt.com/")!

    private static let firstPartyDomains = [
        "chatgpt.com",
        "openai.com",
        "oaistatic.com",
        "oaiusercontent.com"
    ]

    private static let identityDomains = [
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com"
    ]

    private static let verificationDomains = [
        "challenges.cloudflare.com",
        "arkoselabs.com",
        "arkoselabsclient.com"
    ]

    static func isFirstParty(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return isFirstPartyHost(host)
    }

    static func isFirstPartyHost(_ host: String) -> Bool {
        firstPartyDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func shouldOpenInside(_ destination: URL, from source: URL?) -> Bool {
        guard let scheme = destination.scheme?.lowercased(),
              scheme == "https",
              let destinationHost = destination.host?.lowercased() else {
            return false
        }

        if isFirstPartyHost(destinationHost) {
            return true
        }

        let sourceHost = source?.host?.lowercased()
        let sourceIsTrusted = sourceHost.map {
            isFirstPartyHost($0)
                || contains($0, in: identityDomains)
                || contains($0, in: verificationDomains)
        } ?? false

        if sourceIsTrusted && contains(destinationHost, in: identityDomains) {
            return true
        }

        if sourceIsTrusted && contains(destinationHost, in: verificationDomains) {
            return true
        }

        return false
    }

    static func canPersist(_ url: URL?) -> Bool {
        guard isFirstParty(url), let path = url?.path.lowercased() else {
            return false
        }
        return !path.hasPrefix("/auth") && !path.hasPrefix("/login")
    }

    private static func contains(_ host: String, in domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
