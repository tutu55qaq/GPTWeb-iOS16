import SafariServices
import UIKit
import UniformTypeIdentifiers
import WebKit

final class WebViewController: UIViewController {
    private struct PreparedIncomingDocument {
        let sourceURL: URL
        let filename: String
        let mimeType: String
        let base64Chunks: [String]
    }

    private lazy var webView: WKWebView = makeWebView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let errorView = LoadingErrorView()
    private let connectivityMonitor = ConnectivityMonitor()

    private var observations: [NSKeyValueObservation] = []
    private var isConnected = true
    private var lastLoadFailed = false
    private var recoveryAttempts: [Date] = []
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private var pendingDocumentURLs: [URL] = []
    private var shouldPresentDocumentNotice = false
    private var pendingDocumentErrorMessage: String?
    private var isAutomaticallyAttachingDocuments = false
    private var automaticAttachmentAttemptCount = 0
    private var automaticScrollRepairWorkItem: DispatchWorkItem?
    private var sidebarGestureDidTrigger = false
    private weak var sidebarOpenGesture: UIScreenEdgePanGestureRecognizer?
    private weak var sidebarCloseGesture: UIPanGestureRecognizer?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        configureNativeSidebarGestures()
        configureObservers()
        configureConnectivity()
        removeExpiredIncomingDocuments()
        loadInitialPage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        attemptAutomaticDocumentAttachment()
        presentIncomingDocumentNoticeIfNeeded()
        presentPendingDocumentErrorIfNeeded()
    }

    deinit {
        automaticScrollRepairWorkItem?.cancel()
        observations.forEach { $0.invalidate() }
        connectivityMonitor.cancel()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        view.backgroundColor = .systemBackground
        webView.backgroundColor = .systemBackground
    }

    func refreshIfNeeded() {
        guard isViewLoaded else { return }
        if webView.url == nil {
            loadInitialPage()
        } else if lastLoadFailed && isConnected {
            reloadCurrentPage()
        } else {
            attemptAutomaticDocumentAttachment()
        }
    }

    func prepareForBackground() {
        guard isViewLoaded else { return }
        webView.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(media){ media.pause(); });",
            completionHandler: nil
        )
    }

    func receiveDocuments(_ sourceURLs: [URL]) {
        let sources = sourceURLs
            .filter(\.isFileURL)
            .map { sourceURL in
                (
                    url: sourceURL,
                    hasSecurityScope:
                        sourceURL.startAccessingSecurityScopedResource()
                )
            }
        guard !sources.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                for source in sources where source.hasSecurityScope {
                    source.url.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }

            var cachedURLs: [URL] = []
            var failures: [String] = []

            for source in sources {
                do {
                    cachedURLs.append(try self.cacheIncomingDocument(
                        source.url,
                        preferredFilename: source.url.lastPathComponent
                    ))
                } catch {
                    failures.append(source.url.lastPathComponent)
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.finishReceivingDocuments(
                    cachedURLs,
                    failedNames: failures
                )
            }
        }
    }

    private func cacheIncomingDocument(
        _ sourceURL: URL,
        preferredFilename: String
    ) throws -> URL {
        let fileManager = FileManager.default

        let rootDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("IncomingDocuments", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let rawFilename = preferredFilename.isEmpty
            ? "document"
            : preferredFilename
        let safeFilename = rawFilename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let destination = rootDirectory.appendingPathComponent(safeFilename)

        do {
            try fileManager.copyItem(
                at: sourceURL,
                to: destination
            )
            return destination
        } catch {
            // A copied Inbox file succeeds above. Keep coordinated reading as
            // a fallback for providers that still return a security-scoped URL.
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: Error?
        var didCopy = false
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [.withoutChanges],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let values = try coordinatedURL.resourceValues(
                    forKeys: [.isDirectoryKey]
                )
                guard values.isDirectory != true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                try fileManager.copyItem(
                    at: coordinatedURL,
                    to: destination
                )
                didCopy = true
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            try? fileManager.removeItem(at: rootDirectory)
            throw coordinationError
        }
        if let copyError {
            try? fileManager.removeItem(at: rootDirectory)
            throw copyError
        }
        guard didCopy else {
            try? fileManager.removeItem(at: rootDirectory)
            throw CocoaError(.fileReadUnknown)
        }
        return destination
    }

    private func finishReceivingDocuments(
        _ cachedURLs: [URL],
        failedNames: [String]
    ) {
        if !failedNames.isEmpty {
            pendingDocumentErrorMessage =
                "无法读取：\(failedNames.joined(separator: "、"))"
        }

        guard !cachedURLs.isEmpty else {
            presentPendingDocumentErrorIfNeeded()
            return
        }

        pendingDocumentURLs.append(contentsOf: cachedURLs)
        automaticAttachmentAttemptCount = 0
        shouldPresentDocumentNotice = false
        attemptAutomaticDocumentAttachment()
        presentPendingDocumentErrorIfNeeded()
    }

    private func removeExpiredIncomingDocuments() {
        let fileManager = FileManager.default
        guard let cachesDirectory = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return
        }

        let rootDirectory = cachesDirectory.appendingPathComponent(
            "IncomingDocuments",
            isDirectory: true
        )
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let expirationDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for directory in directories {
            let values = try? directory.resourceValues(
                forKeys: [.contentModificationDateKey]
            )
            guard let modified = values?.contentModificationDate,
                  modified < expirationDate else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func attemptAutomaticDocumentAttachment() {
        guard !pendingDocumentURLs.isEmpty,
              !isAutomaticallyAttachingDocuments,
              isViewLoaded,
              view.window != nil,
              !webView.isLoading,
              isChatGPTPage(webView.url) else {
            return
        }

        let sourceURLs = pendingDocumentURLs
        let totalSize = sourceURLs.reduce(Int64(0)) { partialResult, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return partialResult + Int64(values?.fileSize ?? 0)
        }
        guard totalSize > 0,
              totalSize <= Self.maximumAutomaticAttachmentBytes else {
            useManualAttachmentFallback()
            return
        }

        isAutomaticallyAttachingDocuments = true
        webView.evaluateJavaScript(Self.uploadInputAvailabilityScript) {
            [weak self] value, error in
            guard let self else { return }
            guard error == nil, (value as? Bool) == true else {
                self.isAutomaticallyAttachingDocuments = false
                self.scheduleAutomaticAttachmentRetry()
                return
            }
            self.prepareIncomingDocuments(
                sourceURLs,
                totalSize: totalSize
            )
        }
    }

    private func prepareIncomingDocuments(
        _ sourceURLs: [URL],
        totalSize: Int64
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let payloads = try sourceURLs.map { sourceURL in
                    let data = try Data(
                        contentsOf: sourceURL,
                        options: [.mappedIfSafe]
                    )
                    let base64 = data.base64EncodedString() as NSString
                    var chunks: [String] = []
                    var location = 0
                    while location < base64.length {
                        let length = min(
                            Self.javaScriptChunkLength,
                            base64.length - location
                        )
                        chunks.append(base64.substring(
                            with: NSRange(location: location, length: length)
                        ))
                        location += length
                    }

                    let mimeType = UTType(
                        filenameExtension: sourceURL.pathExtension
                    )?.preferredMIMEType ?? "application/octet-stream"
                    return PreparedIncomingDocument(
                        sourceURL: sourceURL,
                        filename: sourceURL.lastPathComponent,
                        mimeType: mimeType,
                        base64Chunks: chunks
                    )
                }

                DispatchQueue.main.async { [weak self] in
                    self?.beginJavaScriptDocumentTransfer(
                        payloads,
                        totalSize: totalSize
                    )
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.automaticAttachmentFailed()
                }
            }
        }
    }

    private func beginJavaScriptDocumentTransfer(
        _ payloads: [PreparedIncomingDocument],
        totalSize: Int64
    ) {
        guard payloads.allSatisfy({
            pendingDocumentURLs.contains($0.sourceURL)
        }) else {
            isAutomaticallyAttachingDocuments = false
            return
        }

        let metadata = payloads.map {
            [
                "name": $0.filename,
                "type": $0.mimeType,
                "chunks": []
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: metadata
        ), let json = String(data: data, encoding: .utf8) else {
            automaticAttachmentFailed()
            return
        }

        let script = """
        window.__gptwebIncomingUpload = {
          files: \(json),
          byteLength: \(totalSize)
        };
        true;
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self else { return }
            guard error == nil else {
                self.automaticAttachmentFailed()
                return
            }
            self.sendJavaScriptDocumentChunk(
                payloads,
                fileIndex: 0,
                chunkIndex: 0
            )
        }
    }

    private func sendJavaScriptDocumentChunk(
        _ payloads: [PreparedIncomingDocument],
        fileIndex: Int,
        chunkIndex: Int
    ) {
        guard payloads.allSatisfy({
            pendingDocumentURLs.contains($0.sourceURL)
        }) else {
            isAutomaticallyAttachingDocuments = false
            webView.evaluateJavaScript(
                "delete window.__gptwebIncomingUpload;",
                completionHandler: nil
            )
            return
        }

        guard fileIndex < payloads.count else {
            finalizeJavaScriptDocumentTransfer(payloads)
            return
        }

        let chunks = payloads[fileIndex].base64Chunks
        guard chunkIndex < chunks.count else {
            sendJavaScriptDocumentChunk(
                payloads,
                fileIndex: fileIndex + 1,
                chunkIndex: 0
            )
            return
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: [chunks[chunkIndex]]
        ), let jsonArray = String(data: data, encoding: .utf8) else {
            automaticAttachmentFailed()
            return
        }
        let script = """
        window.__gptwebIncomingUpload.files[\(fileIndex)].chunks.push(
          \(jsonArray)[0]
        );
        true;
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self else { return }
            guard error == nil else {
                self.automaticAttachmentFailed()
                return
            }
            self.sendJavaScriptDocumentChunk(
                payloads,
                fileIndex: fileIndex,
                chunkIndex: chunkIndex + 1
            )
        }
    }

    private func finalizeJavaScriptDocumentTransfer(
        _ payloads: [PreparedIncomingDocument]
    ) {
        guard payloads.allSatisfy({
            pendingDocumentURLs.contains($0.sourceURL)
        }) else {
            isAutomaticallyAttachingDocuments = false
            webView.evaluateJavaScript(
                "delete window.__gptwebIncomingUpload;",
                completionHandler: nil
            )
            return
        }

        webView.evaluateJavaScript(Self.finalizeIncomingUploadScript) {
            [weak self] value, error in
            guard let self else { return }
            let result = value as? [String: Any]
            let succeeded = result?["success"] as? Bool ?? false
            guard error == nil, succeeded else {
                self.automaticAttachmentFailed()
                return
            }
            self.automaticAttachmentSucceeded(
                payloads.map(\.sourceURL)
            )
        }
    }

    private func automaticAttachmentSucceeded(_ attachedURLs: [URL]) {
        let attachedSet = Set(attachedURLs)
        pendingDocumentURLs.removeAll { attachedSet.contains($0) }
        isAutomaticallyAttachingDocuments = false
        automaticAttachmentAttemptCount = 0
        shouldPresentDocumentNotice = false

        let directories = Set(attachedURLs.map {
            $0.deletingLastPathComponent()
        })
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 30
        ) {
            directories.forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }

        if !pendingDocumentURLs.isEmpty {
            attemptAutomaticDocumentAttachment()
        }
    }

    private func automaticAttachmentFailed() {
        isAutomaticallyAttachingDocuments = false
        webView.evaluateJavaScript(
            "delete window.__gptwebIncomingUpload;",
            completionHandler: nil
        )
        scheduleAutomaticAttachmentRetry()
    }

    private func scheduleAutomaticAttachmentRetry() {
        guard !pendingDocumentURLs.isEmpty else { return }
        automaticAttachmentAttemptCount += 1
        guard automaticAttachmentAttemptCount <
                Self.maximumAutomaticAttachmentAttempts else {
            useManualAttachmentFallback()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            [weak self] in
            self?.attemptAutomaticDocumentAttachment()
        }
    }

    private func useManualAttachmentFallback() {
        isAutomaticallyAttachingDocuments = false
        shouldPresentDocumentNotice = true
        presentIncomingDocumentNoticeIfNeeded()
    }

    private func isChatGPTPage(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "chatgpt.com" ||
            host.hasSuffix(".chatgpt.com") ||
            host == "chat.openai.com"
    }

    private func presentIncomingDocumentNoticeIfNeeded() {
        guard shouldPresentDocumentNotice,
              isViewLoaded,
              view.window != nil,
              presentedViewController == nil,
              !pendingDocumentURLs.isEmpty else {
            return
        }

        shouldPresentDocumentNotice = false
        let names = pendingDocumentURLs.map(\.lastPathComponent)
        let summary: String
        if names.count == 1 {
            summary = "已接收“\(names[0])”。"
        } else {
            summary = "已接收 \(names.count) 个文件。"
        }

        let alert = UIAlertController(
            title: "自动加入未完成",
            message: summary +
                "\n\niOS 16 的 WebKit 没有开放替换文件选择器的接口。" +
                "请在 ChatGPT 输入框旁点击“+”，再从原位置选择这个文件。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消文件", style: .destructive) {
            [weak self] _ in
            self?.discardPendingDocuments()
        })
        alert.addAction(UIAlertAction(title: "继续", style: .default))
        present(alert, animated: true)
    }

    private func discardPendingDocuments() {
        let fileManager = FileManager.default
        let directories = Set(pendingDocumentURLs.map {
            $0.deletingLastPathComponent()
        })
        pendingDocumentURLs.removeAll()
        directories.forEach { try? fileManager.removeItem(at: $0) }
    }

    private func presentDocumentError(message: String) {
        guard isViewLoaded,
              view.window != nil,
              presentedViewController == nil else {
            pendingDocumentErrorMessage = message
            return
        }
        let alert = UIAlertController(
            title: "无法接收文件",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private func presentPendingDocumentErrorIfNeeded() {
        guard let message = pendingDocumentErrorMessage,
              isViewLoaded,
              view.window != nil,
              presentedViewController == nil else {
            return
        }
        pendingDocumentErrorMessage = nil
        presentDocumentError(message: message)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WebSession.shared.processPool
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.suppressesIncrementalRendering = false

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        preferences.preferredContentMode = .mobile
        configuration.defaultWebpagePreferences = preferences

        let contentController = WKUserContentController()
        contentController.addUserScript(WKUserScript(
            source: Self.automaticScrollRepairScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = Self.mobileSafariUserAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = true
        return webView
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = view.window?.tintColor ?? .systemGreen
        progressView.trackTintColor = .clear
        progressView.isHidden = true

        errorView.onRetry = { [weak self] in
            self?.reloadCurrentPage()
        }
        errorView.onOpenInSafari = {
            UIApplication.shared.open(BrowserPolicy.homeURL)
        }

        view.addSubview(webView)
        view.addSubview(progressView)
        view.addSubview(errorView)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            webView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),

            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
        ])
    }

    private func configureObservers() {
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressView.progress = Float(webView.estimatedProgress)
                self.progressView.isHidden = !webView.isLoading || webView.estimatedProgress >= 1
            }
        })

        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.progressView.isHidden = !webView.isLoading
            }
        })

        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.scheduleAutomaticScrollRepair()
            }
        })
    }

    private func configureNativeSidebarGestures() {
        let openGesture = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleSidebarOpenGesture(_:))
        )
        openGesture.edges = .left
        openGesture.cancelsTouchesInView = false
        openGesture.delegate = self
        view.addGestureRecognizer(openGesture)
        sidebarOpenGesture = openGesture

        let closeGesture = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleSidebarCloseGesture(_:))
        )
        closeGesture.maximumNumberOfTouches = 1
        closeGesture.cancelsTouchesInView = false
        closeGesture.delegate = self
        view.addGestureRecognizer(closeGesture)
        sidebarCloseGesture = closeGesture
    }

    @objc private func handleSidebarOpenGesture(
        _ gesture: UIScreenEdgePanGestureRecognizer
    ) {
        handleSidebarGesture(gesture, opening: true)
    }

    @objc private func handleSidebarCloseGesture(
        _ gesture: UIPanGestureRecognizer
    ) {
        handleSidebarGesture(gesture, opening: false)
    }

    private func handleSidebarGesture(
        _ gesture: UIPanGestureRecognizer,
        opening: Bool
    ) {
        switch gesture.state {
        case .began, .changed:
            guard !sidebarGestureDidTrigger else { return }
            let translation = gesture.translation(in: view)
            let horizontalDistance = opening ? translation.x : -translation.x
            guard horizontalDistance >= 18,
                  horizontalDistance > abs(translation.y) * 1.35 else {
                return
            }
            sidebarGestureDidTrigger = true
            webView.evaluateJavaScript(
                opening ? Self.openSidebarScript : Self.closeSidebarScript,
                completionHandler: nil
            )

        case .ended, .cancelled, .failed:
            sidebarGestureDidTrigger = false

        default:
            break
        }
    }

    private func scheduleAutomaticScrollRepair() {
        automaticScrollRepairWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let host = self.webView.url?.host?.lowercased(),
                  host == "chatgpt.com" ||
                    host.hasSuffix(".chatgpt.com") ||
                    host == "chat.openai.com" else {
                return
            }
            self.webView.evaluateJavaScript(
                "window.__gptwebRepairScroll && window.__gptwebRepairScroll();",
                completionHandler: nil
            )
        }
        automaticScrollRepairWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func configureConnectivity() {
        connectivityMonitor.onChange = { [weak self] connected in
            guard let self else { return }
            let reconnected = connected && !self.isConnected
            self.isConnected = connected

            if !connected && (self.webView.url == nil || self.lastLoadFailed) {
                self.errorView.show(
                    title: "当前没有网络连接",
                    message: "连接 Wi‑Fi 或蜂窝网络后再试。"
                )
            } else if reconnected && self.lastLoadFailed {
                self.reloadCurrentPage()
            }
        }
        connectivityMonitor.start()
    }

    private func loadInitialPage() {
        load(BrowserPolicy.homeURL)
    }

    private func load(_ url: URL) {
        guard isConnected else {
            errorView.show(
                title: "当前没有网络连接",
                message: "连接 Wi‑Fi 或蜂窝网络后再试。"
            )
            return
        }

        lastLoadFailed = false
        errorView.hide()

        var request = URLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 45
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        webView.load(request)
    }

    private func reloadCurrentPage() {
        guard isConnected else {
            errorView.show(
                title: "当前没有网络连接",
                message: "连接 Wi‑Fi 或蜂窝网络后再试。"
            )
            return
        }

        lastLoadFailed = false
        errorView.hide()
        if webView.url == nil {
            loadInitialPage()
        } else {
            webView.reload()
        }
    }

    private func presentExternalURL(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            UIApplication.shared.open(url)
            return
        }

        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        safari.preferredControlTintColor = view.tintColor
        present(safari, animated: true)
    }

    private func handleLoadFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            // WebKit reports this when a navigation is intentionally converted
            // into a WKDownload. The page itself is still healthy.
            lastLoadFailed = false
            errorView.hide()
            return
        }

        lastLoadFailed = true
        let message: String
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            message = "服务器响应超时。你的登录状态仍然保留，可以直接重试。"
        } else {
            message = "页面暂时无法载入（\(nsError.localizedDescription)）。"
        }
        errorView.show(title: "ChatGPT 没有载入", message: message)
    }

    private func beginDownload(_ download: WKDownload) {
        lastLoadFailed = false
        errorView.hide()
        download.delegate = self
    }

    private func presentDownloadError(_ error: Error) {
        let alert = UIAlertController(
            title: "下载失败",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    private static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_3 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.3 " +
        "Mobile/15E148 Safari/604.1"

    private static let maximumAutomaticAttachmentBytes: Int64 =
        24 * 1_024 * 1_024
    private static let maximumAutomaticAttachmentAttempts = 10
    private static let javaScriptChunkLength = 128 * 1_024

    private static let uploadInputAvailabilityScript = """
    (function () {
      if (typeof DataTransfer !== 'function' ||
          typeof File !== 'function' ||
          typeof Blob !== 'function') {
        return false;
      }
      var hasInput = Array.prototype.some.call(
        document.querySelectorAll('input[type="file"]'),
        function (input) {
          return !input.disabled;
        }
      );
      if (hasInput) return true;

      var controls = Array.prototype.slice.call(
        document.querySelectorAll(
          'button,[role="button"],[role="menuitem"]'
        )
      );
      var scored = controls.map(function (control) {
        var value = [
          control.getAttribute('aria-label') || '',
          control.getAttribute('data-testid') || '',
          control.textContent || ''
        ].join(' ').toLowerCase();
        var score = 0;
        if (/upload|attach|file|上传|附件/.test(value)) score += 100;
        if (/composer.*plus|plus.*composer/.test(value)) score += 70;
        return { control: control, score: score };
      }).filter(function (entry) {
        return entry.score > 0 && !entry.control.disabled;
      }).sort(function (left, right) {
        return right.score - left.score;
      });

      if (scored.length) {
        scored[0].control.click();
      }
      return false;
    })();
    """

    private static let finalizeIncomingUploadScript = """
    (function () {
      var state = window.__gptwebIncomingUpload;
      if (!state || !state.files || !state.files.length) {
        return { success: false, reason: 'missing-state' };
      }

      var inputs = Array.prototype.slice.call(
        document.querySelectorAll('input[type="file"]')
      ).filter(function (input) {
        return !input.disabled;
      });
      if (!inputs.length) {
        delete window.__gptwebIncomingUpload;
        return { success: false, reason: 'missing-input' };
      }

      inputs.sort(function (left, right) {
        function score(input) {
          var value = [
            input.name || '',
            input.id || '',
            input.getAttribute('aria-label') || '',
            input.getAttribute('data-testid') || '',
            input.accept || ''
          ].join(' ').toLowerCase();
          var result = input.multiple ? 40 : 0;
          if (input.closest && input.closest('main')) result += 30;
          if (/upload|attach|file/.test(value)) result += 80;
          return result;
        }
        return score(right) - score(left);
      });

      try {
        var transfer = new DataTransfer();
        state.files.forEach(function (entry) {
          var binary = window.atob(entry.chunks.join(''));
          var bytes = new Uint8Array(binary.length);
          for (var index = 0; index < binary.length; index += 1) {
            bytes[index] = binary.charCodeAt(index);
          }
          var blob = new Blob([bytes], {
            type: entry.type || 'application/octet-stream'
          });
          transfer.items.add(new File([blob], entry.name, {
            type: entry.type || 'application/octet-stream',
            lastModified: Date.now()
          }));
        });

        var input = inputs[0];
        if (!input.multiple && transfer.files.length > 1) {
          delete window.__gptwebIncomingUpload;
          return { success: false, reason: 'single-file-input' };
        }
        input.files = transfer.files;
        input.dispatchEvent(new Event('input', {
          bubbles: true,
          composed: true
        }));
        input.dispatchEvent(new Event('change', {
          bubbles: true,
          composed: true
        }));
        var count = transfer.files.length;
        delete window.__gptwebIncomingUpload;
        return { success: true, count: count };
      } catch (error) {
        delete window.__gptwebIncomingUpload;
        return {
          success: false,
          reason: String(error && error.message || error)
        };
      }
    })();
    """

    private static let openSidebarScript = """
    (function () {
      var control = document.querySelector(
        'button[data-testid="open-sidebar-button"]'
      ) || document.querySelector(
        '[aria-label="Open sidebar"], [aria-label="打开边栏"], ' +
        '[aria-label="打开侧边栏"], [aria-label="打开聊天列表"]'
      );
      if (!control || control.disabled) return false;
      control.click();
      return true;
    })();
    """

    private static let closeSidebarScript = """
    (function () {
      var control = document.querySelector(
        'button[data-testid="close-sidebar-button"]'
      ) || document.querySelector(
        '[aria-label="Close sidebar"], [aria-label="关闭边栏"], ' +
        '[aria-label="关闭侧边栏"], [aria-label="收起聊天列表"]'
      );
      var sidebar = document.getElementById('stage-popover-sidebar');
      if (!control && sidebar) {
        control = sidebar.querySelector('button, [role="button"]');
      }
      if (!control || control.disabled) return false;
      control.click();
      return true;
    })();
    """

    private static let automaticScrollRepairScript = """
    (function () {
      var hostname = String(window.location.hostname || '').toLowerCase();
      var supportedHost = hostname === 'chatgpt.com' ||
        hostname.slice(-12) === '.chatgpt.com' ||
        hostname === 'chat.openai.com';
      if (!supportedHost || window.__gptwebAutomaticScrollRepairInstalled) return;
      window.__gptwebAutomaticScrollRepairInstalled = true;

      var style = document.createElement('style');
      style.id = 'gptweb-ios16-automatic-scroll-style';
      style.textContent = [
        'html { -webkit-text-size-adjust: 100%; }',
        '@supports (-webkit-touch-callout: none) {',
        '  textarea, input:not([type="checkbox"]):not([type="radio"]), [contenteditable="true"] {',
        '    font-size: 16px !important;',
        '  }',
        '  button, a, [role="button"] { touch-action: manipulation; }',
        '}',
        '[data-gptweb-scroll-repaired="true"] {',
        '  overflow-y: auto !important;',
        '  -webkit-overflow-scrolling: auto !important;',
        '  overscroll-behavior-y: contain !important;',
        '  touch-action: pan-y !important;',
        '  min-height: 0 !important;',
        '}'
      ].join(String.fromCharCode(10));
      (document.head || document.documentElement).appendChild(style);

      var observer = null;
      var retryTimer = 0;
      var mutationTimer = 0;
      var attempts = 0;
      var deadline = 0;
      var maxAttempts = 12;

      function stopWatching() {
        if (observer) {
          observer.disconnect();
          observer = null;
        }
        if (retryTimer) {
          window.clearTimeout(retryTimer);
          retryTimer = 0;
        }
        if (mutationTimer) {
          window.clearTimeout(mutationTimer);
          mutationTimer = 0;
        }
      }

      function parentAcrossShadowDOM(element) {
        if (!element) return null;
        if (element.parentElement) return element.parentElement;
        var root = element.getRootNode ? element.getRootNode() : null;
        return root && root.host ? root.host : null;
      }

      function inspectScroller(element) {
        if (!element || element.nodeType !== 1 || !element.isConnected) {
          return null;
        }
        var root = document.scrollingElement || document.documentElement;
        if (element === root || element === document.body) return null;

        var range = Math.max(0, element.scrollHeight - element.clientHeight);
        if (range < 12) return null;

        var rect = element.getBoundingClientRect();
        var viewportWidth = window.innerWidth || root.clientWidth;
        var viewportHeight = window.innerHeight || root.clientHeight;
        if (rect.width < 120 || rect.height < 96 ||
            rect.right <= 0 || rect.bottom <= 0 ||
            rect.left >= viewportWidth || rect.top >= viewportHeight) {
          return null;
        }

        if (element.closest && element.closest(
          '#stage-popover-sidebar, [role="menu"], pre, code'
        )) {
          return null;
        }

        var overflow = window.getComputedStyle(element).overflowY || 'visible';
        var role = element.getAttribute('role') || '';
        var name = String(element.className || '');
        var native = overflow === 'auto' ||
          overflow === 'scroll' ||
          overflow === 'overlay';
        var relevant = native ||
          overflow === 'hidden' ||
          overflow === 'clip' ||
          element.tagName === 'MAIN' ||
          role === 'main' ||
          role === 'dialog' ||
          name.indexOf('overflow') !== -1 ||
          element.hasAttribute('data-scroll-root');
        if (!relevant) return null;

        return {
          element: element,
          range: range,
          rect: rect,
          role: role,
          name: name,
          native: native
        };
      }

      function scrollerScore(inspection, focused) {
        var viewportArea = Math.max(1, window.innerWidth * window.innerHeight);
        var score = Math.min(
          100,
          inspection.rect.width * inspection.rect.height / viewportArea * 100
        );
        score += Math.min(55, inspection.range / 120);
        if (focused) score += 140;
        if (inspection.native) score += 65;
        if (inspection.element.tagName === 'MAIN' ||
            inspection.role === 'main') score += 70;
        if (inspection.role === 'dialog') score += 35;
        if (inspection.name.indexOf('overflow') !== -1) score += 40;
        if (inspection.element.hasAttribute('data-scroll-root')) score += 85;
        return score;
      }

      function findScroller() {
        var candidates = [];
        var focusedCandidates = [];

        function collect(element, focused) {
          var current = element && element.nodeType === 1 ? element : null;
          var depth = 0;
          while (current && depth < 18 && candidates.length < 48) {
            if (candidates.indexOf(current) === -1) candidates.push(current);
            if (focused && focusedCandidates.indexOf(current) === -1) {
              focusedCandidates.push(current);
            }
            current = parentAcrossShadowDOM(current);
            depth += 1;
          }
        }

        if (typeof document.elementFromPoint === 'function') {
          var viewportWidth = window.innerWidth ||
            document.documentElement.clientWidth;
          var viewportHeight = window.innerHeight ||
            document.documentElement.clientHeight;
          [0.36, 0.55, 0.72].forEach(function (verticalRatio) {
            collect(document.elementFromPoint(
              viewportWidth * 0.52,
              viewportHeight * verticalRatio
            ), true);
          });
        }

        var selector = [
          '[data-scroll-root]',
          'main [role="log"]',
          'main [role="feed"]',
          'main [class*="overflow-y-auto"]',
          'main [class*="overflow-auto"]',
          '[role="main"] [class*="overflow-y-auto"]',
          '[role="main"] [class*="overflow-auto"]',
          '[role="dialog"] [class*="overflow-y-auto"]',
          '[role="main"]',
          '[role="dialog"]',
          'main'
        ].join(',');
        var nodes = document.querySelectorAll(selector);
        var limit = Math.min(nodes.length, 40);
        for (var index = 0; index < limit && candidates.length < 48; index += 1) {
          if (candidates.indexOf(nodes[index]) === -1) {
            candidates.push(nodes[index]);
          }
        }

        var best = null;
        var bestScore = -1;
        for (var candidateIndex = 0;
             candidateIndex < candidates.length;
             candidateIndex += 1) {
          var candidate = candidates[candidateIndex];
          var inspection = inspectScroller(candidate);
          if (!inspection) continue;
          var score = scrollerScore(
            inspection,
            focusedCandidates.indexOf(candidate) !== -1
          );
          if (score > bestScore) {
            best = candidate;
            bestScore = score;
          }
        }
        return best;
      }

      function repairScroller(element) {
        if (!element || !element.style) return false;
        if (element.getAttribute('data-gptweb-scroll-repaired') === 'true') {
          return true;
        }
        element.style.setProperty('overflow-y', 'auto', 'important');
        element.style.setProperty(
          '-webkit-overflow-scrolling',
          'auto',
          'important'
        );
        element.style.setProperty(
          'overscroll-behavior-y',
          'contain',
          'important'
        );
        element.style.setProperty('touch-action', 'pan-y', 'important');
        element.style.setProperty('min-height', '0', 'important');
        element.setAttribute('data-gptweb-scroll-repaired', 'true');
        void element.offsetHeight;
        return true;
      }

      function attemptRepair() {
        if (retryTimer) {
          window.clearTimeout(retryTimer);
          retryTimer = 0;
        }
        if (mutationTimer) {
          window.clearTimeout(mutationTimer);
          mutationTimer = 0;
        }
        if (attempts >= maxAttempts || Date.now() > deadline) {
          stopWatching();
          return false;
        }
        attempts += 1;

        var scroller = findScroller();
        if (scroller && repairScroller(scroller)) {
          stopWatching();
          return true;
        }

        if (!observer && typeof MutationObserver === 'function') {
          var container = document.querySelector('main, [role="main"]') ||
            document.body;
          if (container) {
            observer = new MutationObserver(function () {
              if (mutationTimer || attempts >= maxAttempts) return;
              mutationTimer = window.setTimeout(attemptRepair, 90);
            });
            observer.observe(container, { childList: true, subtree: true });
          }
        }

        if (!retryTimer) {
          retryTimer = window.setTimeout(attemptRepair, 220);
        }
        return false;
      }

      function armRepair() {
        stopWatching();
        attempts = 0;
        deadline = Date.now() + 2800;
        return attemptRepair();
      }

      window.__gptwebRepairScroll = armRepair;

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', armRepair, { once: true });
      } else {
        armRepair();
      }

      window.addEventListener('pageshow', armRepair, { passive: true });
      window.addEventListener('popstate', armRepair, { passive: true });
    })();
    """
}

extension WebViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.preferredContentMode = .mobile

        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if ["blob", "data", "filesystem"].contains(scheme) {
            decisionHandler(.download, preferences)
            return
        }
        if scheme == "about" {
            decisionHandler(.allow, preferences)
            return
        }
        if !["http", "https"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            UIApplication.shared.open(url)
            return
        }

        let isTopLevel = navigationAction.targetFrame?.isMainFrame ?? true
        if !isTopLevel || BrowserPolicy.shouldOpenInside(url, from: webView.url) {
            decisionHandler(.allow, preferences)
        } else {
            decisionHandler(.cancel, preferences)
            presentExternalURL(url)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let contentDisposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased() ?? ""
        let isAttachment = contentDisposition.contains("attachment")
        decisionHandler(
            isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow
        )
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorView.hide()
        lastLoadFailed = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorView.hide()
        lastLoadFailed = false
        recoveryAttempts.removeAll()
        scheduleAutomaticScrollRepair()
        attemptAutomaticDocumentAttachment()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        recoveryAttempts = recoveryAttempts.filter { now.timeIntervalSince($0) < 60 }

        guard recoveryAttempts.count < 3 else {
            lastLoadFailed = true
            errorView.show(
                title: "网页进程已停止",
                message: "iOS 多次回收了网页进程。关闭其他占用内存较多的应用后再重试。"
            )
            return
        }

        recoveryAttempts.append(now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak webView] in
            guard let self, let webView else { return }
            if webView.url == nil {
                self.loadInitialPage()
            } else {
                webView.reload()
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        beginDownload(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        beginDownload(download)
    }
}

extension WebViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }

        let velocity = panGesture.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) * 1.35 else {
            return false
        }

        if gestureRecognizer === sidebarOpenGesture {
            return velocity.x > 0
        }
        if gestureRecognizer === sidebarCloseGesture {
            return velocity.x < 0
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

extension WebViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else {
            return nil
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if ["blob", "data", "filesystem"].contains(scheme) ||
            BrowserPolicy.shouldOpenInside(url, from: webView.url) {
            webView.load(navigationAction.request)
        } else {
            presentExternalURL(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(
            BrowserPolicy.isFirstPartyHost(origin.host.lowercased()) ? .prompt : .deny
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: webView.title ?? "ChatGPT", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: webView.title ?? "ChatGPT", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "继续", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: webView.title ?? "ChatGPT", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}

extension WebViewController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let safeFilename = suggestedFilename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTWebDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(
                safeFilename.isEmpty ? "download" : safeFilename
            )
            downloadDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch {
            completionHandler(nil)
            errorView.show(
                title: "无法准备下载",
                message: error.localizedDescription,
                canRetry: false
            )
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloadDestinations.removeValue(
            forKey: ObjectIdentifier(download)
        ) else {
            return
        }

        let shareSheet = UIActivityViewController(
            activityItems: [destination],
            applicationActivities: nil
        )
        shareSheet.popoverPresentationController?.sourceView = view
        shareSheet.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX,
            y: view.bounds.maxY - 40,
            width: 1,
            height: 1
        )
        present(shareSheet, animated: true)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        presentDownloadError(error)
    }
}
