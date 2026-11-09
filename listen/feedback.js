/* Reactions and the message box on the listener page.
 *   tap 🔥 ─> the emoji floats up at once ─> POST /api/react (no numbers anywhere on the page)
 *   poll   ─> show(now) ─> the play's tally grew since the last poll ─> others' emojis float up from the same button
 *   ✉      ─> POST /api/message ─> the admin's inbox (private: nobody else ever sees it)
 * Like likes.js, every timeline is built once inside gsap.matchMedia and only restarted afterwards;
 * with "reduce motion" on, the counts just change. Reactions go to a play id from /api/now, never a file name. */
(function () {
  const $ = s => document.querySelector(s);
  const FA = '۰۱۲۳۴۵۶۷۸۹'; const fa = x => String(x).replace(/\d/g, d => FA[d]);
  const KINDS = ['fire', 'clap', 'wow', 'sleep'];
  const EMOJI = { fire: '🔥', clap: '👏', wow: '🤩', sleep: '😴' };
  const FLOATERS = 3;
  function store(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } }
  function load(k) { try { return localStorage.getItem(k); } catch { return null; } }

  const faces = $('#faces'); const form = $('#msg'); const openBtn = $('#msg-open');
  const text = $('#msg-text'); const name = $('#msg-name'); const count = $('#msg-count'); const send = $('#msg-send');
  const button = Object.fromEntries(KINDS.map(k => [k, faces.querySelector(`[data-kind="${k}"]`)]));
  for (const k of KINDS) button[k].querySelector('.rfx').innerHTML = Array.from({ length: FLOATERS }, () => `<span>${EMOJI[k]}</span>`).join('');

  let play = null; let counts = {}; let motion = null;

  function fullMotion() {
    const pops = {}; const floats = {}; const next = {};
    for (const k of KINDS) {
      const spans = [...button[k].querySelectorAll('.rfx span')];
      gsap.set(spans, { xPercent: -50, yPercent: -50 });
      const e = button[k].querySelector('.e');
      pops[k] = gsap.timeline({ paused: true })
        .to(e, { scale: 1.6, rotation: 'random(-14, 14)', duration: 0.12, ease: 'power2.out' })
        .to(e, { scale: 1, rotation: 0, duration: 0.5, ease: 'elastic.out(1.2, 0.35)' });
      floats[k] = spans.map(f => gsap.timeline({ paused: true })
        .set(f, { x: 0, y: 0, opacity: 0, scale: 0.5, rotation: 0 })
        .to(f, { opacity: 1, scale: 'random(0.9, 1.5)', duration: 0.2, ease: 'back.out(2)' })
        .to(f, { y: 'random(-170, -110)', duration: 1.5, ease: 'sine.out' }, 0)
        .to(f, { x: 'random(-34, 34)', rotation: 'random(-25, 25)', duration: 0.6, ease: 'sine.inOut', repeat: 1, yoyo: true }, 0)
        .to(f, { opacity: 0, duration: 0.5, ease: 'power1.in' }, 1));
      next[k] = 0;
    }
    function rise(k, n) {
      for (let i = 0; i < n; i++) { floats[k][next[k]].delay(i * 0.14).invalidate().restart(true); next[k] = (next[k] + 1) % FLOATERS; }
    }
    return { tap(k) { pops[k].restart(); rise(k, 1); }, others(k, n) { pops[k].restart(); rise(k, Math.min(n, FLOATERS)); } };
  }
  const mm = gsap.matchMedia();
  mm.add({ full: '(prefers-reduced-motion: no-preference)', reduced: '(prefers-reduced-motion: reduce)' }, ctx => {
    motion = ctx.conditions.full ? fullMotion() : { tap() {}, others() {} };
    return () => { motion = null; };
  });
  function teardown(e) { if (e.persisted) return; mm.revert(); window.removeEventListener('pagehide', teardown); }
  window.addEventListener('pagehide', teardown);

  function draw() { faces.hidden = !play; }

  faces.addEventListener('click', async e => {
    const b = e.target.closest('.face');
    if (!b || !play) return;
    const k = b.dataset.kind; const id = play.id;
    counts[k]++; // my own tap is already animated: the poll must not animate it a second time
    if (motion) motion.tap(k);
    try {
      const res = await fetch('/api/react' + window.RadioChannel.query, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ play: id, listener: RadioLikes.listenerId, kind: k }) });
      if (res.status === 429 && typeof window.hint === 'function') window.hint('یه کم آروم‌تر 🙂');
    } catch { /* a lost tap just doesn't reach the others */ }
  });

  /* p = { id, reactions } for the track on air, or null (nothing to react to, e.g. during a live broadcast).
   * reactions is the server's tally for this play only; it is never shown, only its growth is animated. */
  function show(p) {
    if (!p) { play = null; draw(); return; }
    if (play && play.id === p.id) {
      for (const k of KINDS) {
        const more = p.reactions[k] - counts[k];
        if (more > 0 && motion) motion.others(k, more);
        counts[k] = Math.max(counts[k], p.reactions[k]);
      }
    } else counts = { ...p.reactions };
    play = { id: p.id };
    draw();
  }

  name.value = load('radio.name') || '';
  openBtn.addEventListener('click', () => { form.hidden = !form.hidden; if (!form.hidden) text.focus(); });
  $('#msg-cancel').addEventListener('click', () => { form.hidden = true; });
  text.addEventListener('input', () => { count.textContent = text.value.length > 200 ? `${fa(text.value.length)} / ${fa(280)}` : ''; });
  form.addEventListener('submit', async e => {
    e.preventDefault();
    const body = text.value.replace(/\s+/g, ' ').trim();
    if (!body) return;
    send.disabled = true;
    try {
      const res = await fetch('/api/message' + window.RadioChannel.query, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ play: play ? play.id : -1, listener: RadioLikes.listenerId, name: name.value.trim(), text: body }) });
      const r = await res.json().catch(() => ({}));
      if (res.ok) {
        store('radio.name', name.value.trim());
        text.value = ''; count.textContent = ''; form.hidden = true;
        if (typeof window.hint === 'function') window.hint('پیامت رسید، ممنون 🙏');
        openBtn.disabled = true; setTimeout(() => { openBtn.disabled = false; }, 30000);
      } else if (typeof window.hint === 'function') window.hint(r.error || 'نشد بفرستم؛ دوباره امتحان کن');
    } catch { if (typeof window.hint === 'function') window.hint('رادیو در دسترس نیست'); }
    send.disabled = false;
  });

  window.RadioFeedback = { show };
})();
