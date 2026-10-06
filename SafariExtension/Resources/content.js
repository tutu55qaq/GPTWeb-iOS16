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
  var active = false;
  var cycleURL = '';
  var repairedScroller = null;
  var repairedURL = '';
  var repairedAt = -Infinity;
  var attempts = 0;
  var deadline = 0;
  var maxAttempts = 12;

  function stopWatching() {
    active = false;
    if (observer) {
      observer.disconnect();
      observer = null;
    }
    if (retryTimer) {
      window.clearTimeout(retryTimer);
      retryTimer = 0;
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

    // Exclude controls and side panels before any synchronous layout read.
    if (element.closest && element.closest(
      '#stage-popover-sidebar, [role="menu"], pre, code, textarea, input, [contenteditable="true"]'
    )) return null;

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

    var best = null;
    var bestInspection = null;
    var bestScore = -1;
    function consider(candidate) {
      var inspection = inspectScroller(candidate);
      if (!inspection) return;
      var score = scrollerScore(
        inspection, focusedCandidates.indexOf(candidate) !== -1
      );
      if (score > bestScore) {
        best = candidate;
        bestInspection = inspection;
        bestScore = score;
      }
    }
    candidates.forEach(consider);
    // A recognized visible message scroller needs no document-wide fallback.
    if (bestInspection && (best.hasAttribute('data-scroll-root') ||
        (bestInspection.native && bestInspection.name.indexOf('overflow') !== -1))) {
      return best;
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
        consider(nodes[index]);
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
    if (document.hidden || attempts >= maxAttempts || Date.now() >= deadline) {
      stopWatching();
      return false;
    }
    attempts += 1;

    var scroller = findScroller();
    if (scroller && repairScroller(scroller)) {
      repairedScroller = scroller;
      repairedURL = String(window.location.href || '');
      repairedAt = Date.now();
      stopWatching();
      return true;
    }

    if (!observer && typeof MutationObserver === 'function') {
      var container = document.querySelector('main, [role="main"]') ||
        document.body;
      if (container) {
        observer = new MutationObserver(function () {
          scheduleRetry();
        });
        observer.observe(container, { childList: true, subtree: true });
      }
    }

    scheduleRetry();
    return false;
  }

  function scheduleRetry() {
    if (!active || retryTimer || document.hidden) return;
    var remaining = deadline - Date.now();
    if (remaining <= 0 || attempts >= maxAttempts) {
      stopWatching();
      return;
    }
    // One timer shared by mutations and fallback polling. Streaming DOM updates
    // cannot accelerate scans or extend the repair window.
    var delay = Math.min(880, 220 * Math.pow(2, attempts - 1), remaining);
    retryTimer = window.setTimeout(attemptRepair, delay);
  }

  function armRepair() {
    if (document.hidden || document.readyState === 'loading') return false;
    var url = String(window.location.href || '');
    if (active && cycleURL === url) return false;
    if (repairedScroller && repairedScroller.isConnected &&
        repairedURL === url && Date.now() - repairedAt < 500 &&
        repairedScroller.getAttribute('data-gptweb-scroll-repaired') === 'true') {
      return true;
    }
    stopWatching();
    active = true;
    cycleURL = url;
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

  window.addEventListener('pageshow', function (event) {
    if (event.persisted) repairedScroller = null;
    armRepair();
  }, { passive: true });
  window.addEventListener('popstate', armRepair, { passive: true });
  window.addEventListener('pagehide', stopWatching, { passive: true });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) {
      stopWatching();
    } else {
      repairedScroller = null;
      armRepair();
    }
  });
})();
