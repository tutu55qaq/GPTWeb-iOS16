(function () {
  var hostname = String(window.location.hostname || '').toLowerCase();
  var isChatGPTDocument = hostname === 'chatgpt.com' ||
    hostname.slice(-12) === '.chatgpt.com' ||
    hostname === 'chat.openai.com';
  if (!isChatGPTDocument) return;
  if (window.__gptwebWorkRepairDotInstalled) return;
  window.__gptwebWorkRepairDotInstalled = true;

  var style = document.createElement('style');
  style.id = 'gptweb-work-repair-dot-style';
  style.textContent = [
    'html { -webkit-text-size-adjust: 100%; }',
    '@supports (-webkit-touch-callout: none) {',
    '  textarea, input:not([type="checkbox"]):not([type="radio"]), [contenteditable="true"] {',
    '    font-size: 16px !important;',
    '  }',
    '  button, a, [role="button"] { touch-action: manipulation; }',
    '}',
    '#gptweb-work-repair-dot {',
    '  position: fixed;',
    '  z-index: 2147483646;',
    '  top: calc(env(safe-area-inset-top, 0px) + 56px);',
    '  right: 7px;',
    '  width: 30px;',
    '  height: 30px;',
    '  border: 0;',
    '  background: transparent;',
    '  box-shadow: none;',
    '  opacity: 0;',
    '  pointer-events: none;',
    '  touch-action: none !important;',
    '  -webkit-touch-callout: none !important;',
    '  -webkit-user-select: none;',
    '  user-select: none;',
    '  transition: opacity 140ms ease;',
    '}',
    '#gptweb-work-repair-dot::before {',
    '  content: "";',
    '  position: absolute;',
    '  top: 50%;',
    '  left: 50%;',
    '  width: 9px;',
    '  height: 9px;',
    '  margin: -4.5px 0 0 -4.5px;',
    '  border-radius: 50%;',
    '  background: #0a84ff;',
    '  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.24);',
    '  transform: scale(1);',
    '  transition: transform 140ms ease, box-shadow 140ms ease;',
    '}',
    '#gptweb-work-repair-dot.gptweb-visible {',
    '  opacity: 0.96;',
    '  pointer-events: auto;',
    '}',
    '#gptweb-work-repair-dot.gptweb-pressing::before {',
    '  transform: scale(1.45);',
    '}',
    '#gptweb-work-repair-dot.gptweb-repaired::before {',
    '  transform: scale(1.7);',
    '  box-shadow: 0 0 0 5px rgba(10, 132, 255, 0.18);',
    '}'
  ].join('\n');
  (document.head || document.documentElement).appendChild(style);

  var dot = null;
  var activeScroller = null;
  var pendingContentTouch = null;
  var press = null;
  var hideTimer = 0;
  var lastContentSelectionAt = 0;

  function parentElementAcrossShadowDOM(element) {
    if (!element) return null;
    if (element.parentElement) return element.parentElement;
    var root = element.getRootNode ? element.getRootNode() : null;
    return root && root.host ? root.host : null;
  }

  function scrollRange(element) {
    return element ?
      Math.max(0, element.scrollHeight - element.clientHeight) :
      0;
  }

  function overflowKind(element) {
    var value = window.getComputedStyle(element).overflowY;
    return value || 'visible';
  }

  function isVisible(element) {
    if (!element || element.nodeType !== 1 || !element.isConnected) {
      return false;
    }
    var rect = element.getBoundingClientRect();
    var viewportHeight =
      window.innerHeight || document.documentElement.clientHeight;
    var viewportWidth =
      window.innerWidth || document.documentElement.clientWidth;
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
    var viewportArea = Math.max(
      1,
      window.innerWidth * window.innerHeight
    );
    var score = Math.min(
      100,
      rect.width * rect.height / viewportArea * 100
    );
    score += Math.min(45, scrollRange(element) / 160);
    if (element.tagName === 'MAIN' || role === 'main') score += 80;
    if (role === 'dialog') score += 45;
    if (element.hasAttribute('data-scroll-root')) score += 70;
    if (name.indexOf('overflow') !== -1) score += 35;
    return score;
  }

  function nearestScroller(start) {
    var element = start && start.nodeType === 1 ?
      start :
      start && start.parentElement;
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
    var nested = nearestScroller(start) ||
      fallbackScroller(start, x, y);
    if (nested) return nested;
    var root = document.scrollingElement || document.documentElement;
    return root && scrollRange(root) >= 12 ? root : null;
  }

  function ensureDot() {
    if (dot && dot.isConnected) return true;
    if (!document.body) return false;
    dot = document.createElement('div');
    dot.id = 'gptweb-work-repair-dot';
    dot.setAttribute('role', 'button');
    dot.setAttribute('aria-label', '修复 Work 滚动');
    document.body.appendChild(dot);
    dot.addEventListener('touchstart', beginPress, {
      passive: false
    });
    dot.addEventListener('touchmove', movePress, {
      passive: false
    });
    dot.addEventListener('touchend', endPress, {
      passive: false
    });
    dot.addEventListener('touchcancel', cancelPress, {
      passive: false
    });
    return true;
  }

  function isRepaired(element) {
    return element &&
      element.getAttribute('data-gptweb-scroll-repaired') === 'true';
  }

  function hideDot() {
    if (!dot || press) return;
    dot.classList.remove('gptweb-visible');
    dot.classList.remove('gptweb-pressing');
    dot.classList.remove('gptweb-repaired');
  }

  function hideDotSoon(delay) {
    if (hideTimer) window.clearTimeout(hideTimer);
    hideTimer = window.setTimeout(function () {
      hideTimer = 0;
      hideDot();
    }, delay);
  }

  function revealDot() {
    if (!activeScroller || isRepaired(activeScroller)) {
      hideDot();
      return;
    }
    if (!ensureDot()) return;
    dot.classList.add('gptweb-visible');
    hideDotSoon(1800);
  }

  function repairScroller(element) {
    if (!element || !element.style || !element.style.setProperty) {
      return false;
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
    activeScroller = element;
    return true;
  }

  function clearPressTimer() {
    if (!press || !press.timer) return;
    window.clearTimeout(press.timer);
    press.timer = 0;
  }

  function beginPress(event) {
    if (event.touches.length !== 1 ||
        !activeScroller ||
        isRepaired(activeScroller)) {
      return;
    }
    if (hideTimer) {
      window.clearTimeout(hideTimer);
      hideTimer = 0;
    }
    var touch = event.touches[0];
    press = {
      startX: touch.clientX,
      startY: touch.clientY,
      repaired: false,
      timer: 0
    };
    dot.classList.add('gptweb-pressing');
    press.timer = window.setTimeout(function () {
      if (!press) return;
      press.timer = 0;
      if (!repairScroller(activeScroller)) return;
      press.repaired = true;
      dot.classList.remove('gptweb-pressing');
      dot.classList.add('gptweb-repaired');
    }, 360);
    event.preventDefault();
    event.stopPropagation();
  }

  function movePress(event) {
    if (!press || event.touches.length !== 1) return;
    var touch = event.touches[0];
    var deltaX = touch.clientX - press.startX;
    var deltaY = touch.clientY - press.startY;
    if (!press.repaired &&
        Math.sqrt(deltaX * deltaX + deltaY * deltaY) > 14) {
      clearPressTimer();
      dot.classList.remove('gptweb-pressing');
    }
    event.preventDefault();
    event.stopPropagation();
  }

  function finishPress(event) {
    if (!press) return;
    var repaired = press.repaired;
    clearPressTimer();
    press = null;
    dot.classList.remove('gptweb-pressing');
    if (repaired) {
      hideDotSoon(320);
    } else {
      hideDotSoon(700);
    }
    if (event.cancelable) event.preventDefault();
    event.stopPropagation();
  }

  function endPress(event) {
    finishPress(event);
  }

  function cancelPress(event) {
    finishPress(event);
  }

  document.addEventListener('touchstart', function (event) {
    if (dot && dot.contains(event.target)) return;
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
    activeScroller = scroller;
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
        Math.abs(deltaY) <= Math.abs(deltaX)) {
      return;
    }
    pendingContentTouch = null;
    revealDot();
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
      (press || Date.now() - lastContentSelectionAt < 2400);
    if (!preserveNestedTarget && isScroller(target)) {
      activeScroller = target;
    }
  }, {
    capture: true,
    passive: true
  });

  var observer = new MutationObserver(function () {
    if (!activeScroller ||
        !activeScroller.isConnected ||
        scrollRange(activeScroller) < 12) {
      activeScroller = null;
      hideDot();
    }
  });
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true
  });

  ensureDot();
})();
