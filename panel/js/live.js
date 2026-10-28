/* Live broadcast from this browser.
 *   capture (screen-share audio or mic) ─> MediaRecorder (Opus, 250 ms chunks) ─> WebSocket "webcast" ─> :8005/live
 * The radio's one-time token is the password, so LIVE_PASSWORD never reaches the browser. Browsers allow
 * capture only on localhost or HTTPS, hence "open the panel on the radio computer itself". */
document.addEventListener('alpine:init', () => {
  const store = () => Alpine.store('radio');
  const secure = window.isSecureContext && !!navigator.mediaDevices && !!window.MediaRecorder;
  const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  Alpine.data('live', () => {
    // MediaStream, WebSocket and friends must stay outside Alpine's reactive proxy
    let session = null;
    return {
      kind: 'system', title: 'پخش زنده', on: false, hint: '', busy: false, secure,
      get r() { return store(); },
      get live() { return this.r.live; },
      get others() { return this.live.connected && !this.on; },
      get badge() { return this.live.airing ? '● روی آنتن' : this.live.connected ? 'وصل، روی آنتن نیست' : 'آفلاین'; },
      get status() {
        const l = this.live;
        if (!l.connected) return l.allowed ? 'هیچ منبع زنده‌ای وصل نیست.' : 'پخش زنده خاموش است و اتصال جدید پذیرفته نمی‌شود.';
        const who = this.on ? 'همین مرورگر' : /Mozilla/.test(l.client) ? 'یک مرورگر' : (l.client || 'یک برنامه');
        const why = l.airing ? '' : !l.allowed ? ' — روی آنتن نیست چون اجازه‌ی پخش زنده خاموش است' : this.r.st.paused ? ' — رادیو متوقف است' : ' — در حال آماده شدن…';
        return `منبع: ${who} · ${this.r.fmt(l.since)}${l.title ? ' · «' + l.title + '»' : ''}${why}`;
      },
      init() {
        this.setKindHint();
        window.addEventListener('beforeunload', e => { if (session) { e.preventDefault(); e.returnValue = ''; } });
        window.addEventListener('radio:logout', () => this.stop('از پنل خارج شدی؛ پخش زنده تمام شد.'));
      },
      setKind(k) { if (!this.on) { this.kind = k; this.setKindHint(); } },
      setKindHint() {
        if (!secure) { this.hint = 'برای پخش زنده از همین صفحه، پنل را روی خود کامپیوتر رادیو با <a href="http://localhost:8001">localhost:8001</a> باز کن؛ مرورگرها گرفتن صدا را فقط روی localhost یا HTTPS اجازه می‌دهند. برنامه‌های پخش (پایین) از هر دستگاهی کار می‌کنند.'; return; }
        this.hint = this.kind === 'system'
          ? 'در پنجره‌ای که باز می‌شود «Entire screen / کل صفحه» را انتخاب کن و تیک «Share system audio» را بزن. هر صدایی که ویندوز پخش کند روی رادیو می‌رود. موقع پخش، روی همین کامپیوتر به رادیو گوش نده تا صدای رادیو دوباره ضبط نشود.'
          : 'صدای میکروفون پیش‌فرض ویندوز روی رادیو می‌رود.';
      },
      async setAllowed(allowed) {
        this.busy = true;
        try { await this.r.post('live/allow', { allowed }, allowed ? 'پخش زنده مجاز شد' : 'پخش زنده خاموش شد'); } finally { this.busy = false; }
      },
      sendTitle() {
        if (session && session.ws.readyState === 1) session.ws.send(JSON.stringify({ type: 'metadata', data: { title: this.title.trim() || 'پخش زنده' } }));
      },
      titleChanged() { clearTimeout(this._t); this._t = setTimeout(() => this.sendTitle(), 600); },
      toggle() { return session ? this.stop('پخش زنده تمام شد؛ موزیک از همان‌جا ادامه پیدا می‌کند.') : this.start(); },

      meter(s, tracks) {
        const ctx = s.ctx = new AudioContext();
        const an = ctx.createAnalyser();
        an.fftSize = 1024;
        ctx.createMediaStreamSource(new MediaStream(tracks)).connect(an);   // not to the speakers: no echo
        const buf = new Float32Array(an.fftSize), bar = this.$refs.meter;
        const loop = () => {
          an.getFloatTimeDomainData(buf);
          let peak = 0;
          for (const v of buf) peak = Math.max(peak, Math.abs(v));
          bar.style.width = Math.min(100, peak * 140) + '%';
          s.raf = requestAnimationFrame(loop);
        };
        loop();
      },

      async start() {
        let stream;
        try {
          stream = this.kind === 'system'
            ? await navigator.mediaDevices.getDisplayMedia({ video: true, systemAudio: 'include', selfBrowserSurface: 'exclude',
                audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } })
            : await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
        } catch (e) {
          this.hint = e.name === 'NotAllowedError' ? 'اجازه‌ی گرفتن صدا داده نشد.' : 'گرفتن صدا ممکن نشد: ' + esc(e.message);
          return;
        }
        const tracks = stream.getAudioTracks();
        if (!tracks.length) {
          stream.getTracks().forEach(t => t.stop());
          this.hint = 'صدایی گرفته نشد. دوباره بزن، «Entire screen / کل صفحه» را انتخاب کن و تیک «Share system audio» را بزن.';
          return;
        }
        const mime = ['audio/webm;codecs=opus', 'audio/ogg;codecs=opus'].find(m => MediaRecorder.isTypeSupported(m));
        if (!mime) { stream.getTracks().forEach(t => t.stop()); this.hint = 'این مرورگر نمی‌تواند صدا را با Opus رمزگذاری کند؛ از کروم یا اج استفاده کن.'; return; }
        if (this.kind === 'system') document.dispatchEvent(new Event('radio:mute-local'));

        let ticket;
        try { ticket = await this.r.call('live/token', {}); } catch { stream.getTracks().forEach(t => t.stop()); return; }
        const ws = new WebSocket(`ws://${location.hostname}:${ticket.port}/${ticket.mount}`, 'webcast');
        const s = session = { stream, ws, rec: null, ctx: null, raf: 0 };
        ws.onopen = () => {
          ws.send(JSON.stringify({ type: 'hello', data: { mime, user: 'source', password: ticket.token,
            audio: { channels: 2, samplerate: 48000, bitrate: 160, encoder: 'MediaRecorder' } } }));
          this.sendTitle();
          s.rec = new MediaRecorder(new MediaStream(tracks), { mimeType: mime, audioBitsPerSecond: 160000 });
          s.rec.ondataavailable = e => { if (e.data.size && ws.readyState === 1) ws.send(e.data); };   // send(Blob) keeps chunk order
          s.rec.start(250);
          this.on = true;
          this.hint = 'روی آنتنی. برای تمام کردن «پایان پخش زنده» را بزن یا اشتراک صفحه را متوقف کن.';
          setTimeout(() => this.r.refresh(), 1500);
        };
        ws.onclose = e => {
          if (session !== s) return;
          this.stop(e.code === 1011 ? 'رادیو اتصال را نپذیرفت؛ «اجازه‌ی پخش زنده» روشن است؟' : 'اتصال پخش زنده قطع شد.');
        };
        tracks.forEach(t => { t.onended = () => session === s && this.stop('اشتراک صدا متوقف شد؛ پخش زنده تمام شد.'); });
        this.meter(s, tracks);
      },

      stop(message) {
        const s = session;
        session = null;
        if (!s) return;
        try { if (s.rec && s.rec.state !== 'inactive') s.rec.stop(); } catch { /* already stopped */ }
        s.stream.getTracks().forEach(t => t.stop());
        if (s.ws.readyState <= 1) s.ws.close();
        cancelAnimationFrame(s.raf);
        if (s.ctx) s.ctx.close();
        this.on = false;
        if (message) this.hint = esc(message);
        setTimeout(() => this.r.refresh(), 1000);
      },
    };
  });
});
