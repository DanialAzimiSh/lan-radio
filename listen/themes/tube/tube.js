/* The "tube radio" design of the listener page: data, player and animations in one file.
 *
 *   poll /api/now ─> render() ─> a new track tunes the dial: the needle sweeps through static to the track's
 *                    own frequency, the digits scramble into place, the title's words rise in
 *   audio level   ─> magic eye, dial glow and the speaker grille (one gsap.ticker callback)
 *   knob          ─> Draggable rotation (with inertia) is the volume
 *
 * Like likes.js, every timeline is built once inside gsap.matchMedia and only restarted afterwards (function
 * values + invalidate() re-roll the sweep each time); with "reduce motion" on, the needle just jumps and the
 * knob has no inertia. The widgets (❤️, reactions, requests) are likes.js, feedback.js and requests.js. */
(function () {
  gsap.registerPlugin(Draggable, InertiaPlugin, SplitText, CustomEase, ScrambleTextPlugin);
  CustomEase.create('settle', 'M0,0 C0.22,0 0.3,1.28 0.5,1.1 0.66,0.96 0.8,1.04 1,1');

  const $ = s => document.querySelector(s);
  const app = $('#app');
  const FA = '۰۱۲۳۴۵۶۷۸۹';
  const fa = x => String(x).replace(/\d/g, d => FA[d]);
  const rel = new Intl.RelativeTimeFormat('fa', { numeric: 'auto' });
  const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const coverUrl = f => '/api/cover?f=' + encodeURIComponent(f);
  function store(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } }
  function load(k) { try { return localStorage.getItem(k); } catch { return null; } }

  // "Ben_Böhmer_Enamour_MP3_4134930_uVidBot.mp3" -> "Ben Böhmer Enamour"
  function clean(file) {
    const n = (file.split('/').pop() || '').replace(/\.[^.]+$/, '');
    return n.replace(/_/g, ' ').replace(/\b(MP3|uVidBot)\b/gi, '').replace(/\b\d{5,}\b/g, '').replace(/\s{2,}/g, ' ').trim();
  }
  const titleOf = t => t.title || clean(t.file);
  const artistOf = t => t.artist || '';
  function hash(s) { let h = 7; for (const c of s) h = (h * 31 + c.codePointAt(0)) >>> 0; return h; }
  function fallbackArt(file) {
    const h = hash(file || 'radio') % 360;
    return `linear-gradient(135deg, hsl(${h} 75% 52%), hsl(${(h + 70) % 360} 70% 28%))`;
  }
  function fmt(s) {
    if (!(s >= 0) || !isFinite(s)) return '';
    s = Math.floor(s);
    const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = String(s % 60).padStart(2, '0');
    return fa(h ? `${h}:${String(m).padStart(2, '0')}:${x}` : `${m}:${x}`);
  }
  // every track sits on its own frequency of the 88-108 dial
  const FREQ_MIN = 88, FREQ_SPAN = 20;
  const freqOf = key => FREQ_MIN + (hash(key || 'radio') % 201) / 10;
  const freqText = f => fa(f.toFixed(1)).replace('.', '٫');

  function hint(t) { $('#hint').textContent = t; }
  window.hint = hint;   // feedback.js and requests.js speak through it

  /* ---------- the dial ---------- */
  const dial = $('#dial'); const needle = $('#needle'); const trackBox = $('#dial-track');
  const freqEl = $('#freq-n');
  {
    let html = '';
    for (let f = FREQ_MIN; f <= FREQ_MIN + FREQ_SPAN; f += 0.5) {
      const pct = (f - FREQ_MIN) / FREQ_SPAN * 100;
      const major = f % 4 === 0, whole = Number.isInteger(f);
      html += `<i class="${major ? 'm' : whole ? '' : 'b'}" style="left:${pct}%"></i>`;
      if (major) html += `<b style="left:${pct}%">${f}</b>`;
    }
    $('#ticks').innerHTML = html;
  }
  const needleX = f => (f - FREQ_MIN) / FREQ_SPAN * trackBox.clientWidth;
  const tuneState = { freq: 98, text: freqText(98) };

  /* ---------- audio ---------- */
  const audio = new Audio();
  audio.preload = 'none';
  const player = createLivePlayer(audio, '/stream', {
    onReconnect: () => { app.classList.add('loading'); hint('اتصال قطع شد، دارم دوباره وصل می‌شم…'); }
  });
  let ctx = null, analyser = null, freq = null;
  const iOS = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

  let volume = Number(load('radio.vol') ?? 80);
  let knobSet = null;   // set by the motion context: turns the knob to a volume
  function applyVolume(fromKnob) {
    audio.volume = volume / 100;
    $('#knob-dial').style.setProperty('--v-deg', volume * 2.7 + 'deg');
    $('#knob').setAttribute('aria-valuenow', String(Math.round(volume)));
    $('#spk').style.opacity = audio.muted || volume === 0 ? .35 : 1;
    if (!fromKnob && knobSet) knobSet(volume);
  }
  $('#mute').onclick = () => { audio.muted = !audio.muted; applyVolume(false); };
  $('#knob').addEventListener('keydown', e => {
    const step = { ArrowLeft: 5, ArrowDown: -5, ArrowRight: -5, ArrowUp: 5 }[e.key];   // RTL: left is "more"
    if (!step) return;
    e.preventDefault();
    audio.muted = false;
    volume = Math.max(0, Math.min(100, volume + step));
    store('radio.vol', volume);
    applyVolume(false);
  });

  function setupAnalyser() {
    // iOS stops Web Audio graphs in the background, so it keeps the plain element (and a calm grille)
    if (ctx || iOS || !window.AudioContext) return;
    try {
      ctx = new AudioContext();
      const src = ctx.createMediaElementSource(audio);
      analyser = ctx.createAnalyser();
      analyser.fftSize = 256;
      analyser.smoothingTimeConstant = .8;
      freq = new Uint8Array(analyser.frequencyBinCount);
      src.connect(analyser);
      analyser.connect(ctx.destination);
    } catch { analyser = null; }
  }
  function start() {
    setupAnalyser();
    if (ctx && ctx.state === 'suspended') ctx.resume();
    app.classList.add('loading');
    player.start().catch(e => {
      if (e.name !== 'NotAllowedError') return;   // AbortError = a reconnect replaced the source
      stop();
      hint('مرورگر اجازه‌ی پخش نداد؛ دوباره روی پخش بزن');
    });
  }
  function stop() {
    player.stop();
    app.classList.remove('playing', 'loading');
    hint('قطع شد. هر وقت خواستی دوباره بزن، از همون لحظه‌ی زنده پخش می‌شه');
  }
  let stationPaused = false;
  $('#play').addEventListener('click', () => { if (motion) motion.press(); if (player.wanted) stop(); else start(); });
  audio.addEventListener('playing', () => { app.classList.add('playing'); app.classList.remove('loading'); hint(stationPaused ? 'وصلی، ولی رادیو الان ساکته' : 'زنده داری گوش می‌دی 🎧'); });
  audio.addEventListener('waiting', () => player.wanted && app.classList.add('loading'));

  /* ---------- the level that drives the eye, the glow and the grille ---------- */
  let level = 0, bass = 0;
  function readLevel(t) {
    const playing = app.classList.contains('playing');
    let l, b;
    if (analyser && playing) {
      analyser.getByteFrequencyData(freq);
      let sum = 0, low = 0;
      for (let i = 0; i < freq.length; i++) { sum += freq[i]; if (i < 6) low += freq[i]; }
      l = sum / freq.length / 150; b = low / 6 / 255;
    } else if (playing) {
      l = .35 + .25 * Math.sin(t / 420) * Math.sin(t / 1100); b = .4 + .3 * Math.sin(t / 520);
    } else { l = .02; b = 0; }
    level += (Math.min(1, l) - level) * .25;
    bass += (Math.min(1, b) - bass) * .35;
  }

  /* ---------- the speaker grille: concentric rings of dots that swell with the sound ---------- */
  const cv = $('#viz'), g = cv.getContext('2d');
  function sizeCanvas() {
    const r = cv.getBoundingClientRect(), dpr = Math.min(2, window.devicePixelRatio || 1);
    cv.width = Math.max(1, r.width * dpr); cv.height = Math.max(1, r.height * dpr);
    drawGrille(0);
  }
  function drawGrille(t) {
    const W = cv.width, c = W / 2, R = W / 2 * .9;
    g.clearRect(0, 0, W, cv.height);
    const rings = 11;
    for (let k = 1; k <= rings; k++) {
      const rr = R * k / rings, n = Math.max(6, Math.round(k * 7));
      const pulse = Math.max(0, level * 1.3 - k / rings * .5) + bass * (1 - k / rings) * .6;
      for (let i = 0; i < n; i++) {
        const a = (i / n) * Math.PI * 2 + k * .31 + t / 9000 * (k % 2 ? 1 : -1) * level;
        const wob = 1 + pulse * .12 * Math.sin(t / 160 + i);
        const x = c + Math.cos(a) * rr * wob, y = c + Math.sin(a) * rr * wob;
        const r0 = W / 120 * (.55 + pulse * 1.1);
        g.globalAlpha = .4 + pulse * .6;
        g.fillStyle = pulse > .45 ? '#ffd27a' : '#d6903a';
        g.beginPath(); g.arc(x, y, r0, 0, Math.PI * 2); g.fill();
      }
    }
    // the cone
    const cone = R * (.1 + bass * .07);
    const grad = g.createRadialGradient(c, c, 0, c, c, cone * 1.6);
    grad.addColorStop(0, `rgba(255, 190, 90, ${.35 + bass * .5})`); grad.addColorStop(1, 'rgba(255, 190, 90, 0)');
    g.globalAlpha = 1; g.fillStyle = grad; g.beginPath(); g.arc(c, c, cone * 1.6, 0, Math.PI * 2); g.fill();
    g.globalAlpha = 1;
  }
  new ResizeObserver(sizeCanvas).observe(cv);

  /* ---------- motion ---------- */
  let motion = null;   // the animations for the current motion preference

  function fullMotion() {
    const eyeGap = $('#eye-gap'), glow = $('#glow'), cabinet = $('#cabinet'), play = $('#play');
    const eyeTo = gsap.quickTo(eyeGap, 'scaleY', { duration: .14, ease: 'power2.out' });
    const glowTo = gsap.quickTo(glow, 'opacity', { duration: .3 });
    const needleBump = gsap.quickTo(needle, 'scaleY', { duration: .12 });

    // the sweep: out into the static, a wobble, then onto the track's own frequency with a little overshoot
    const sweep = gsap.timeline({ paused: true })
      .call(() => dial.classList.add('tuning'))
      .to(needle, { x: () => tuneState.mid, duration: .5, ease: 'power2.in' })
      .to(needle, { x: () => tuneState.mid2, duration: .28, ease: 'sine.inOut' })
      .to(needle, { x: () => needleX(tuneState.freq), duration: 1.15, ease: 'settle' })
      .call(() => dial.classList.remove('tuning'));
    // "{original}": the digits settle on whatever text the element holds when the tween (re)starts
    const digits = gsap.timeline({ paused: true })
      .to(freqEl, { duration: 1.5, scrambleText: { text: '{original}', chars: FA, revealDelay: .5, speed: .6 } });
    const pressTl = gsap.timeline({ paused: true })
      .to(play, { scale: .9, duration: .07, ease: 'power2.out' })
      .to(play, { scale: 1, duration: .55, ease: 'elastic.out(1.2, .35)' });
    let split = null; let words = null;

    // the warm-up when the page opens: the cabinet rises, the dial lights up with a flicker, the needle homes in
    const intro = gsap.timeline({ paused: true })
      .fromTo(cabinet, { y: 40, opacity: 0 }, { y: 0, opacity: 1, duration: .9, ease: 'power3.out', immediateRender: false })
      .fromTo(dial.querySelectorAll('.ticks i, .ticks b'), { opacity: 0 }, { opacity: 1, duration: .5, stagger: { each: .012, from: 'center' }, ease: 'none', immediateRender: false }, .35)
      .fromTo(glow, { opacity: 0 }, { opacity: .8, duration: 1.1, ease: 'steps(9)', immediateRender: false }, .5);

    const frame = () => {
      if (document.hidden) return;
      const t = performance.now();
      readLevel(t);
      eyeTo(.92 - level * .85);
      glowTo(.55 + level * .45);
      needleBump(1 + bass * .05);
      drawGrille(t);
    };
    gsap.ticker.add(frame);

    const knob = Draggable.create('#knob', {
      type: 'rotation', bounds: { minRotation: -135, maxRotation: 135 }, inertia: true, edgeResistance: .85,
      onDrag: onKnob, onThrowUpdate: onKnob,
    })[0];
    function onKnob() {
      audio.muted = false;
      volume = Math.round((knob.rotation + 135) / 270 * 100);
      store('radio.vol', volume);
      applyVolume(true);
    }
    knobSet = v => { gsap.set('#knob', { rotation: v / 100 * 270 - 135 }); knob.update(); };
    knobSet(volume);

    intro.play();
    return {
      frame,
      press: () => pressTl.restart(),
      tune(f, text) {
        tuneState.freq = f;
        const from = gsap.getProperty(needle, 'x');
        const to = needleX(f), w = trackBox.clientWidth;
        tuneState.mid = Math.max(0, Math.min(w, from + (to - from) * .5 + (Math.random() - .5) * w * .5));
        tuneState.mid2 = Math.max(0, Math.min(w, tuneState.mid + (Math.random() - .5) * w * .22));
        freqEl.textContent = text;
        sweep.invalidate().restart(true);
        digits.invalidate().restart(true);
      },
      reveal(el) {
        const text = el.textContent;      // the new title; revert() would bring back the old one
        split?.revert();
        el.textContent = text;
        split = SplitText.create(el, { type: 'words', wordsClass: 'w' });
        words?.kill();
        words = gsap.from(split.words, { yPercent: 70, opacity: 0, duration: .8, stagger: .07, ease: 'power3.out', delay: .9 });
      },
    };
  }

  function reducedMotion() {
    drawGrille(0);
    gsap.set('#eye-gap', { scaleY: .5 });
    const knob = Draggable.create('#knob', {
      type: 'rotation', bounds: { minRotation: -135, maxRotation: 135 },
      onDrag() {
        audio.muted = false;
        volume = Math.round((this.rotation + 135) / 270 * 100);
        store('radio.vol', volume);
        applyVolume(true);
      },
    })[0];
    knobSet = v => { gsap.set('#knob', { rotation: v / 100 * 270 - 135 }); knob.update(); };
    knobSet(volume);
    return {
      press() {},
      tune(f, text) { tuneState.freq = f; freqEl.textContent = text; gsap.set(needle, { x: needleX(f) }); },
      reveal() {},
    };
  }

  const mm = gsap.matchMedia();
  mm.add({ full: '(prefers-reduced-motion: no-preference)', reduced: '(prefers-reduced-motion: reduce)' }, ctxMm => {
    motion = ctxMm.conditions.full ? fullMotion() : reducedMotion();
    return () => { if (motion.frame) gsap.ticker.remove(motion.frame); motion = null; knobSet = null; };
  });
  const life = new AbortController();   // aborted with the page: listeners that must not outlive it
  function teardown(e) { if (e.persisted) return; mm.revert(); life.abort(); window.removeEventListener('pagehide', teardown); }
  window.addEventListener('pagehide', teardown);

  /* ---------- now playing ---------- */
  let now = null, nowAt = 0, shownFile = null, bgFlip = false, live = { airing: false, since: 0 }, firstRender = true;
  const progressTo = gsap.quickTo('#bar', 'scaleX', { duration: 1, ease: 'none' });

  function setBackdrop(url, gradient) {
    bgFlip = !bgFlip;
    const on = $(bgFlip ? '#bg-a' : '#bg-b'), off = $(bgFlip ? '#bg-b' : '#bg-a');
    on.style.backgroundImage = url ? `url("${url}")` : gradient;
    on.classList.add('on');
    off.classList.remove('on');
  }
  function setArt(file) {
    const art = fallbackArt(file);
    $('#art').style.setProperty('--art', art);
    $('#note').textContent = '♪';
    const img = $('#cover');
    img.hidden = true;
    setBackdrop(null, art);
    if (!file) return;
    const probe = new Image();
    probe.onload = () => {
      if (shownFile !== file) return;
      img.src = probe.src;
      img.hidden = false;
      setBackdrop(probe.src);
    };
    probe.src = coverUrl(file);
  }
  function thumb(t) {
    const art = fallbackArt(t.file);
    return `<span class="thumb" style="--art:${art}">${t.file ? `<img src="${coverUrl(t.file)}" alt="" onerror="this.remove()">` : ''}♪</span>`;
  }
  function setLiveArt() {
    $('#art').style.setProperty('--art', 'radial-gradient(circle at 35% 30%, #ff6b6b, #c2112b 55%, #4a0612)');
    $('#cover').hidden = true;
    $('#note').textContent = '🎙';
    setBackdrop(null, 'radial-gradient(circle at 50% 40%, #b0122a, #2a0710 70%)');
  }

  function render(s) {
    now = s.now; nowAt = performance.now();
    stationPaused = s.paused;
    live = s.live || { airing: false, since: 0 };
    // a hidden track has no file but a title: it is still on air
    const onAir = !!(now.file || now.title);
    app.classList.toggle('live', (!s.paused && onAir) || live.airing);
    app.classList.toggle('broadcast', live.airing);
    $('#kicker').textContent = live.airing ? '🔴 پخش زنده' : s.paused ? 'رادیو موقتاً ساکته' : 'در حال پخش';

    // a hidden track has no file and always the same title, so its play id tells one play from the next
    const key = now.file || 'play' + now.id;
    const shown = live.airing ? 'live:' + live.title : key;
    if (shown !== shownFile) {
      shownFile = shown;
      const f = live.airing ? 107.9 : freqOf(key);
      if (live.airing) {
        $('#title').textContent = live.title || 'پخش زنده';
        $('#artist').textContent = 'زنده، همین حالا';
        setLiveArt();
      } else {
        // a hidden track arrives with no file and a placeholder title, and gets the neutral art
        $('#title').textContent = titleOf(now) || 'به‌زودی…';
        $('#artist').textContent = artistOf(now);
        setArt(now.file);
      }
      if (motion) {
        motion.tune(f, freqText(f));
        if (!firstRender) motion.reveal($('#title'));
      }
      if ('mediaSession' in navigator) {
        navigator.mediaSession.metadata = new MediaMetadata(live.airing
          ? { title: live.title || 'پخش زنده', artist: 'رادیو', album: 'رادیو · زنده' }
          : now.file
            ? { title: titleOf(now), artist: artistOf(now) || 'رادیو', album: 'رادیو · زنده',
                artwork: [{ src: location.origin + coverUrl(now.file), sizes: '512x512' }] }
            : { title: now.title || 'رادیو', artist: 'رادیو', album: 'رادیو · زنده' });
      }
      firstRender = false;
    }
    tick();

    // during a broadcast the paused track is what comes back next
    const n = live.airing && onAir ? now : s.next;
    $('#next-h').textContent = live.airing ? 'بعد از پخش زنده' : 'آهنگ بعدی';
    $('#next').innerHTML = n.file
      ? `${thumb(n)}<div class="meta"><div class="t" dir="auto">${esc(titleOf(n))}</div><div class="a" dir="auto">${esc(artistOf(n))}</div></div>`
      : `<span class="empty">${s.paused ? 'بعد از برگشتن رادیو' : 'یه سورپرایز…'}</span>`;

    const past = s.history.slice(1, 8);
    $('#history').innerHTML = past.length ? past.map(h => {
      const mins = Math.max(0, Math.round((s.time - h.at) / 60));
      return `<li class="track-row">${thumb(h)}<div class="meta"><div class="t" dir="auto">${esc(titleOf(h))}</div><div class="a" dir="auto">${esc(artistOf(h))}</div></div><button class="mini-love${h.liked ? ' on' : ''}" data-play="${h.id}" data-liked="${h.liked}" title="دوستش دارم">♥ ${h.likes ? fa(h.likes) : ''}</button><span class="when">${mins < 1 ? 'همین الان' : rel.format(-mins, 'minute')}</span></li>`;
    }).join('') : '<li class="empty">هنوز چیزی پخش نشده</li>';

    // the ❤️ button, reactions and requests live in their own modules
    RadioLikes.show(now.id >= 0 && !live.airing ? { id: now.id, likes: now.likes, liked: now.liked } : null);
    RadioFeedback.show(now.id >= 0 && !live.airing ? { id: now.id, reactions: now.reactions } : null);
    RadioRequests.show(s.mine, s.catalog_open);
  }

  $('#history').addEventListener('click', async e => {
    const b = e.target.closest('.mini-love');
    if (!b) return;
    b.classList.add('pop');
    const r = await RadioLikes.toggle(+b.dataset.play, b.dataset.liked !== 'true');
    if (r) poll();
  });

  function tick() {
    if (!now) return;
    if (live.airing) {
      $('#elapsed').textContent = fmt(live.since + (performance.now() - nowAt) / 1000);
      $('#duration').textContent = 'زنده';
      progressTo(1);
      return;
    }
    const e = now.elapsed + (stationPaused ? 0 : (performance.now() - nowAt) / 1000);
    const d = now.duration > 0 ? now.duration : 0;
    $('#elapsed').textContent = now.file || now.title ? fmt(d ? Math.min(e, d) : e) : '';
    $('#duration').textContent = d ? fmt(d) : '';
    progressTo(d ? Math.min(1, e / d) : 0);
  }

  async function poll() {
    if (document.hidden && !player.wanted) return;
    try { render(await (await fetch('/api/now?listener=' + RadioLikes.listenerId, { cache: 'no-store' })).json()); }
    catch { $('#kicker').textContent = 'رادیو در دسترس نیست'; app.classList.remove('live'); }
  }
  async function listeners() {
    try {
      const s = (await (await fetch('/status-json.xsl', { cache: 'no-store' })).json()).icestats.source;
      const src = [].concat(s || []).find(x => (x.listenurl || '').endsWith('/radio'));
      const n = src ? src.listeners : 0;
      $('#listeners').innerHTML = n ? `<b>${fa(n)}</b> نفر دارن گوش می‌دن` : 'هنوز کسی گوش نمی‌ده';
    } catch { $('#listeners').textContent = ''; }
  }

  /* ---------- media keys, link, timers ---------- */
  if ('mediaSession' in navigator) {
    navigator.mediaSession.setActionHandler('play', start);
    navigator.mediaSession.setActionHandler('pause', stop);
    navigator.mediaSession.setActionHandler('stop', stop);
  }
  const link = `${location.protocol}//${location.host}/radio`;
  $('#link').textContent = link;
  $('#copy').onclick = async () => {
    try { await navigator.clipboard.writeText(link); }
    catch {
      const t = document.createElement('textarea');
      t.value = link; document.body.appendChild(t); t.select();
      try { document.execCommand('copy'); } catch { /* nothing more to try */ }
      t.remove();
    }
    $('#copy').textContent = 'کپی شد ✓';
    setTimeout(() => { $('#copy').textContent = 'کپی'; }, 1800);
  };

  applyVolume(false);
  poll(); listeners();
  setInterval(poll, 3000);
  setInterval(tick, 1000);
  setInterval(listeners, 10000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) { poll(); sizeCanvas(); } }, { signal: life.signal });
})();
