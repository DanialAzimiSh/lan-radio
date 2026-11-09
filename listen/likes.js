/* The ❤️ on the listener page: one like per listener per play, and its animations (GSAP).
 *
 *   tap  ─> optimistic state ─> like timeline (squash, ring, spark burst, +۱, floating hearts) ─> POST /api/like
 *   poll ─> show(now) ─> others liked since the last poll ─> floating hearts rise for everyone
 *
 * Every timeline is built once, inside gsap.matchMedia (reverted if the motion preference changes), and
 * only restarted afterwards: "random(...)" values plus invalidate() re-roll the directions each time, so a
 * tap never allocates a tween. With "reduce motion" on, the heart only changes colour.
 * Listeners like a play id from /api/now, never a file name, so hidden songs stay nameless.
 */
(function () {
  gsap.registerPlugin(Physics2DPlugin);

  const $ = s => document.querySelector(s);
  const FA = '۰۱۲۳۴۵۶۷۸۹';
  const fa = x => String(x).replace(/\d/g, d => FA[d]);
  const HEART = '<svg viewBox="0 0 24 24"><path d="M12 20.5s-7.5-4.6-9.6-9.2C.9 7.8 3.2 4 6.9 4c2.1 0 3.6 1.1 5.1 3 1.5-1.9 3-3 5.1-3 3.7 0 6 3.8 4.5 7.3-2.1 4.6-9.6 9.2-9.6 9.2z"/></svg>';
  const SPARKS = 20;
  const FLOATERS = 10;

  function store(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } }
  function load(k) { try { return localStorage.getItem(k); } catch { return null; } }

  // an anonymous id kept in this browser; getRandomValues also works on plain-http LAN pages (randomUUID doesn't)
  const listenerId = (() => {
    let id = load('radio.listener');
    if (!/^[A-Za-z0-9-]{8,64}$/.test(id || '')) {
      const b = new Uint8Array(16);
      crypto.getRandomValues(b);
      id = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
      store('radio.listener', id);
    }
    return id;
  })();

  const btn = $('#love');
  const num = $('#love-n');
  const fx = $('#love-fx');
  const heart = btn.querySelector('.heart');
  const beatBox = btn.querySelector('.beat');

  // the burst pieces and the floating hearts are made once and reused
  fx.innerHTML = '<span class="glow"></span><span class="ring"></span><span class="ring"></span><span class="plus">+۱</span>'
    + Array.from({ length: SPARKS }, (_, i) => (i % 3 ? '<span class="spark dot"></span>' : `<span class="spark">${HEART}</span>`)).join('')
    + Array.from({ length: FLOATERS }, () => `<span class="floater">${HEART}</span>`).join('');
  const glow = fx.querySelector('.glow');
  const rings = [...fx.querySelectorAll('.ring')];
  const plus = fx.querySelector('.plus');
  const sparks = [...fx.querySelectorAll('.spark')];
  const floaters = [...fx.querySelectorAll('.floater')];

  let play = null;      // { id, likes, liked } of the track on air
  let pending = false;  // a like is on its way: polls must not undo the optimistic state
  let motion = null;    // the animations for the current motion preference

  function fullMotion() {
    // every effect piece is centred on the button; x/y animations then move it from there
    gsap.set([glow, ...rings, plus, ...sparks, ...floaters], { xPercent: -50, yPercent: -50 });

    // fromTo paints its "from" values as soon as it is built, even paused: immediateRender:false keeps them for when it plays
    const like = gsap.timeline({ paused: true })
      .to(heart, { scaleX: 1.3, scaleY: 0.7, duration: 0.09, ease: 'power1.in' })
      .to(heart, { scaleX: 0.85, scaleY: 1.35, duration: 0.12, ease: 'power2.out' })
      .to(heart, { scaleX: 1, scaleY: 1, duration: 0.8, ease: 'elastic.out(1.2, 0.3)' })
      .fromTo(glow, { scale: 0.6, opacity: 0.85 }, { scale: 2.4, opacity: 0, duration: 0.9, ease: 'power2.out', immediateRender: false }, 0.08)
      .fromTo(rings, { scale: 0.5, opacity: 0.95 }, { scale: 3.2, opacity: 0, duration: 0.8, ease: 'expo.out', stagger: 0.12, immediateRender: false }, 0.1)
      .set(sparks, { x: 0, y: 0, opacity: 1, scale: 'random(0.7, 1.4)', rotation: 'random(-45, 45)' }, 0.12)
      .to(sparks, {
        physics2D: { velocity: 'random(240, 440)', angle: 'random(0, 360)', gravity: 700 },
        rotation: '+=random(-180, 180)', opacity: 0, duration: 1.15, ease: 'power1.in'
      }, 0.12)
      .fromTo(plus, { y: 0, opacity: 0, scale: 0.5 }, { y: -50, opacity: 1, scale: 1, duration: 0.35, ease: 'back.out(3)', immediateRender: false }, 0.1)
      .to(plus, { y: -74, opacity: 0, duration: 0.45, ease: 'power1.in' });

    const unlike = gsap.timeline({ paused: true })
      .to(heart, { scaleX: 0.7, scaleY: 0.7, duration: 0.12, ease: 'power2.in' })
      .to(heart, { scaleX: 1, scaleY: 1, duration: 0.5, ease: 'back.out(3)' });

    // lub-dub, then a rest: a heartbeat while the song is liked
    const beat = gsap.timeline({ paused: true, repeat: -1, repeatDelay: 1.4 })
      .to(beatBox, { scale: 1.14, duration: 0.11, ease: 'power2.out' })
      .to(beatBox, { scale: 1, duration: 0.14, ease: 'power2.in' })
      .to(beatBox, { scale: 1.08, duration: 0.1, ease: 'power2.out' })
      .to(beatBox, { scale: 1, duration: 0.35, ease: 'power2.inOut' });

    const floats = floaters.map((f, i) => gsap.timeline({ paused: true })
      .set(f, { x: 0, y: 0, opacity: 0, scale: 0.4, rotation: 0 })
      .to(f, { opacity: 1, scale: 'random(0.8, 1.35)', duration: 0.25, ease: 'back.out(2)' })
      .to(f, { y: 'random(-270, -180)', duration: 2 + (i % 3) * 0.3, ease: 'sine.out' }, 0)
      .to(f, { x: 'random(-48, 48)', rotation: 'random(-30, 30)', duration: 0.7 + (i % 2) * 0.15, ease: 'sine.inOut', repeat: 2, yoyo: true }, 0)
      .to(f, { opacity: 0, duration: 0.6, ease: 'power1.in' }, 1.5));
    let nextFloat = 0;
    function rise(n) {
      for (let k = 0; k < n; k++) {
        floats[nextFloat].delay(k * 0.18).invalidate().restart(true);
        nextFloat = (nextFloat + 1) % floats.length;
      }
    }

    const pop = gsap.timeline({ paused: true }).fromTo(num, { scale: 1.7 }, { scale: 1, duration: 0.5, ease: 'back.out(3)', immediateRender: false });

    let beating = false;
    return {
      like() { like.invalidate().restart(); rise(3); },
      unlike() { unlike.restart(); },
      others(n) { rise(Math.min(n, 6)); pop.restart(); },
      beat(on) {
        if (on === beating) return;
        beating = on;
        if (on) beat.restart(); else beat.pause(0);
      }
    };
  }

  function reducedMotion() {
    const fade = gsap.timeline({ paused: true }).fromTo(heart, { opacity: 0.4 }, { opacity: 1, duration: 0.3, immediateRender: false });
    return { like() { fade.restart(); }, unlike() { fade.restart(); }, others() {}, beat() {} };
  }

  const mm = gsap.matchMedia();
  mm.add({ full: '(prefers-reduced-motion: no-preference)', reduced: '(prefers-reduced-motion: reduce)' }, ctx => {
    motion = ctx.conditions.full ? fullMotion() : reducedMotion();
    draw();
    return () => { motion = null; };
  });
  // a page kept in the back/forward cache comes back with its animations; any other leave tears them down
  function teardown(e) {
    if (e.persisted) return;
    mm.revert();
    window.removeEventListener('pagehide', teardown);
  }
  window.addEventListener('pagehide', teardown);

  function draw() {
    btn.hidden = num.hidden = !play;
    if (!play) { if (motion) motion.beat(false); return; }
    btn.classList.toggle('on', play.liked);
    btn.setAttribute('aria-pressed', String(play.liked));
    btn.title = play.liked ? 'دیگه دوستش ندارم' : 'دوستش دارم';
    num.textContent = play.likes ? fa(play.likes) : '';
    if (motion) motion.beat(play.liked);
  }

  async function send(id, liked) {
    try {
      const res = await fetch('/api/like' + window.RadioChannel.query, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ play: id, listener: listenerId, liked })
      });
      if (res.status === 429 && typeof window.hint === 'function') window.hint('یه کم آروم‌تر 🙂');
      return res.ok ? await res.json() : null;
    } catch {
      return null;
    }
  }

  btn.addEventListener('click', async () => {
    if (!play || pending) return;
    const want = !play.liked;
    play.liked = want;
    play.likes = Math.max(0, play.likes + (want ? 1 : -1));
    draw();
    if (motion) { if (want) motion.like(); else motion.unlike(); }
    pending = true;
    const r = await send(play.id, want);
    pending = false;
    if (r && play && play.id === r.play) { play.likes = r.likes; play.liked = r.liked; draw(); }
  });

  // called on every poll with the track on air ({id, likes, liked}) or null (live broadcast / nothing)
  function show(p) {
    if (pending && p && play && p.id === play.id) return;
    const before = play;
    play = p ? { id: p.id, likes: p.likes, liked: p.liked } : null;
    if (p && before && p.id === before.id && p.likes > before.likes && motion) motion.others(p.likes - before.likes);
    draw();
  }

  window.RadioLikes = { listenerId, show, toggle: send };
})();
