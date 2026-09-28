/* Nostalgex marketing homepage — global script.
   Loaded by index.html, web-tuner.html and support.html, which all share styles.css. */
(function () {
  "use strict";

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- Theme toggle ----------
     The <head> boot script owns the default + first paint; this just flips
     [data-theme] on <html> and remembers the choice. The button shows the
     theme you can switch TO: a sun while dark, a moon while light. */
  var THEME_KEY = "nostalgex-theme-v2";
  var rootEl = document.documentElement;
  var themeToggle = document.getElementById("themeToggle");

  function syncToggle() {
    var dark = rootEl.getAttribute("data-theme") === "dark";
    var label = dark ? "Switch to day mode" : "Switch to night mode";
    themeToggle.setAttribute("aria-pressed", String(dark));
    themeToggle.setAttribute("aria-label", label);
    themeToggle.setAttribute("title", label);
  }

  if (themeToggle) {
    themeToggle.addEventListener("click", function () {
      var next = rootEl.getAttribute("data-theme") === "dark" ? "light" : "dark";
      rootEl.setAttribute("data-theme", next);
      try { localStorage.setItem(THEME_KEY, next); } catch (e) {}
      syncToggle();
    });
    syncToggle();
  }

  /* ---------- Nav scroll state ---------- */
  var nav = document.getElementById("nav");
  if (nav) {
    var onScroll = function () {
      nav.classList.toggle("is-scrolled", window.scrollY > 8);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
  }

  /* ---------- Lineup: generated groups become collapsible bundles ----------
     render-lineup.mjs emits flat .lineup__group blocks (head + grid). Rather
     than fork the generator into <details>, progressively enhance them here. */
  var groups = document.querySelectorAll(".lineup-card .lineup__group");
  groups.forEach(function (group, i) {
    var head = group.querySelector(".lineup__group-head");
    var grid = group.querySelector(".lineup__grid");
    if (!head || !grid) return;

    var marker = document.createElement("span");
    marker.className = "faq-marker";
    marker.setAttribute("aria-hidden", "true");
    head.appendChild(marker);

    var open = i === 0;
    head.setAttribute("role", "button");
    head.setAttribute("tabindex", "0");

    function apply() {
      group.classList.toggle("is-open", open);
      head.setAttribute("aria-expanded", String(open));
      grid.hidden = !open;
    }
    apply();

    head.addEventListener("click", function () {
      open = !open;
      apply();
    });
    head.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
        e.preventDefault();
        open = !open;
        apply();
      }
    });
  });

  /* Bundle / channel counts read from the generated markup, so they never drift. */
  var bundleCount = document.querySelector("[data-lineup-bundles]");
  var channelCount = document.querySelector("[data-lineup-channels]");
  if (bundleCount && groups.length) bundleCount.textContent = String(groups.length);
  if (channelCount) {
    var items = document.querySelectorAll(".lineup-card .lineup__item").length;
    if (items) channelCount.textContent = String(items);
  }

  /* ---------- Reveal on scroll ---------- */
  var revealEls = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window && !reduceMotion) {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -40px 0px" }
    );
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add("is-visible"); });
  }

  /* ---------- FAQ: close others when one opens ---------- */
  var faqs = document.querySelectorAll(".faq-list details");
  faqs.forEach(function (d) {
    d.addEventListener("toggle", function () {
      if (d.open) {
        faqs.forEach(function (other) {
          if (other !== d) other.open = false;
        });
      }
    });
  });

  /* ---------- What's new (changelog dialog) ----------
     Native <dialog>: Escape closes for free; we add backdrop-click close
     and a body scroll lock while it's open. */
  var changelog = document.getElementById("changelogDialog");
  if (changelog) {
    document.querySelectorAll("[data-changelog-open]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        document.body.style.overflow = "hidden";
        changelog.showModal();
        var body = changelog.querySelector(".changelog-body");
        if (body) body.scrollTop = 0;
      });
    });
    document.querySelectorAll("[data-changelog-close]").forEach(function (btn) {
      btn.addEventListener("click", function () { changelog.close(); });
    });
    changelog.addEventListener("click", function (e) {
      /* a click on the dialog element itself (not its children) is the backdrop */
      if (e.target === changelog) changelog.close();
    });
    changelog.addEventListener("close", function () {
      document.body.style.overflow = "";
    });
  }

  /* ---------- Email signup (Resend, via /api/subscribe) ----------
     Same-origin now that this page ships on nostalgex.app. Binds the page's own
     forms (.js-subscribe-form) AND the newsletter form the lineup generator
     drops into the bundle list (.newsletter-form). This is the only subscribe
     handler on this page — scripts/newsletter.js is NOT loaded here. */
  var SUBSCRIBE_URL = "/api/subscribe";

  function pageSource() {
    return window.location.pathname.replace(/\.html$/, "") || "/";
  }

  document.querySelectorAll(".js-subscribe-form, .newsletter-form").forEach(function (form) {
    var input = form.querySelector("input[type='email']");
    var button = form.querySelector("button[type='submit']");
    var msg = form.parentElement.querySelector(".subscribe-msg, .newsletter-msg");
    if (!input || !button) return;

    function say(text, isError) {
      if (!msg) return;
      msg.textContent = text;
      msg.classList.toggle("is-error", !!isError);
    }

    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var email = (input.value || "").trim();
      if (!email || email.indexOf("@") < 1) {
        say("That email doesn't look right. One more try.", true);
        input.focus();
        return;
      }
      button.disabled = true;
      say("Sending...");
      fetch(SUBSCRIBE_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: email, source: pageSource() })
      })
        .then(function (res) {
          if (!res.ok) throw new Error("bad status " + res.status);
          say("You're in. Talk soon.");
          form.reset();
        })
        .catch(function () {
          say("That didn't go through. Give it another shot in a minute.", true);
        })
        .finally(function () {
          button.disabled = false;
        });
    });
  });
})();
