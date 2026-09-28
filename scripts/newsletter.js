/**
 * Nostalgex marketing-site newsletter forms + scroll-triggered signup bar.
 * Attach to any block with [data-newsletter]; optional #newsletter-bar at end of body.
 */
(function () {
  const SUBSCRIBED_KEY = 'nostalgex_newsletter_subscribed';
  const BAR_DISMISSED_KEY = 'nostalgex_newsletter_bar_dismissed';

  function isSubscribed() {
    try {
      return localStorage.getItem(SUBSCRIBED_KEY) === '1';
    } catch {
      return false;
    }
  }

  function markSubscribed() {
    try {
      localStorage.setItem(SUBSCRIBED_KEY, '1');
    } catch {
      /* ignore */
    }
    hideStickyBar();
    document.querySelectorAll('[data-newsletter]').forEach((root) => {
      root.classList.add('is-subscribed');
    });
  }

  function hideStickyBar() {
    const bar = document.getElementById('newsletter-bar');
    if (!bar) return;
    bar.classList.remove('is-visible');
    bar.hidden = true;
  }

  function pageSource() {
    const path = window.location.pathname.replace(/\.html$/, '') || '/';
    return path;
  }

  async function postSubscribe(email) {
    const res = await fetch('/api/subscribe', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, source: pageSource() }),
    });
    const data = await res.json().catch(() => ({}));
    if (res.ok) return { ok: true };
    return { ok: false, error: data.error || 'Subscription failed' };
  }

  function bindNewsletter(root) {
    const form = root.querySelector('.newsletter-form');
    const msg = root.querySelector('.newsletter-msg');
    const submitBtn = form?.querySelector('button[type="submit"]');
    const emailInput = form?.querySelector('input[type="email"]');
    if (!form || !msg || !submitBtn || !emailInput) return;

    if (isSubscribed()) {
      root.classList.add('is-subscribed');
      msg.textContent = "YOU'RE ON THE LIST";
      msg.className = 'newsletter-msg ok';
      return;
    }

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      msg.textContent = '';
      msg.className = 'newsletter-msg';

      const email = (emailInput.value || '').trim();
      if (!email) {
        msg.textContent = 'ENTER AN EMAIL ADDRESS';
        msg.className = 'newsletter-msg err';
        return;
      }

      submitBtn.disabled = true;
      const prevLabel = submitBtn.textContent;
      submitBtn.textContent = 'SENDING...';

      try {
        const result = await postSubscribe(email);
        if (result.ok) {
          msg.textContent = "YOU'RE ON THE LIST — THANKS";
          msg.className = 'newsletter-msg ok';
          emailInput.value = '';
          markSubscribed();
        } else {
          msg.textContent = (result.error || 'SUBSCRIPTION FAILED').toUpperCase();
          msg.className = 'newsletter-msg err';
        }
      } catch {
        msg.textContent = 'CONNECTION FAILED — TRY AGAIN';
        msg.className = 'newsletter-msg err';
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = prevLabel;
      }
    });
  }

  function initStickyBar() {
    const bar = document.getElementById('newsletter-bar');
    if (!bar) return;

    if (isSubscribed()) {
      bar.hidden = true;
      return;
    }

    try {
      if (sessionStorage.getItem(BAR_DISMISSED_KEY) === '1') {
        bar.hidden = true;
        return;
      }
    } catch {
      /* ignore */
    }

    const dismiss = bar.querySelector('.newsletter-bar__dismiss');
    dismiss?.addEventListener('click', () => {
      try {
        sessionStorage.setItem(BAR_DISMISSED_KEY, '1');
      } catch {
        /* ignore */
      }
      bar.classList.remove('is-visible');
      window.setTimeout(() => {
        bar.hidden = true;
      }, 320);
    });

    const threshold = parseInt(bar.dataset.showAfter || '640', 10);
    let shown = false;

    function onScroll() {
      if (shown || window.scrollY < threshold) return;
      shown = true;
      bar.hidden = false;
      document.documentElement.classList.add('has-newsletter-bar');
      requestAnimationFrame(() => bar.classList.add('is-visible'));
    }

    window.addEventListener('scroll', onScroll, { passive: true });
    onScroll();

    const formRoot = bar.querySelector('[data-newsletter]');
    if (formRoot) bindNewsletter(formRoot);
  }

  document.querySelectorAll('[data-newsletter]').forEach((root) => {
    if (!root.closest('#newsletter-bar')) bindNewsletter(root);
  });
  initStickyBar();
})();
