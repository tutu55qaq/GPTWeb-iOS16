import SafariServices
import UIKit
import WebKit

final class WebViewController: UIViewController {
    private enum Keys {
        static let lastURL = "GPTWeb.lastFirstPartyURL"
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

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        configureObservers()
        configureConnectivity()
        loadInitialPage()
    }

    deinit {
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
        }
    }

    func prepareForBackground() {
        guard isViewLoaded else { return }
        webView.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(function(media){ media.pause(); });",
            completionHandler: nil
        )
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
            source: Self.scrollbarScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = Self.mobileSafariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isOpaque = false
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
        let storedURL = UserDefaults.standard.string(forKey: Keys.lastURL).flatMap(URL.init(string:))
        let destination = BrowserPolicy.canPersist(storedURL) ? storedURL! : BrowserPolicy.homeURL
        load(destination)
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

    private func persistCurrentURL() {
        guard BrowserPolicy.canPersist(webView.url) else { return }
        UserDefaults.standard.set(webView.url?.absoluteString, forKey: Keys.lastURL)
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

    private static let compatibilityScript = """
    (function () {
      var hostname = String(window.location.hostname || '').toLowerCase();
      var isChatGPTDocument = hostname === 'chatgpt.com' ||
        hostname.slice(-12) === '.chatgpt.com' ||
        hostname === 'chat.openai.com';
      if (!isChatGPTDocument) return;
      if (window.__gptwebIOS16CompatibilityInstalled) return;
      window.__gptwebIOS16CompatibilityInstalled = true;

      var style = document.createElement('style');
      style.id = 'gptweb-ios16-compat';
      style.textContent = [
        'html { -webkit-text-size-adjust: 100%; overscroll-behavior-y: none; }',
        'body { overscroll-behavior-y: none; }',
        '@supports (-webkit-touch-callout: none) {',
        '  textarea, input:not([type="checkbox"]):not([type="radio"]), [contenteditable="true"] {',
        '    font-size: 16px !important;',
        '  }',
        '  button, a, [role="button"] { touch-action: manipulation; }',
        '  [data-gptweb-scroll-fix="true"] {',
        '    overflow-y: auto !important;',
        '    -webkit-overflow-scrolling: auto !important;',
        '    overscroll-behavior-y: contain !important;',
        '    touch-action: pan-y !important;',
        '    min-height: 0 !important;',
        '  }',
        '}'
      ].join('\\n');
      (document.head || document.documentElement).appendChild(style);

      var gesture = null;
      var fixedScrollers = [];

      function parentElementAcrossShadowDOM(element) {
        if (!element) return null;
        if (element.parentElement) return element.parentElement;
        var root = element.getRootNode ? element.getRootNode() : null;
        return root && root.host ? root.host : null;
      }

      function isVisible(element) {
        if (!element || element.nodeType !== 1) return false;
        var rect = element.getBoundingClientRect();
        var viewportHeight = window.innerHeight || document.documentElement.clientHeight;
        var viewportWidth = window.innerWidth || document.documentElement.clientWidth;
        return rect.height >= 96 &&
          rect.width >= 120 &&
          rect.bottom > 0 &&
          rect.right > 0 &&
          rect.top < viewportHeight &&
          rect.left < viewportWidth;
      }

      function scrollRange(element) {
        return Math.max(0, element.scrollHeight - element.clientHeight);
      }

      function overflowKind(element) {
        var value = window.getComputedStyle(element).overflowY;
        return value || 'visible';
      }

      function isNativeScroller(element) {
        var overflow = overflowKind(element);
        return overflow === 'auto' || overflow === 'scroll' || overflow === 'overlay';
      }

      function isBrokenScrollerCandidate(element) {
        if (!isVisible(element) || scrollRange(element) < 12) return false;
        var overflow = overflowKind(element);
        if (overflow === 'hidden' || overflow === 'clip') return true;
        var role = element.getAttribute('role') || '';
        var name = String(element.className || '');
        return element.tagName === 'MAIN' ||
          role === 'main' ||
          role === 'dialog' ||
          name.indexOf('overflow') !== -1 ||
          element.hasAttribute('data-scroll-root');
      }

      function rememberScroller(element) {
        if (fixedScrollers.indexOf(element) === -1) fixedScrollers.push(element);
        if (fixedScrollers.length > 12) fixedScrollers.shift();
      }

      function repairScroller(element) {
        if (!element || !element.isConnected) return;
        element.setAttribute('data-gptweb-scroll-fix', 'true');
        element.style.setProperty('overflow-y', 'auto', 'important');
        element.style.setProperty('-webkit-overflow-scrolling', 'auto', 'important');
        element.style.setProperty('overscroll-behavior-y', 'contain', 'important');
        element.style.setProperty('touch-action', 'pan-y', 'important');
        void element.offsetHeight;
        rememberScroller(element);
      }

      function nearestScroller(start) {
        var element = start && start.nodeType === 1 ? start : start && start.parentElement;
        var brokenCandidate = null;
        var depth = 0;

        while (element && element !== document.documentElement && depth < 40) {
          if (isVisible(element) && scrollRange(element) >= 12) {
            if (isNativeScroller(element)) return element;
            if (!brokenCandidate && isBrokenScrollerCandidate(element)) {
              brokenCandidate = element;
            }
          }
          element = parentElementAcrossShadowDOM(element);
          depth += 1;
        }
        return brokenCandidate;
      }

      function pointInside(rect, x, y) {
        return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
      }

      function fallbackScroller(start, x, y) {
        var selector = [
          '[data-scroll-root]',
          '[data-testid*="conversation"]',
          '[data-testid*="thread"]',
          '[data-testid*="message"]',
          '[class*="overflow-y-auto"]',
          '[class*="overflow-auto"]',
          '[role="main"]',
          '[role="dialog"]',
          'main'
        ].join(',');
        var nodes = document.querySelectorAll(selector);
        var best = null;
        var bestScore = -1;
        var count = Math.min(nodes.length, 300);

        for (var index = 0; index < count; index += 1) {
          var node = nodes[index];
          if (!isVisible(node) || scrollRange(node) < 12) continue;
          var rect = node.getBoundingClientRect();
          var containsStart = start && node.contains(start);
          var containsPoint = pointInside(rect, x, y);
          if (!containsStart && !containsPoint) continue;

          var score = 0;
          if (containsStart) score += 120;
          if (containsPoint) score += 80;
          if (isNativeScroller(node)) score += 40;
          if (overflowKind(node) === 'hidden' || overflowKind(node) === 'clip') score += 25;
          score += Math.min(35, scrollRange(node) / 120);
          score += Math.min(20, rect.height / 80);
          if (score > bestScore) {
            best = node;
            bestScore = score;
          }
        }
        return best;
      }

      function findScroller(start, x, y) {
        var nested = nearestScroller(start) || fallbackScroller(start, x, y);
        if (nested) return nested;
        var root = document.scrollingElement || document.documentElement;
        return root && scrollRange(root) >= 12 ? root : null;
      }

      function isEditableTarget(target) {
        if (!target || !target.closest) return false;
        return Boolean(target.closest(
          'textarea,input,select,[contenteditable="true"],[role="textbox"],canvas'
        ));
      }

      function beginGesture(event) {
        if (event.touches.length !== 1 || isEditableTarget(event.target)) {
          gesture = null;
          return;
        }
        var touch = event.touches[0];
        var scroller = findScroller(event.target, touch.clientX, touch.clientY);
        if (!scroller) {
          gesture = null;
          return;
        }

        repairScroller(scroller);
        gesture = {
          scroller: scroller,
          startX: touch.clientX,
          startY: touch.clientY,
          lastY: touch.clientY,
          observedTop: scroller.scrollTop,
          windowX: window.scrollX,
          windowY: window.scrollY,
          moveCount: 0,
          nativeScrolling: false,
          manualScrolling: false
        };
      }

      function continueGesture(event) {
        if (!gesture || event.touches.length !== 1) return;
        var scroller = gesture.scroller;
        if (!scroller || !scroller.isConnected) {
          gesture = null;
          return;
        }

        var touch = event.touches[0];
        var totalX = touch.clientX - gesture.startX;
        var totalY = touch.clientY - gesture.startY;
        var deltaY = gesture.lastY - touch.clientY;
        gesture.lastY = touch.clientY;

        if (Math.abs(totalY) < 8 || Math.abs(totalY) <= Math.abs(totalX) * 1.1) return;

        var currentTop = scroller.scrollTop;
        if (!gesture.manualScrolling &&
            Math.abs(currentTop - gesture.observedTop) > 0.5) {
          gesture.nativeScrolling = true;
        }
        gesture.observedTop = currentTop;
        gesture.moveCount += 1;

        if (gesture.nativeScrolling) return;
        if (!gesture.manualScrolling && gesture.moveCount < 2) return;

        var maximum = scrollRange(scroller);
        var nextTop = Math.max(0, Math.min(maximum, currentTop + deltaY));
        if (Math.abs(nextTop - currentTop) > 0.5) {
          scroller.scrollTop = nextTop;
          gesture.observedTop = nextTop;
          gesture.manualScrolling = true;
        }

        if (gesture.manualScrolling) {
          if (window.scrollX !== gesture.windowX || window.scrollY !== gesture.windowY) {
            window.scrollTo(gesture.windowX, gesture.windowY);
          }
          event.preventDefault();
          event.stopPropagation();
        }
      }

      function endGesture() {
        gesture = null;
      }

      document.addEventListener('touchstart', beginGesture, {
        capture: true,
        passive: true
      });
      document.addEventListener('touchmove', continueGesture, {
        capture: true,
        passive: false
      });
      document.addEventListener('touchend', endGesture, {
        capture: true,
        passive: true
      });
      document.addEventListener('touchcancel', endGesture, {
        capture: true,
        passive: true
      });

      var refreshScheduled = false;
      var observer = new MutationObserver(function () {
        if (refreshScheduled) return;
        refreshScheduled = true;
        window.requestAnimationFrame(function () {
          refreshScheduled = false;
          fixedScrollers = fixedScrollers.filter(function (element) {
            if (!element.isConnected) return false;
            repairScroller(element);
            return true;
          });
        });
      });
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true
      });
    })();
    """

    private static let scrollbarScript = """
    (function () {
      var hostname = String(window.location.hostname || '').toLowerCase();
      var isChatGPTDocument = hostname === 'chatgpt.com' ||
        hostname.slice(-12) === '.chatgpt.com' ||
        hostname === 'chat.openai.com';
      if (!isChatGPTDocument) return;
      if (window.__gptwebIOS16ScrollbarInstalled) return;
      window.__gptwebIOS16ScrollbarInstalled = true;

      var style = document.createElement('style');
      style.id = 'gptweb-ios16-scrollbar-style';
      style.textContent = [
        'html { -webkit-text-size-adjust: 100%; }',
        '@supports (-webkit-touch-callout: none) {',
        '  textarea, input:not([type="checkbox"]):not([type="radio"]), [contenteditable="true"] {',
        '    font-size: 16px !important;',
        '  }',
        '  button, a, [role="button"] { touch-action: manipulation; }',
        '}',
        '#gptweb-scrollbar {',
        '  position: fixed;',
        '  z-index: 2147483646;',
        '  top: calc(env(safe-area-inset-top, 0px) + 58px);',
        '  bottom: calc(env(safe-area-inset-bottom, 0px) + 94px);',
        '  right: 0;',
        '  width: 22px;',
        '  box-sizing: border-box;',
        '  background: transparent;',
        '  border: 0;',
        '  box-shadow: none;',
        '  pointer-events: none;',
        '  touch-action: none !important;',
        '  -webkit-touch-callout: none !important;',
        '  -webkit-user-select: none;',
        '  user-select: none;',
        '}',
        '#gptweb-scrollbar.gptweb-interactive {',
        '  pointer-events: auto;',
        '}',
        '#gptweb-scrollbar-thumb {',
        '  position: absolute;',
        '  top: 0;',
        '  right: 2px;',
        '  width: 5px;',
        '  min-height: 42px;',
        '  border-radius: 999px;',
        '  background: #0a84ff;',
        '  box-shadow: none;',
        '  opacity: 0;',
        '  transition: opacity 150ms ease, width 120ms ease;',
        '  will-change: transform, height;',
        '}',
        '#gptweb-scrollbar.gptweb-visible #gptweb-scrollbar-thumb {',
        '  opacity: 0.94;',
        '}',
        '#gptweb-scrollbar.gptweb-fast #gptweb-scrollbar-thumb {',
        '  width: 8px;',
        '  opacity: 1;',
        '}'
      ].join('\\n');
      (document.head || document.documentElement).appendChild(style);

      var scrollbar = null;
      var thumb = null;
      var activeScroller = null;
      var barGesture = null;
      var updateScheduled = false;
      var hideTimer = 0;
      var inertiaFrame = 0;
      var pendingContentTouch = null;
      var lastContentSelectionAt = 0;

      function parentElementAcrossShadowDOM(element) {
        if (!element) return null;
        if (element.parentElement) return element.parentElement;
        var root = element.getRootNode ? element.getRootNode() : null;
        return root && root.host ? root.host : null;
      }

      function scrollRange(element) {
        return element ? Math.max(0, element.scrollHeight - element.clientHeight) : 0;
      }

      function overflowKind(element) {
        var value = window.getComputedStyle(element).overflowY;
        return value || 'visible';
      }

      function isVisible(element) {
        if (!element || element.nodeType !== 1 || !element.isConnected) return false;
        var rect = element.getBoundingClientRect();
        var viewportHeight = window.innerHeight || document.documentElement.clientHeight;
        var viewportWidth = window.innerWidth || document.documentElement.clientWidth;
        return rect.height >= 96 &&
          rect.width >= 120 &&
          rect.bottom > 0 &&
          rect.right > 0 &&
          rect.top < viewportHeight &&
          rect.left < viewportWidth;
      }

      function isScroller(element) {
        if (!element || scrollRange(element) < 12) return false;
        var root = document.scrollingElement || document.documentElement;
        if (element === root) return true;
        if (!isVisible(element)) return false;
        var overflow = overflowKind(element);
        var role = element.getAttribute('role') || '';
        var name = String(element.className || '');
        return overflow === 'auto' ||
          overflow === 'scroll' ||
          overflow === 'overlay' ||
          overflow === 'hidden' ||
          overflow === 'clip' ||
          element.tagName === 'MAIN' ||
          role === 'main' ||
          role === 'dialog' ||
          name.indexOf('overflow') !== -1 ||
          element.hasAttribute('data-scroll-root');
      }

      function isNativeScroller(element) {
        var overflow = overflowKind(element);
        return overflow === 'auto' ||
          overflow === 'scroll' ||
          overflow === 'overlay';
      }

      function brokenScrollerScore(element) {
        if (!isScroller(element) || isNativeScroller(element)) return -1;
        var rect = element.getBoundingClientRect();
        var role = element.getAttribute('role') || '';
        var name = String(element.className || '');
        var viewportArea = Math.max(1, window.innerWidth * window.innerHeight);
        var score = Math.min(100, rect.width * rect.height / viewportArea * 100);
        score += Math.min(45, scrollRange(element) / 160);
        if (element.tagName === 'MAIN' || role === 'main') score += 80;
        if (role === 'dialog') score += 45;
        if (element.hasAttribute('data-scroll-root')) score += 70;
        if (name.indexOf('overflow') !== -1) score += 35;
        return score;
      }

      function nearestScroller(start) {
        var element = start && start.nodeType === 1 ? start : start && start.parentElement;
        var brokenCandidate = null;
        var brokenScore = -1;
        var depth = 0;
        while (element && depth < 40) {
          if (isScroller(element)) {
            if (isNativeScroller(element)) return element;
            var score = brokenScrollerScore(element);
            if (score > brokenScore) {
              brokenCandidate = element;
              brokenScore = score;
            }
          }
          element = parentElementAcrossShadowDOM(element);
          depth += 1;
        }
        return brokenCandidate;
      }

      function pointInside(rect, x, y) {
        return x >= rect.left && x <= rect.right &&
          y >= rect.top && y <= rect.bottom;
      }

      function fallbackScroller(start, x, y) {
        var selector = [
          '[data-scroll-root]',
          '[data-testid*="conversation"]',
          '[data-testid*="thread"]',
          '[data-testid*="message"]',
          '[class*="overflow-y-auto"]',
          '[class*="overflow-auto"]',
          '[role="main"]',
          '[role="dialog"]',
          'main'
        ].join(',');
        var nodes = document.querySelectorAll(selector);
        var best = null;
        var bestScore = -1;
        var count = Math.min(nodes.length, 400);

        for (var index = 0; index < count; index += 1) {
          var node = nodes[index];
          if (!isScroller(node)) continue;
          var rect = node.getBoundingClientRect();
          var containsStart = start && node.contains(start);
          var containsPoint = pointInside(rect, x, y);
          if (!containsStart && !containsPoint) continue;

          var score = 0;
          if (containsStart) score += 140;
          if (containsPoint) score += 80;
          if (isNativeScroller(node)) score += 90;
          score += Math.max(0, brokenScrollerScore(node));
          if (score > bestScore) {
            best = node;
            bestScore = score;
          }
        }
        return best;
      }

      function findScroller(start, x, y) {
        var nested = nearestScroller(start) || fallbackScroller(start, x, y);
        if (nested) return nested;
        var root = document.scrollingElement || document.documentElement;
        return root && scrollRange(root) >= 12 ? root : null;
      }

      function defaultScroller() {
        var selector = [
          '[data-scroll-root]',
          '[data-testid*="conversation"]',
          '[data-testid*="thread"]',
          '[data-testid*="message"]',
          '[class*="overflow-y-auto"]',
          '[class*="overflow-auto"]',
          '[role="main"]',
          '[role="dialog"]',
          'main'
        ].join(',');
        var nodes = document.querySelectorAll(selector);
        var best = null;
        var bestScore = -1;
        var viewportArea = Math.max(1, window.innerWidth * window.innerHeight);
        var count = Math.min(nodes.length, 300);

        for (var index = 0; index < count; index += 1) {
          var node = nodes[index];
          if (!isScroller(node)) continue;
          var rect = node.getBoundingClientRect();
          var role = node.getAttribute('role') || '';
          var score = Math.min(140, (rect.width * rect.height / viewportArea) * 140);
          score += Math.min(45, scrollRange(node) / 180);
          if (node.tagName === 'MAIN' || role === 'main') score += 70;
          if (role === 'dialog') score += 35;
          if (rect.width > window.innerWidth * 0.55) score += 25;
          if (score > bestScore) {
            best = node;
            bestScore = score;
          }
        }

        var root = document.scrollingElement || document.documentElement;
        if (!best && isScroller(root)) best = root;
        return best;
      }

      function ensureScrollbar() {
        if (scrollbar && scrollbar.isConnected) return true;
        if (!document.body) return false;

        scrollbar = document.createElement('div');
        scrollbar.id = 'gptweb-scrollbar';
        scrollbar.setAttribute('aria-hidden', 'true');
        thumb = document.createElement('div');
        thumb.id = 'gptweb-scrollbar-thumb';
        scrollbar.appendChild(thumb);
        document.body.appendChild(scrollbar);

        scrollbar.addEventListener('touchstart', beginBarGesture, {
          passive: false
        });
        scrollbar.addEventListener('touchmove', continueBarGesture, {
          passive: false
        });
        scrollbar.addEventListener('touchend', endBarGesture, {
          passive: false
        });
        scrollbar.addEventListener('touchcancel', cancelBarGesture, {
          passive: false
        });
        return true;
      }

      function setActiveScroller(element, shouldReveal) {
        if (!isScroller(element)) return false;
        activeScroller = element;
        scheduleUpdate();
        if (shouldReveal) revealScrollbar();
        return true;
      }

      function ensureActiveScroller() {
        if (isScroller(activeScroller)) return activeScroller;
        activeScroller = defaultScroller();
        return activeScroller;
      }

      function barHeight() {
        if (!scrollbar) return 0;
        return scrollbar.clientHeight || scrollbar.getBoundingClientRect().height || 0;
      }

      function thumbMetrics(scroller) {
        var height = barHeight();
        var maximum = scrollRange(scroller);
        if (height <= 0 || maximum <= 0) return null;
        var thumbHeight = Math.max(
          42,
          Math.min(height, height * scroller.clientHeight / scroller.scrollHeight)
        );
        var travel = Math.max(1, height - thumbHeight);
        var top = Math.max(0, Math.min(
          travel,
          scroller.scrollTop / maximum * travel
        ));
        return {
          height: height,
          maximum: maximum,
          thumbHeight: thumbHeight,
          travel: travel,
          top: top
        };
      }

      function updateScrollbar() {
        updateScheduled = false;
        if (!ensureScrollbar()) return;
        var scroller = ensureActiveScroller();
        var metrics = scroller ? thumbMetrics(scroller) : null;
        if (!metrics) {
          scrollbar.classList.remove('gptweb-visible');
          scrollbar.classList.remove('gptweb-interactive');
          return;
        }
        thumb.style.height = metrics.thumbHeight + 'px';
        thumb.style.transform = 'translate3d(0,' + metrics.top + 'px,0)';
      }

      function scheduleUpdate() {
        if (updateScheduled) return;
        updateScheduled = true;
        window.requestAnimationFrame(updateScrollbar);
      }

      function hideScrollbarSoon() {
        if (!scrollbar) return;
        if (hideTimer) window.clearTimeout(hideTimer);
        hideTimer = window.setTimeout(function () {
          hideTimer = 0;
          if (barGesture) return;
          scrollbar.classList.remove('gptweb-visible');
          scrollbar.classList.remove('gptweb-interactive');
          scrollbar.classList.remove('gptweb-fast');
        }, 1400);
      }

      function revealScrollbar() {
        if (!ensureScrollbar()) return;
        scrollbar.classList.add('gptweb-visible');
        scrollbar.classList.add('gptweb-interactive');
        scheduleUpdate();
        hideScrollbarSoon();
      }

      function cancelInertia() {
        if (!inertiaFrame) return;
        window.cancelAnimationFrame(inertiaFrame);
        inertiaFrame = 0;
      }

      function prepareScrollTarget(scroller) {
        if (!scroller || !scroller.style || !scroller.style.setProperty) {
          return {
            scroller: scroller,
            persistent: true,
            saved: []
          };
        }
        var overflow = overflowKind(scroller);
        var properties = [
          'overflow-y',
          '-webkit-overflow-scrolling',
          'overscroll-behavior-y',
          'touch-action',
          'min-height'
        ];
        var saved = properties.map(function (name) {
          return {
            name: name,
            value: scroller.style.getPropertyValue ?
              scroller.style.getPropertyValue(name) :
              String(scroller.style[name] || ''),
            priority: scroller.style.getPropertyPriority ?
              scroller.style.getPropertyPriority(name) :
              ''
          };
        });
        scroller.style.setProperty('overflow-y', 'auto', 'important');
        scroller.style.setProperty(
          '-webkit-overflow-scrolling',
          'auto',
          'important'
        );
        scroller.style.setProperty(
          'overscroll-behavior-y',
          'contain',
          'important'
        );
        scroller.style.setProperty('touch-action', 'pan-y', 'important');
        scroller.style.setProperty('min-height', '0', 'important');
        void scroller.offsetHeight;
        return {
          scroller: scroller,
          persistent: overflow === 'hidden' || overflow === 'clip',
          saved: saved
        };
      }

      function restoreScrollTarget(prepared) {
        if (!prepared || prepared.persistent || !prepared.scroller) return;
        if (barGesture && barGesture.scroller === prepared.scroller) {
          window.setTimeout(function () {
            restoreScrollTarget(prepared);
          }, 500);
          return;
        }
        var style = prepared.scroller.style;
        prepared.saved.forEach(function (entry) {
          if (entry.value) {
            style.setProperty(entry.name, entry.value, entry.priority);
          } else if (style.removeProperty) {
            style.removeProperty(entry.name);
          } else {
            style[entry.name] = '';
          }
        });
        void prepared.scroller.offsetHeight;
      }

      function beginBarGesture(event) {
        if (event.touches.length !== 1) return;
        var prepared = prepareScrollTarget(ensureActiveScroller());
        var scroller = prepared.scroller;
        var metrics = scroller ? thumbMetrics(scroller) : null;
        if (!metrics) {
          restoreScrollTarget(prepared);
          return;
        }

        var touch = event.touches[0];
        cancelInertia();
        if (hideTimer) {
          window.clearTimeout(hideTimer);
          hideTimer = 0;
        }
        barGesture = {
          startY: touch.clientY,
          lastY: touch.clientY,
          lastTime: Date.now(),
          startTop: scroller.scrollTop,
          maximum: metrics.maximum,
          travel: metrics.travel,
          scroller: scroller,
          fast: false,
          moved: false,
          velocity: 0,
          longPressTimer: 0,
          prepared: prepared
        };
        barGesture.longPressTimer = window.setTimeout(function () {
          if (!barGesture || barGesture.moved) return;
          barGesture.fast = true;
          scrollbar.classList.add('gptweb-fast');
          revealScrollbar();
        }, 360);
        event.preventDefault();
        event.stopPropagation();
        revealScrollbar();
      }

      function continueBarGesture(event) {
        if (!barGesture || event.touches.length !== 1) return;
        var touch = event.touches[0];
        var now = Date.now();
        var totalDelta = touch.clientY - barGesture.startY;
        var stepDelta = barGesture.lastY - touch.clientY;
        var elapsed = Math.max(1, now - barGesture.lastTime);

        if (!barGesture.fast && Math.abs(totalDelta) > 7) {
          barGesture.moved = true;
          if (barGesture.longPressTimer) {
            window.clearTimeout(barGesture.longPressTimer);
            barGesture.longPressTimer = 0;
          }
        }

        var next;
        if (barGesture.fast) {
          next = barGesture.startTop +
            totalDelta / barGesture.travel * barGesture.maximum;
        } else {
          next = barGesture.scroller.scrollTop + stepDelta;
          var instantaneousVelocity = stepDelta / elapsed;
          barGesture.velocity =
            barGesture.velocity * 0.72 + instantaneousVelocity * 0.28;
        }
        barGesture.scroller.scrollTop = Math.max(
          0,
          Math.min(barGesture.maximum, next)
        );
        barGesture.lastY = touch.clientY;
        barGesture.lastTime = now;
        event.preventDefault();
        event.stopPropagation();
        scheduleUpdate();
      }

      function startInertia(scroller, velocity) {
        if (!scroller || Math.abs(velocity) < 0.08) return;
        var previous = Date.now();
        function step() {
          var now = Date.now();
          var elapsed = Math.min(32, Math.max(1, now - previous));
          previous = now;
          var maximum = scrollRange(scroller);
          var current = scroller.scrollTop;
          var next = Math.max(0, Math.min(maximum, current + velocity * elapsed));
          scroller.scrollTop = next;
          velocity *= Math.pow(0.94, elapsed / 16);
          scheduleUpdate();
          revealScrollbar();
          if (Math.abs(velocity) >= 0.025 &&
              next > 0 && next < maximum) {
            inertiaFrame = window.requestAnimationFrame(step);
          } else {
            inertiaFrame = 0;
            hideScrollbarSoon();
          }
        }
        inertiaFrame = window.requestAnimationFrame(step);
      }

      function finishBarGesture(event, cancelled) {
        if (!barGesture) return;
        var finished = barGesture;
        if (finished.longPressTimer) {
          window.clearTimeout(finished.longPressTimer);
        }
        barGesture = null;
        scrollbar.classList.remove('gptweb-fast');
        if (!cancelled && !finished.fast) {
          startInertia(finished.scroller, finished.velocity);
        }
        window.setTimeout(function () {
          restoreScrollTarget(finished.prepared);
        }, 1600);
        if (event.cancelable) event.preventDefault();
        event.stopPropagation();
        scheduleUpdate();
        hideScrollbarSoon();
      }

      function endBarGesture(event) {
        finishBarGesture(event, false);
      }

      function cancelBarGesture(event) {
        finishBarGesture(event, true);
      }

      document.addEventListener('touchstart', function (event) {
        if (scrollbar && scrollbar.contains(event.target)) return;
        if (event.touches.length !== 1) return;
        var touch = event.touches[0];
        var scroller = findScroller(
          event.target,
          touch.clientX,
          touch.clientY
        );
        if (!scroller) {
          pendingContentTouch = null;
          return;
        }
        setActiveScroller(scroller, false);
        lastContentSelectionAt = Date.now();
        pendingContentTouch = {
          startX: touch.clientX,
          startY: touch.clientY
        };
      }, {
        capture: true,
        passive: true
      });

      document.addEventListener('touchmove', function (event) {
        if (!pendingContentTouch || event.touches.length !== 1) return;
        var touch = event.touches[0];
        var deltaX = touch.clientX - pendingContentTouch.startX;
        var deltaY = touch.clientY - pendingContentTouch.startY;
        if (Math.abs(deltaY) < 5 ||
            Math.abs(deltaY) <= Math.abs(deltaX)) return;
        pendingContentTouch = null;
        revealScrollbar();
      }, {
        capture: true,
        passive: true
      });

      function clearPendingContentTouch() {
        pendingContentTouch = null;
      }

      document.addEventListener('touchend', clearPendingContentTouch, {
        capture: true,
        passive: true
      });
      document.addEventListener('touchcancel', clearPendingContentTouch, {
        capture: true,
        passive: true
      });

      document.addEventListener('scroll', function (event) {
        var target = event.target;
        var root = document.scrollingElement || document.documentElement;
        if (target === document || target === document.documentElement) {
          target = root;
        }
        var preserveNestedTarget = activeScroller &&
          activeScroller !== root &&
          target === root &&
          (barGesture || Date.now() - lastContentSelectionAt < 2400);
        if (!preserveNestedTarget && isScroller(target)) {
          activeScroller = target;
        }
        revealScrollbar();
      }, {
        capture: true,
        passive: true
      });

      var observer = new MutationObserver(function () {
        if (!activeScroller || !activeScroller.isConnected || scrollRange(activeScroller) < 12) {
          activeScroller = null;
        }
        scheduleUpdate();
      });
      observer.observe(document.documentElement, {
        childList: true,
        subtree: true
      });

      window.addEventListener('resize', scheduleUpdate, {
        passive: true
      });
      window.setInterval(scheduleUpdate, 1200);
      ensureScrollbar();
      scheduleUpdate();
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
        persistCurrentURL()
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
        let alert = UIAlertController(title: webView.title ?? "GPT Web", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: webView.title ?? "GPT Web", message: message, preferredStyle: .alert)
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
        let alert = UIAlertController(title: webView.title ?? "GPT Web", message: prompt, preferredStyle: .alert)
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
