/* Notices from the admin on the listener page. A listener can't close or remove any of them.
 *   poll ─> show(now.notices) ─> two kinds, told apart by `style`:
 *     "banner" (shown as "permanent"): a card at the top of the page that stays while the admin keeps it up.
 *              Several of them take turns, one at a time, cross-fading; dots under the card show whose turn it is.
 *     "popup"  (shown as "a notification"): glides in at the top, stays for about as long as it takes to read,
 *              glides out. Each browser sees it once; several wait their turn.
 * Everything moves with CSS transitions (notices.css). Every text goes in as textContent, so nothing the
 * admin types can become markup. */
(function () {
  const root = document.querySelector('#notices');
  const KEY = 'radio.notices.seen';
  const FADE = 750;                  // = the CSS transition time
  const slides = new Map();          // permanent: id -> card
  const queue = [];                  // notifications waiting for their turn
  let seen = new Set();              // notification ids this browser has already shown
  let order = [];                    // permanent ids, newest first
  let shownId = 0;                   // the permanent card on screen
  let turn = 0;                      // timer of the next permanent card
  let toast = null;                  // the notification on screen
  let toastId = 0;
  let toastTimer = 0;

  try { seen = new Set(JSON.parse(localStorage.getItem(KEY) || '[]')); } catch { /* private mode */ }
  function remember() { try { localStorage.setItem(KEY, JSON.stringify([...seen])); } catch { /* private mode */ } }

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }

  const inner = el('div', 'notices-in');
  const stage = el('div', 'notice-stage');
  const dots = el('div', 'notice-dots');
  dots.setAttribute('aria-hidden', 'true');
  inner.append(stage, dots);
  root.append(inner);

  // Both kinds use the same body. With no picture, render only the text.
  function build(n, card) {
    const box = el('div', 'notice-body');
    if (n.image) {
      const media = el('img', 'notice-img');
      media.alt = '';
      media.src = '/api/notice/image?id=' + n.id;
      media.addEventListener('error', () => { media.remove(); card.classList.add('no-image'); });
      box.append(media);
    } else card.classList.add('no-image');
    const text = el('div', 'notice-text');
    if (n.title) text.append(el('h3', '', n.title));
    if (n.quote_text) {
      const q = el('blockquote', 'notice-quote');
      q.append(el('b', '', n.quote_name || 'یک شنونده'), el('span', '', n.quote_text));
      text.append(q);
    }
    if (n.body) text.append(el('p', '', n.body));
    box.append(text);
    return box;
  }

  // about as long as it takes to read it
  const holdFor = n => Math.min(14000, Math.max(6000, 4000 + (n.title.length + n.body.length + n.quote_text.length) * 60));

  // ---------- permanent cards ----------
  function paintDots() {
    dots.hidden = order.length < 2;
    dots.replaceChildren(...order.map(id => el('i', id === shownId ? 'on' : '')));
  }

  function showCard(id) {
    shownId = id;
    for (const [k, card] of slides) card.classList.toggle('on', k === id);
    paintDots();
    clearTimeout(turn);
    turn = 0;
    if (order.length > 1 && slides.has(id)) turn = setTimeout(next, +slides.get(id).dataset.hold);
  }

  function next() {
    turn = 0;
    const i = order.indexOf(shownId);
    showCard(order[(i + 1) % order.length]);
  }

  function syncCards(list) {
    const live = list.filter(n => n.style !== 'popup');
    const ids = new Set(live.map(n => n.id));
    for (const [id, card] of slides) {
      if (ids.has(id)) continue;
      card.classList.remove('on');           // fades out, then leaves
      slides.delete(id);
      setTimeout(() => card.remove(), FADE);
    }
    let added = false;
    for (const n of live) {
      if (slides.has(n.id)) continue;
      const card = el('article', 'notice');
      card.dataset.hold = holdFor(n);
      card.append(build(n, card));
      slides.set(n.id, card);
      stage.append(card);
      added = true;
    }
    order = live.map(n => n.id);
    root.classList.toggle('has', order.length > 0);
    if (!order.length) { shownId = 0; clearTimeout(turn); turn = 0; paintDots(); return; }
    if (!slides.has(shownId)) { void stage.offsetWidth; showCard(order[0]); return; }   // reflow first: the fade needs a painted start
    if (added) { paintDots(); if (!turn && order.length > 1) turn = setTimeout(next, +slides.get(shownId).dataset.hold); }
  }

  // ---------- notifications ----------
  function hideToast() {
    clearTimeout(toastTimer);
    const t = toast;
    if (!t) return;
    t.classList.remove('on');
    setTimeout(() => {
      t.remove();
      if (toast === t) { toast = null; toastId = 0; pump(); }
    }, FADE + 50);
  }

  function pump() {
    if (toast || !queue.length) return;
    const n = queue.shift();
    toastId = n.id;
    toast = el('div', 'notice-toast');
    const card = el('article', 'notice');
    card.append(build(n, card));
    toast.append(card);
    (root.closest('[data-notice-slot]') || document.body).append(toast);
    void toast.offsetWidth;
    toast.classList.add('on');
    seen.add(n.id);
    seen = new Set([...seen].slice(-500));
    remember();
    toastTimer = setTimeout(hideToast, holdFor(n) + 2000);
  }

  function syncToasts(list) {
    const live = new Set(list.map(n => n.id));
    for (let i = queue.length - 1; i >= 0; i--) if (!live.has(queue[i].id)) queue.splice(i, 1);
    if (toast && !live.has(toastId)) hideToast();           // the admin took it down
    // Notice IDs are global and never reused. Keep seen IDs when changing channels.
    for (const n of list.slice().reverse()) {
      if (n.style === 'popup' && !seen.has(n.id) && n.id !== toastId && !queue.some(q => q.id === n.id)) queue.push(n);
    }
    pump();
  }

  function show(list) {
    list = list || [];
    syncCards(list);
    syncToasts(list);
  }

  window.RadioNotices = { show };
})();
