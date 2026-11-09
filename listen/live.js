/* Low-latency player for the radio's MP3 stream, shared by the listener page and the admin panel.
 *
 * A plain <audio src=stream> lets the browser decide: Chrome gathers ~5 s before it starts and then
 * stays that far behind live for good. Here the page fetches the stream itself and feeds it to Media
 * Source Extensions, so it decides: start right away, play ~0.8 s behind the newest audio, and jump
 * forward whenever a network hiccup leaves it more than 2 s behind.
 *
 *   fetch(/stream) ──chunks──> SourceBuffer ──> <audio> ──> speakers
 *                                  │                ▲
 *                                  └── every 0.5 s: if behind > maxLag, seek to newest − target
 *
 * iPhone Safari has no MSE for MP3 (and suspends it in the background), so it keeps the plain element
 * and only trims what it buffered at start.
 */
window.createLivePlayer = function (audio, url, { target = 0.8, maxLag = 2, onReconnect = () => {} } = {}) {
  const iOS = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const mse = !iOS && !!window.MediaSource && MediaSource.isTypeSupported('audio/mpeg');
  const tail = ranges => (ranges.length ? ranges.end(ranges.length - 1) : 0);
  let session = null, wanted = false, retry = 0;

  function concat(parts) {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let at = 0;
    for (const p of parts) { out.set(p, at); at += p.length; }
    return out;
  }

  function close() {
    if (!session) return;
    session.ctrl.abort();
    clearInterval(session.timer);
    if (session.objectUrl) URL.revokeObjectURL(session.objectUrl);
    session = null;
  }

  function fail() {
    if (!wanted) return;
    close();
    onReconnect();
    clearTimeout(retry);
    retry = setTimeout(() => wanted && start().catch(() => {}), 2500);
  }

  function pump(s) {
    const sb = s.sb;
    if (session !== s || !sb || sb.updating || s.ms.readyState !== 'open') return;
    const b = sb.buffered;
    // drop what was played: Chrome caps an audio SourceBuffer at ~12 MB, a few minutes of 320 kbps
    if (b.length && audio.currentTime - b.start(0) > 30) { sb.remove(b.start(0), audio.currentTime - 10); return; }
    if (!s.queue.length) return;
    const parts = s.queue.splice(0);
    try { sb.appendBuffer(parts.length === 1 ? parts[0] : concat(parts)); } catch { fail(); }
  }

  async function feed(s) {
    if (session !== s || s.ctrl.signal.aborted) return;
    URL.revokeObjectURL(s.objectUrl);
    s.objectUrl = '';
    const sb = s.sb = s.ms.addSourceBuffer('audio/mpeg');
    sb.mode = 'sequence';
    let atLive = false;
    sb.addEventListener('updateend', () => {
      // the first chunk carries Icecast's burst of the last seconds; skip it and start at the live edge
      if (!atLive && tail(sb.buffered) > target + 0.3) { atLive = true; audio.currentTime = tail(sb.buffered) - target; }
      pump(s);
    });
    try {
      const res = await fetch(url + (url.includes('?') ? '&' : '?') + 't=' + Date.now(), { signal: s.ctrl.signal, cache: 'no-store' });
      if (!res.ok || !res.body) throw new Error('HTTP ' + res.status);
      const reader = res.body.getReader();
      for (;;) {
        const { value, done } = await reader.read();
        if (done) throw new Error('stream closed');
        s.queue.push(value);
        pump(s);
      }
    } catch {
      if (session === s) fail();
    }
  }

  function openMse() {
    const s = session = { ctrl: new AbortController(), ms: new MediaSource(), sb: null, queue: [], timer: 0, objectUrl: '' };
    s.objectUrl = URL.createObjectURL(s.ms);
    audio.src = s.objectUrl;
    s.ms.addEventListener('sourceopen', () => feed(s), { once: true });
    s.timer = setInterval(() => {
      if (session !== s || !s.sb || audio.paused) return;
      const newest = tail(s.sb.buffered);
      if (newest - audio.currentTime > maxLag) audio.currentTime = newest - target;
    }, 500);
  }

  function openPlain() {
    session = { ctrl: new AbortController(), timer: 0 };
    audio.src = url + (url.includes('?') ? '&' : '?') + 't=' + Date.now();
    audio.addEventListener('playing', () => {
      try {
        const newest = tail(audio.buffered);
        if (newest - audio.currentTime > maxLag) audio.currentTime = newest - target;
      } catch { /* Safari may refuse to seek a live stream; it simply stays where it is */ }
    }, { once: true });
  }

  function start() {
    wanted = true;
    clearTimeout(retry);
    close();
    (mse ? openMse : openPlain)();
    return audio.play();
  }

  function stop() {
    wanted = false;
    clearTimeout(retry);
    close();
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
  }

  audio.addEventListener('error', () => wanted && fail());
  audio.addEventListener('ended', () => wanted && fail());

  function switchStream(nextUrl) {
    const resume = wanted;
    stop();
    url = nextUrl;
    return resume ? start() : Promise.resolve();
  }

  return { start, stop, switchStream, lowLatency: mse, get wanted() { return wanted; } };
};
