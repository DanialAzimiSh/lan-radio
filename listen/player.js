/* Shared listener playback, metadata and visualizer for all themes. */
/* global RadioChannel */
const $ = s => document.querySelector(s);
const app = $('#app');
const FA = '۰۱۲۳۴۵۶۷۸۹';
const fa = x => String(x).replace(/\d/g, d => FA[d]);
const rel = new Intl.RelativeTimeFormat('fa', { numeric: 'auto' });
const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const coverUrl = f => '/api/cover?f=' + encodeURIComponent(f);

// "Ben_Böhmer_Enamour_MP3_4134930_uVidBot.mp3" -> "Ben Böhmer Enamour"
function clean(file) {
  const n = (file.split('/').pop() || '').replace(/\.[^.]+$/, '');
  return n.replace(/_/g, ' ').replace(/\b(MP3|uVidBot)\b/gi, '').replace(/\b\d{5,}\b/g, '').replace(/\s{2,}/g, ' ').trim();
}
const titleOf = t => t.title || clean(t.file);
const artistOf = t => t.artist || '';

function hue(s) { let h = 0; for (const c of s) h = (h * 31 + c.codePointAt(0)) % 360; return h; }
function fallbackArt(file) {
  const h = hue(file || 'radio');
  return `linear-gradient(135deg, hsl(${h} 75% 52%), hsl(${(h + 70) % 360} 70% 28%))`;
}
function fmt(s) {
  if (!(s >= 0) || !isFinite(s)) return '';
  s = Math.floor(s);
  const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = String(s % 60).padStart(2, '0');
  return fa(h ? `${h}:${String(m).padStart(2, '0')}:${x}` : `${m}:${x}`);
}

/* ---------- audio ---------- */
const audio = new Audio();
audio.preload = 'none';
const player = createLivePlayer(audio, RadioChannel.stream, {
  onReconnect: () => { app.classList.add('loading'); hint('اتصال قطع شد، دارم دوباره وصل می‌شم…'); }
});
let ctx = null, analyser = null, freq = null;
const iOS = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

function store(k, v) { try { localStorage.setItem(k, v); } catch { /* optional browser feature */ } }
function load(k) { try { return localStorage.getItem(k); } catch { return null; } }

const vol = $('#vol');
vol.value = load('radio.vol') ?? 80;
function applyVolume() {
  audio.volume = vol.value / 100;
  vol.style.setProperty('--v', vol.value + '%');
  $('#spk').style.opacity = audio.muted || vol.value == 0 ? .35 : 1;
}
vol.oninput = () => { audio.muted = false; applyVolume(); store('radio.vol', vol.value); };
$('#mute').onclick = () => { audio.muted = !audio.muted; applyVolume(); };
applyVolume();

function setupAnalyser() {
  // iOS stops Web Audio graphs in the background, so it keeps the plain element (and a calm visualizer)
  if (ctx || iOS || !window.AudioContext) return;
  try {
    ctx = new AudioContext();
    const src = ctx.createMediaElementSource(audio);
    analyser = ctx.createAnalyser();
    analyser.fftSize = 2048;
    analyser.smoothingTimeConstant = .8;
    freq = new Uint8Array(analyser.frequencyBinCount);
    makeBands(ctx.sampleRate / analyser.fftSize);
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
    stopPlayback();
    hint('مرورگر اجازه‌ی پخش نداد؛ دوباره روی پخش بزن');
  });
}
function stopPlayback() {
  player.stop();
  app.classList.remove('playing', 'loading');
  hint('قطع شد. هر وقت خواستی دوباره بزن، از همون لحظه‌ی زنده پخش می‌شه');
}
$('#play').onclick = () => (player.wanted ? stopPlayback() : start());
audio.addEventListener('playing', () => { app.classList.add('playing'); app.classList.remove('loading'); hint(stationPaused ? 'وصلی، ولی رادیو الان ساکته' : 'زنده داری گوش می‌دی 🎧'); });
audio.addEventListener('waiting', () => player.wanted && app.classList.add('loading'));

