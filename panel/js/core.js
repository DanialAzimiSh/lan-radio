/* The panel's shared state: one Alpine store that every section reads.
 *   poll /api/status every 2 s ─> st ─> the sections draw from it
 *   call(path, body)            ─> one place that knows about login (401), errors and toasts
 * Sections keep their own state in their own component (see sections.js and live.js). */
document.addEventListener('alpine:init', () => {
  const FA_DIGITS = '۰۱۲۳۴۵۶۷۸۹';

  Alpine.store('radio', {
    st: null,            // the last /api/status answer
    fetchedAt: 0,
    now: Date.now(),     // ticks every 500 ms so the progress bar moves between polls
    offline: false,
    loggedOut: false,
    loginError: '',
    toastText: '',
    toastOn: false,
    listeners: null,     // Icecast's listener count
    host: location.hostname,
    lib: [],             // every library path, loaded once (and on ↻)

    // ----- formatting -----
    base: f => f.split('/').pop().replace(/\.[^.]+$/, ''),
    dir: f => (f.includes('/') ? f.slice(0, f.lastIndexOf('/')) : ''),
    mb: n => (n / 1048576).toFixed(1),
    fa: n => String(n).replace(/\d/g, d => FA_DIGITS[d]),
    time(at) { return new Date(at * 1000).toLocaleString('fa-IR'); },
    clock(at) { return new Date(at * 1000).toLocaleTimeString('fa-IR'); },
    fmt(s) {
      if (!(s >= 0) || !isFinite(s)) return '–';
      s = Math.floor(s);
      const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = String(s % 60).padStart(2, '0');
      return h ? `${h}:${String(m).padStart(2, '0')}:${x}` : `${m}:${x}`;
    },

    // ----- what the status says -----
    isHidden(f) { return !!this.st && this.st.hidden.includes(f); },
    likeOf(f) { const x = this.st && this.st.likes.find(l => l.file === f); return x ? x.n : 0; },
    get live() { return this.st ? this.st.live : { airing: false, connected: false, allowed: true, since: 0, title: '' }; },
    get playing() { return this.st ? this.st.now.file : ''; },
    get titleText() {
      const s = this.st, n = s.now;
      if (s.live.airing) return s.live.title || 'پخش زنده';
      return n.title || (n.file ? this.base(n.file) : 'چیزی پخش نمی‌شود');
    },
    get artistText() {
      const s = this.st, n = s.now;
      if (s.live.airing) return n.file ? `بعد از پخش زنده، موزیک از «${n.title || this.base(n.file)}» ادامه پیدا می‌کند` : '';
      return n.artist || this.dir(n.file);
    },
    // the on-air track's likes and reactions, as one line
    get mood() {
      const s = this.st, f = s.now.file;
      if (!f || s.live.airing) return '';
      const likes = this.likeOf(f);
      const faces = [['fire', '🔥'], ['clap', '👏'], ['wow', '🤩'], ['sleep', '😴']].filter(([k]) => s.reactions[k]).map(([k, e]) => `${e} ${s.reactions[k]}`).join('  ');
      return [likes ? `❤️ ${likes} شنونده این آهنگ را دوست دارند` : '', faces].filter(Boolean).join('   ·   ');
    },
    elapsed() {
      if (!this.st) return 0;
      if (this.st.live.airing) return this.st.live.since + (this.now - this.fetchedAt) / 1000;
      const n = this.st.now, e = n.elapsed + (this.st.paused ? 0 : (this.now - this.fetchedAt) / 1000);
      return n.duration > 0 ? Math.min(e, n.duration) : e;
    },
    progress() {
      if (!this.st || this.st.live.airing || !(this.st.now.duration > 0)) return 0;
      return Math.min(100, this.elapsed() / this.st.now.duration * 100);
    },

    // ----- talking to the radio -----
    toast(text) {
      this.toastText = text; this.toastOn = true;
      clearTimeout(this._toast);
      this._toast = setTimeout(() => { this.toastOn = false; }, 2400);
    },
    // any 401 means this browser is not signed in (or the password changed): show the login screen
    async call(path, body) {
      const opts = body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
      const r = await fetch('/api/' + path, opts);
      const data = await r.json().catch(() => ({}));
      if (r.status === 401) { this.loggedOut = true; window.dispatchEvent(new Event('radio:logout')); throw new Error('login'); }
      if (!r.ok) { this.toast('خطا: ' + (data.error || r.status)); throw new Error(data.error || r.status); }
      return data;
    },
    // the radio re-picks its next track right after a change; read again once that has settled
    async post(path, body = {}, msg) {
      this.apply(await this.call(path, body));
      if (msg) this.toast(msg);
      setTimeout(() => this.refresh(), 700);
    },
    apply(s) { this.st = s; this.fetchedAt = Date.now(); this.offline = false; },
    async refresh() {
      if (document.hidden) return;
      try { this.apply(await this.call('status')); } catch (e) { if (e.message !== 'login') this.offline = true; }
    },
    async login(password) {
      const r = await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password }) });
      const data = await r.json().catch(() => ({}));
      if (!r.ok) { this.loginError = data.error || 'ورود ممکن نشد'; return false; }
      this.loggedOut = false; this.loginError = '';
      await this.refresh();
      this.loadLibrary(false);
      return true;
    },
    async logout() {
      await fetch('/api/logout', { method: 'POST' });
      this.loggedOut = true;
      window.dispatchEvent(new Event('radio:logout'));
    },
    async loadLibrary(refresh) {
      try { this.lib = await this.call('library' + (refresh ? '?refresh=1' : '')); } catch { return; }
      if (refresh) this.toast('کتابخانه دوباره خوانده شد');
    },
    async loadListeners() {
      try {
        const ice = (await (await fetch(`http://${location.hostname}:8000/status-json.xsl`)).json()).icestats;
        const src = [].concat(ice.source || []).find(x => (x.listenurl || '').endsWith('/radio'));
        this.listeners = src ? src.listeners : 0;
        this.host = ice.host || location.hostname;   // RADIO_HOST, also right when the panel is on localhost
      } catch { this.listeners = null; }
    },
    toggleHidden(f) {
      const hide = !this.isHidden(f);
      return this.post('hidden', { file: f, hidden: hide }, hide ? 'از شنونده‌ها مخفی شد' : 'برای شنونده‌ها نمایش داده می‌شود');
    },
  });
});
