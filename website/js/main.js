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
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('visible');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });

    faders.forEach(function (el) { observer.observe(el); });
  } else {
    // Fallback: just show everything
    faders.forEach(function (el) { el.classList.add('visible'); });
  }
})();