function hint(t) { $('#hint').textContent = t; }

/* ---------- now playing ---------- */
let now = null, nowAt = 0, shownFile = null, stationPaused = false, bgFlip = false, live = { airing: false, since: 0 };

function setArt(file) {
  const art = fallbackArt(file);
  $('#label').style.setProperty('--art', art);
  $('#note').textContent = '♪';
  const img = $('#cover');
  img.hidden = true;
  setBackdrop(null, art);
  setAccent(hue(file || 'radio'));
  if (!file) return;
  const probe = new Image();
  probe.onload = () => {
    if (shownFile !== file) return;
    img.src = probe.src;
    img.hidden = false;
    setBackdrop(probe.src);
    accentFromImage(probe);
  };
  probe.src = coverUrl(file);
}

function setBackdrop(url, gradient) {
  if (!$('#bg-a') || !$('#bg-b')) return;
  bgFlip = !bgFlip;
  const on = $(bgFlip ? '#bg-a' : '#bg-b'), off = $(bgFlip ? '#bg-b' : '#bg-a');
  on.style.backgroundImage = url ? `url("${url}")` : gradient;
  on.classList.add('on');
  off.classList.remove('on');
}

function setAccent(h, s = 85, l = 62) {
  if (document.body.dataset.fixedAccent) return;
  const root = document.documentElement.style;
  root.setProperty('--accent', `hsl(${h} ${s}% ${l}%)`);
  root.setProperty('--accent-soft', `hsl(${h} ${s}% ${l}% / .22)`);
}
function accentFromImage(img) {
  try {
    const c = document.createElement('canvas');
    c.width = c.height = 32;
    const x = c.getContext('2d');
    x.drawImage(img, 0, 0, 32, 32);
    const d = x.getImageData(0, 0, 32, 32).data;
    let r = 0, g = 0, b = 0, w = 0;
    for (let i = 0; i < d.length; i += 4) {
      const mx = Math.max(d[i], d[i + 1], d[i + 2]), mn = Math.min(d[i], d[i + 1], d[i + 2]);
      const wt = (mx ? (mx - mn) / mx : 0) ** 2 * (mx / 255) + .001;
      r += d[i] * wt; g += d[i + 1] * wt; b += d[i + 2] * wt; w += wt;
    }
    r /= w * 255; g /= w * 255; b /= w * 255;
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
    let h = 0;
    if (mx !== mn) {
      const dl = mx - mn;
      h = mx === r ? ((g - b) / dl) % 6 : mx === g ? (b - r) / dl + 2 : (r - g) / dl + 4;
      h = Math.round(h * 60 + 360) % 360;
    }
    const sat = mx === mn ? 0 : (mx - mn) / (1 - Math.abs(mx + mn - 1));
    setAccent(h, Math.round(Math.max(55, Math.min(95, sat * 100 + 25))), 62);
  } catch { /* optional browser feature */ }
}

// rewrite a list only when it changed: an open dropdown keeps its scroll, and missing covers aren't asked for again
function paint(el, html) {
  if (el._html !== html) { el._html = html; el.innerHTML = html; }
}
function thumb(t) {
  const art = fallbackArt(t.file);
  return `<span class="thumb" style="--art:${art}">${t.file ? `<img src="${coverUrl(t.file)}" alt="" onerror="this.remove()">` : ''}♪</span>`;
}
function setLiveArt() {
  $('#label').style.setProperty('--art', 'radial-gradient(circle at 35% 30%, #ff6b6b, #c2112b 55%, #4a0612)');
  $('#cover').hidden = true;
  $('#note').textContent = '🎙';
  setBackdrop(null, 'radial-gradient(circle at 50% 40%, #b0122a, #2a0710 70%)');
  setAccent(355, 85, 60);
}

