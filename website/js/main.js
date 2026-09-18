/* ============================================
   Dusk Marketing Website — main.js
   ============================================ */

(function () {
  'use strict';

  // --- Theme Toggle ---
  var THEME_KEY = 'dusk-theme';
  var html = document.documentElement;
  var toggle = document.getElementById('theme-switch');

  function getSystemTheme() {
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }

  function applyTheme(theme) {
    html.setAttribute('data-theme', theme);
    toggle.setAttribute('aria-checked', theme === 'dark' ? 'true' : 'false');
  }

  // Init: check saved preference, fall back to system
  var saved = localStorage.getItem(THEME_KEY);
  applyTheme(saved || getSystemTheme());

  // Click handler — toggle between themes
  toggle.addEventListener('click', function () {
    var current = html.getAttribute('data-theme');
    var next = current === 'dark' ? 'light' : 'dark';
    localStorage.setItem(THEME_KEY, next);
    applyTheme(next);
  });

  // Keyboard handler for accessibility
  toggle.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      toggle.click();
    }
  });

  // Listen for system theme changes (only if no saved preference)
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function (e) {
    if (!localStorage.getItem(THEME_KEY)) {
      applyTheme(e.matches ? 'dark' : 'light');
    }
  });

  // --- Footer Year ---
  document.getElementById('year').textContent = new Date().getFullYear();

  // --- Scroll Animations ---
  var faders = document.querySelectorAll('.fade-in');

  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      // Stagger whatever enters together in document order, so a batch of
      // cards always cascades top-left to bottom-right and a lone card that
      // scrolls in later shows up right away.
      var revealed = entries
        .filter(function (entry) { return entry.isIntersecting; })
        .map(function (entry) { return entry.target; })
        .sort(function (a, b) {
          return a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1;
        });

      revealed.forEach(function (el, i) {
        observer.unobserve(el);
        if (i > 0) {
          el.style.transitionDelay = (i * 0.08) + 's';
          // Drop the delay once revealed so hover effects aren't held back.
          el.addEventListener('transitionend', function () {
            el.style.transitionDelay = '';
          }, { once: true });
        }
        el.classList.add('visible');
      });
    }, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });

    faders.forEach(function (el) { observer.observe(el); });
  } else {
    // Fallback: just show everything
    faders.forEach(function (el) { el.classList.add('visible'); });
  }
})();
