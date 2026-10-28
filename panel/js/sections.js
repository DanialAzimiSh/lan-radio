/* One Alpine component per panel section. They read the shared store ($store.radio, core.js) and own
 * only what is theirs: a search box, a drag in progress, the answer of their own endpoint. */
document.addEventListener('alpine:init', () => {
  const store = () => Alpine.store('radio');
  const TITLES = {
    dashboard: 'داشبورد', playlist: 'لیست پخش', library: 'کتابخانه', live: 'پخش زنده',
    messages: 'پیام‌ها', requests: 'درخواست‌ها', uploads: 'آهنگ‌های ارسالی', settings: 'تنظیمات',
  };
  const TABS = Object.keys(TITLES);

  /* the whole page: routing (#/library), the sign-in screen, polling, the "listen here" player */
  Alpine.data('app', () => {
    let player = null;
    return {
      tab: 'dashboard', menu: false, password: '', listening: false,
      get r() { return store(); },
      get title() { return TITLES[this.tab]; },
      init() {
        document.addEventListener('radio:mute-local', () => {
          if (player && player.wanted) { this.stopListening(); this.r.toast('پخش رادیو در این پنل قطع شد تا صدایش دوباره ضبط نشود'); }
        });
        const fromHash = () => { const t = location.hash.replace(/^#\/?/, ''); this.tab = TABS.includes(t) ? t : 'dashboard'; this.menu = false; };
        fromHash();
        window.addEventListener('hashchange', fromHash);
        this.r.refresh().then(() => this.r.loadLibrary(false));
        this.r.loadListeners();
        setInterval(() => this.r.refresh(), 2000);
        setInterval(() => { this.r.now = Date.now(); }, 500);
        setInterval(() => this.r.loadListeners(), 10000);
        document.addEventListener('visibilitychange', () => this.r.refresh());
        // same low-latency player as the listener page, served by the :8000 front door
        document.head.appendChild(Object.assign(document.createElement('script'), { src: `http://${location.hostname}:8000/listen/live.js` }));
      },
      go(t) { location.hash = '#/' + t; },
      async signIn() { if (await this.r.login(this.password)) this.password = ''; },
      toggleListen() {
        const url = `http://${location.hostname}:8000/stream`;
        player ??= window.createLivePlayer && window.createLivePlayer(this.$refs.player, url);
        if (!player) return this.r.toast('پلیر رادیو (پورت 8000) در دسترس نیست');
        if (!player.wanted) {
          player.start().catch(e => e.name === 'NotAllowedError' && this.r.toast('پخش در مرورگر شروع نشد'));
          this.listening = true;
        } else { player.stop(); this.listening = false; }
      },
      stopListening() { if (player && player.wanted) { player.stop(); this.listening = false; } },
    };
  });

  /* playlist: drag to reorder, per-row actions, and the "play next" queue */
  Alpine.data('playlist', () => ({
    from: null, over: null,
    get r() { return store(); },
    move(list, from, to) { const a = list.slice(); a.splice(to, 0, a.splice(from, 1)[0]); return a; },
    save(list, msg) { return this.r.post('tracks', { tracks: list }, msg); },
    up(i) { if (i > 0) this.save(this.move(this.r.st.tracks, i, i - 1)); },
    down(i) { if (i < this.r.st.tracks.length - 1) this.save(this.move(this.r.st.tracks, i, i + 1)); },
    remove(i) { this.save(this.r.st.tracks.filter((_, j) => j !== i), 'از لیست حذف شد'); },
    drop(to) {
      const from = this.from;
      this.from = null; this.over = null;
      if (from !== null && to !== from) this.save(this.move(this.r.st.tracks, from, to));
    },
    tag(f, i) {
      if (f === this.r.playing && !this.r.live.airing) return '♪ در حال پخش';
      return i === this.r.st.next_index ? 'بعدی' : '';
    },
  }));

  /* library: search, folder filter, add to the playlist / play next / play now / hide */
  Alpine.data('library', () => ({
    q: '', folder: '', limit: 100,
    get r() { return store(); },
    get folders() { return [...new Set(this.r.lib.filter(f => f.includes('/')).map(f => f.split('/')[0]))].sort(); },
    get items() {
      const q = this.q.trim().toLowerCase(), fd = this.folder, r = this.r;
      const inFolder = f => !fd || (fd === '__hidden__' ? r.isHidden(f) : fd === '__liked__' ? r.likeOf(f) > 0 : f.startsWith(fd + '/'));
      const items = r.lib.filter(f => inFolder(f) && (!q || f.toLowerCase().includes(q)));
      return fd === '__liked__' ? items.sort((a, b) => r.likeOf(b) - r.likeOf(a)) : items;
    },
    get shown() { return this.items.slice(0, this.limit); },
    inList(f) { return this.r.st.tracks.includes(f); },
    reset() { this.limit = 100; },
    add(f) { return this.r.post('tracks', { tracks: [...this.r.st.tracks, f] }, 'به لیست اضافه شد'); },
    addAll() {
      const have = new Set(this.r.st.tracks), add = this.items.filter(f => !have.has(f));
      if (!add.length) return this.r.toast('همه‌شون از قبل توی لیست هستن');
      if (add.length > 20 && !confirm(`${add.length} آهنگ به لیست اضافه بشه؟`)) return;
      return this.r.post('tracks', { tracks: [...this.r.st.tracks, ...add] }, `${add.length} آهنگ اضافه شد`);
    },
  }));

  /* a list the admin works through (messages, requests, uploads): loaded when its count in the status changes,
   * or after an action here */
  function inbox(path, counter) {
    return {
      d: null,
      get r() { return store(); },
      async load(sub = '', body) {
        try { this.d = await this.r.call(path + sub, body); } catch { /* login screen or toast already shown */ }
      },
      init() {
        this.load();
        this.$watch(() => this.r.st && this.r.st[counter], () => this.load());
      },
    };
  }

  Alpine.data('messages', () => ({
    ...inbox('messages', 'messages_unread'),
    act(a, id) { return this.load('/' + a, { id }); },
  }));

  Alpine.data('requests', () => ({
    ...inbox('requests', 'requests_pending'),
    // one row per track, however many listeners asked for it; notes stay one per row
    get open() {
      const groups = [], byFile = new Map();
      for (const it of (this.d ? this.d.items : []).filter(i => i.status === 'pending')) {
        const who = it.name || 'ناشناس';
        if (it.file && byFile.has(it.file)) { byFile.get(it.file).names.push(who); continue; }
        const g = { ...it, names: [who] };
        groups.push(g);
        if (it.file) byFile.set(it.file, g);
      }
      return groups;
    },
    get answered() { return (this.d ? this.d.items : []).filter(i => i.status !== 'pending'); },
    state: s => ({ queued: 'در صف پخش', played: 'پخش شد', rejected: 'رد شد', done: 'انجام شد' }[s] || s),
    act(a, id) { return this.load('/' + a, { id }); },
    setMode(auto) { return this.load('/mode', { mode: auto ? 'auto' : 'manual' }); },
  }));

  Alpine.data('uploads', () => ({
    ...inbox('uploads', 'uploads_pending'),
    approve(id, next) { return this.load('/approve', { id, next }); },
    reject(id) { if (confirm('این فایل برای همیشه پاک شود؟')) return this.load('/reject', { id }); },
  }));

  Alpine.data('settings', () => ({
    d: null,
    get r() { return store(); },
    get dbUrl() { return `http://${location.hostname}:8002`; },
    async init() { try { this.d = await this.r.call('settings'); } catch { /* login screen */ } },
    async setCatalog(on) {
      try { this.d = await this.r.call('settings', { catalog_public: on }); this.r.toast(on ? 'شنونده‌ها فهرست آهنگ‌ها را می‌بینند' : 'فهرست آهنگ‌ها بسته شد'); } catch { /* toast shown */ }
      await this.init();
    },
    async setMode(auto) {
      try { await this.r.call('requests/mode', { mode: auto ? 'auto' : 'manual' }); } catch { /* toast shown */ }
      await this.init();
    },
  }));
});