function render(s) {
  now = s.now; nowAt = performance.now();
  RadioNotices.show(s.notices);
  stationPaused = s.paused;
  live = s.live || { airing: false, since: 0 };
  // a hidden track has no file but a title: it is still on air
  const onAir = !!(now.file || now.title);
  app.classList.toggle('live', (!s.paused && onAir) || live.airing);
  app.classList.toggle('broadcast', live.airing);
  $('#kicker').textContent = live.airing ? '🔴 پخش زنده' : s.paused ? 'رادیو موقتاً ساکته' : 'در حال پخش';

  const shown = live.airing ? 'live:' + live.title : now.file;
  if (shown !== shownFile) {
    shownFile = shown;
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
    if ('mediaSession' in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata(live.airing
        ? { title: live.title || 'پخش زنده', artist: 'رادیو', album: 'رادیو · زنده' }
        : now.file
          ? { title: titleOf(now), artist: artistOf(now) || 'رادیو', album: 'رادیو · زنده',
              artwork: [{ src: location.origin + coverUrl(now.file), sizes: '512x512' }] }
          : { title: now.title || 'رادیو', artist: 'رادیو', album: 'رادیو · زنده' });
    }
  }
  window.dispatchEvent(new CustomEvent('radio:now', { detail: s }));
  tick();

  // the admin decides which of the two lists exist; each opens from one row to five
  const lists = s.lists || { next: true, recent: true };
  $('#card-next').hidden = !lists.next;
  $('#card-recent').hidden = !lists.recent;
  $('#cards').hidden = !lists.next && !lists.recent;
  $('#cards').classList.toggle('one', lists.next !== lists.recent);

  // each board shows its first song next to NEXT / LAST; a click drops the whole list down under it.
  // During a broadcast the paused track is what comes back next.
  const coming = (live.airing && onAir ? [now] : (s.upcoming || [])).slice(0, 5);
  const past = s.history.slice(1).filter(h => !h.kind).slice(0, 5);
  const face = t => t ? `${thumb(t)}<span class="meta"><span class="t" dir="auto">${esc(titleOf(t))}</span><span class="a" dir="auto">${esc(artistOf(t))}</span></span>` : `<span class="meta"><span class="a">…</span></span>`;
  paint($('#next-now'), face(coming[0]));
  paint($('#recent-now'), face(past[0]));
  paint($('#next'), coming.map(n => `<li class="track">${thumb(n)}<div class="meta"><div class="t" dir="auto">${esc(titleOf(n))}</div><div class="a" dir="auto">${esc(artistOf(n))}</div></div></li>`).join(''));
  paint($('#history'), past.map(h => {
    const mins = Math.max(0, Math.round((s.time - h.at) / 60));
    return `<li class="track">${thumb(h)}<div class="meta"><div class="t" dir="auto">${esc(titleOf(h))}</div><div class="a" dir="auto">${esc(artistOf(h))}</div></div><button class="mini-love${h.liked ? ' on' : ''}" data-play="${h.id}" data-liked="${h.liked}" title="دوستش دارم">♥ ${h.likes ? fa(h.likes) : ''}</button><span class="when">${mins < 1 ? 'همین الان' : rel.format(-mins, 'minute')}</span></li>`;
  }).join(''));
  window.RadioLists.show(coming.length, past.length);

  // the ❤️ button and its animations live in likes.js
  RadioLikes.show(now.id >= 0 && !live.airing && !now.kind ? { id: now.id, likes: now.likes, liked: now.liked } : null);
  RadioFeedback.show(now.id >= 0 && !live.airing && !now.kind ? { id: now.id, reactions: now.reactions } : null);
  RadioRequests.show(s.mine, s.catalog_open);
  window.RadioNotes.show(now, live);
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
    $('#bar').style.width = '100%';
    return;
  }
  const e = now.elapsed + (stationPaused ? 0 : (performance.now() - nowAt) / 1000);
  const d = now.duration > 0 ? now.duration : 0;
  $('#elapsed').textContent = now.file || now.title ? fmt(d ? Math.min(e, d) : e) : '';
  $('#duration').textContent = d ? fmt(d) : '';
  $('#bar').style.width = d ? Math.min(100, e / d * 100) + '%' : '0';
}

async function poll() {
  if (document.hidden && !player.wanted) return;
  const channelId = RadioChannel.id;
  try {
    const response = await fetch(RadioChannel.now + (channelId ? '&' : '?') + 'listener=' + RadioLikes.listenerId, { cache: 'no-store' });
    if (!response.ok) throw new Error('now');
    const data = await response.json();
    if (channelId === RadioChannel.id) render(data);
  }
  catch { if (channelId === RadioChannel.id) { $('#kicker').textContent = 'رادیو در دسترس نیست'; app.classList.remove('live'); } }
}
async function listeners() {
  const channelId = RadioChannel.id;
  try {
    const s = (await (await fetch('/status-json.xsl', { cache: 'no-store' })).json()).icestats.source;
    if (channelId !== RadioChannel.id) return;
    const src = [].concat(s || []).find(x => (x.listenurl || '').endsWith(channelId ? '/channel-' + channelId : '/radio'));
    const n = src ? src.listeners : 0;
    const el = $('#listeners');
    el.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 14v-2a8 8 0 0 1 16 0v2"/><path d="M4 14h2.5a1.5 1.5 0 0 1 1.5 1.5v3A1.5 1.5 0 0 1 6.5 20H5a1 1 0 0 1-1-1v-5Zm16 0h-2.5a1.5 1.5 0 0 0-1.5 1.5v3a1.5 1.5 0 0 0 1.5 1.5H19a1 1 0 0 0 1-1v-5Z"/></svg><b>${fa(n)}</b>`;
    el.title = n ? `${fa(n)} نفر دارن گوش می‌دن` : 'هنوز کسی گوش نمی‌ده';
    el.classList.toggle('none', !n);
  } catch { $('#listeners').textContent = ''; }
}

/* ---------- visualizer: bars radiating around the record ---------- */
const cv = $('#viz'), g = cv.getContext('2d');
function sizeCanvas() {
  const r = cv.getBoundingClientRect(), dpr = Math.min(2, window.devicePixelRatio || 1);
  cv.width = r.width * dpr; cv.height = r.height * dpr;
}
window.addEventListener('resize', sizeCanvas);
sizeCanvas();

// Half the ring (top to bottom, mirrored) covers 40 Hz - 14 kHz on a log scale, so every octave gets the same
// share of bars; music has far less energy up high, so higher bands get more gain. (A linear map put bass alone
// at the top and left the lower half on 8-16 kHz, which barely moves.)
const BARS = 96, HALF = BARS / 2;
const level = new Float32Array(BARS);
let bands = [];
function makeBands(binHz) {
  bands = Array.from({ length: HALF }, (_, b) => {
    const f0 = 40 * Math.pow(14000 / 40, b / HALF), f1 = 40 * Math.pow(14000 / 40, (b + 1) / HALF);
    const lo = Math.max(1, Math.floor(f0 / binHz));
    return { lo, hi: Math.max(lo + 1, Math.ceil(f1 / binHz)), gain: 1 + .9 * b / (HALF - 1) };
  });
}
function bandLevel(b) {
  const { lo, hi, gain } = bands[b];
  let sum = 0;
  for (let k = lo; k < hi; k++) sum += freq[k];
  return Math.min(1, sum / (hi - lo) / 255 * gain);
}
function draw(t) {
  requestAnimationFrame(draw);
  if (document.hidden) return;
  const W = cv.width, H = cv.height, cx = W / 2, cy = H / 2;
  const R = W / 2 / 1.32;               // record radius inside the 132% canvas
  const playing = app.classList.contains('playing');
  if (analyser && playing) analyser.getByteFrequencyData(freq);
  g.clearRect(0, 0, W, H);
  const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent');
  if (document.body.dataset.visualizer === 'bars') {
    g.lineWidth = Math.max(1, W / 240);
    const elapsed = now ? now.elapsed + (stationPaused ? 0 : (performance.now() - nowAt) / 1000) : 0;
    const progress = now?.duration > 0 ? Math.min(1, elapsed / now.duration) : .35;
    for (let i = 0; i < BARS; i++) {
      const b = Math.floor(i / BARS * HALF);
      const v = analyser && playing && bands.length ? bandLevel(b) : playing ? .15 + .12 * Math.sin(t / 400 + i * .5) : .025;
      level[i] += (v - level[i]) * .25;
      const x = (i + .5) / BARS * W;
      g.strokeStyle = i / BARS < progress ? accent : '#ffffff30';
      g.beginPath(); g.moveTo(x, H); g.lineTo(x, H - Math.max(2, level[i] * H)); g.stroke();
    }
    return;
  }
  g.strokeStyle = accent;
  g.lineCap = 'round';
  g.lineWidth = Math.max(2, W / 220);
  g.shadowColor = accent;
  g.shadowBlur = W / 60;
  for (let i = 0; i < BARS; i++) {
    const half = i < HALF ? i : BARS - 1 - i;           // mirror so the ring is symmetric
    let v;
    if (analyser && playing && bands.length) v = bandLevel(half);
    else if (playing) v = .25 + .2 * Math.sin(t / 380 + half * .55) * Math.sin(t / 900 + half * .21);
    else v = .05 + .03 * Math.sin(t / 900 + half * .4);
    level[i] += (v - level[i]) * .25;
    const len = R * .03 + level[i] * R * .2;
    const a = (i / BARS) * Math.PI * 2 - Math.PI / 2;
    const r0 = R * 1.035;
    g.globalAlpha = .35 + level[i] * .65;
    g.beginPath();
    g.moveTo(cx + Math.cos(a) * r0, cy + Math.sin(a) * r0);
    g.lineTo(cx + Math.cos(a) * (r0 + len), cy + Math.sin(a) * (r0 + len));
    g.stroke();
  }
  g.globalAlpha = 1;
}
requestAnimationFrame(draw);

/* ---------- media keys, link, timers ---------- */
if ('mediaSession' in navigator) {
  navigator.mediaSession.setActionHandler('play', start);
  navigator.mediaSession.setActionHandler('pause', stopPlayback);
  navigator.mediaSession.setActionHandler('stop', stopPlayback);
}

let link = `${location.protocol}//${location.host}${RadioChannel.id ? '/channel-' + RadioChannel.id : '/radio'}`;
$('#link').textContent = link;
$('#copy').onclick = async () => {
  try { await navigator.clipboard.writeText(link); }
  catch {
    const t = document.createElement('textarea');
    t.value = link; document.body.appendChild(t); t.select();
    try { document.execCommand('copy'); } catch { /* optional browser feature */ }
    t.remove();
  }
  $('#copy').textContent = 'کپی شد ✓';
  $('#copy').classList.add('copied');
  setTimeout(() => { $('#copy').textContent = 'کپی'; $('#copy').classList.remove('copied'); }, 1800);
};

window.addEventListener('radio:channel-changed', () => {
  shownFile = null; now = null;
  RadioNotices.show([]); RadioLikes.show(null); RadioFeedback.show(null); RadioRequests.show([], false);
  window.RadioNotes.show(null, null);
  $('#title').textContent = 'در حال دریافت کانال…'; $('#artist').textContent = '';
  $('#listeners').textContent = '';
  link = `${location.protocol}//${location.host}${RadioChannel.id ? '/channel-' + RadioChannel.id : '/radio'}`;
  $('#link').textContent = link;
  if (player.wanted) app.classList.add('loading');
  const channelId = RadioChannel.id;
  player.switchStream(RadioChannel.stream).catch(error => {
    if (error.name === 'NotAllowedError' && channelId === RadioChannel.id) { stopPlayback(); hint('برای شروع پخش روی دکمهٔ پخش بزن'); }
  });
  poll(); listeners();
});
poll(); listeners();
setInterval(poll, 3000);
setInterval(tick, 1000);
setInterval(listeners, 10000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) { poll(); sizeCanvas(); } });
