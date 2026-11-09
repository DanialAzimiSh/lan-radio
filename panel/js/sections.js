/* One Alpine component per panel section. They read the shared store ($store.radio, core.js) and own
 * only what is theirs: a search box, a drag in progress, the answer of their own endpoint. */
document.addEventListener('alpine:init', () => {
  const store = () => Alpine.store('radio');
  const TITLES = {
    dashboard: 'داشبورد', playlist: 'لیست پخش', library: 'کتابخانه', live: 'پخش زنده',
    messages: 'پیام‌ها', notices: 'اعلان‌ها', requests: 'درخواست‌ها', uploads: 'آهنگ‌های ارسالی',
    jingles: 'جینگل و ساعت', channels: 'کانال‌ها', stats: 'آمار', settings: 'تنظیمات',
  };
  const TABS = Object.keys(TITLES);

  /* the whole page: routing (#/library), the sign-in screen, polling, the "listen here" player */
  Alpine.data('app', () => {
    let player = null;
    return {
      tab: 'dashboard', menu: false, password: '', listening: false,
      get r() { return store(); },
      get title() { return TITLES[this.tab]; },
      get listenerUrl() { return `http://${location.hostname}:8000${this.r.channelId ? '/channel/' + this.r.channelId : '/radio'}`; },
      init() {
        document.addEventListener('radio:mute-local', () => {
          if (player && player.wanted) { this.stopListening(); this.r.toast('پخش رادیو در این پنل قطع شد تا صدایش دوباره ضبط نشود'); }
        });
        const fromHash = () => { const t = location.hash.replace(/^#\/?/, ''); this.tab = TABS.includes(t) ? t : 'dashboard'; this.menu = false; };
        fromHash();
        window.addEventListener('hashchange', fromHash);
        this.r.loadChannels().then(() => this.r.refresh().then(() => this.r.loadLibrary(false)));
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
        const url = `http://${location.hostname}:8000${this.r.channelId ? '/channel-' + this.r.channelId : '/stream'}`;
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

  /* Home: the real listener page beside the controls for what appears on it. */
  Alpine.data('dashboard', () => ({
    settings: null, settingsBusy: false,
    publicNow: null, publicFetchedAt: 0, publicTimer: 0, publicLoadId: 0, nextExpanded: false, recentExpanded: false, showNoticeForm: false, previewVolume: 80,
    noticeTitle: '', noticeBody: '', noticeStyle: 'banner', noticeTtl: 3600, noticeBusy: false,
    noteFile: '', noteDescription: '', noteFacts: '', noteBusy: false,
    clips: null, clipsTimer: 0, manualJingleName: '', manualBusy: false,
    eqFrequencies: ['60', '150', '400', '1k', '2.5k', '6k', '12k'],
    eqGains: [0, 0, 0, 0, 0, 0, 0], eqEnabled: false, eqBusy: false, eqPreset: 'flat',
    eqHz: [60, 150, 400, 1000, 2500, 6000, 12000],
    eqDrag: null, eqSelected: 3, eqKeyDirty: false,
    get r() { return store(); },
    get previewNow() { return this.publicNow?.now || {}; },
    get previewTitle() { const n = this.previewNow; return this.publicNow?.live?.airing ? (this.publicNow.live.title || 'پخش زنده') : n.title || (n.file ? this.r.base(n.file) : 'چیزی پخش نمی‌شود'); },
    get previewArtist() { const n = this.previewNow; return this.publicNow?.live?.airing ? 'زنده، همین حالا' : n.artist || (n.file ? this.r.dir(n.file) : ''); },
    get nextItems() { return this.publicNow?.live?.airing && this.previewNow.title ? [this.previewNow] : (this.publicNow?.upcoming || []).slice(0, 5); },
    get recentItems() { return (this.publicNow?.history || []).slice(1).filter(h => !h.kind).slice(0, 5); },
    get previewNotice() { return (this.publicNow?.notices || []).find(n => n.style !== 'popup') || (this.publicNow?.notices || [])[0] || null; },
    get previewElapsed() { if (!this.publicNow) return 0; const n = this.previewNow; const delta = Math.max(0, (this.r.now - this.publicFetchedAt) / 1000); if (this.publicNow.live?.airing) return (this.publicNow.live.since || 0) + delta; return (n.elapsed || 0) + (this.publicNow.paused ? 0 : delta); },
    get previewProgress() { const d = this.previewNow.duration; return this.publicNow?.live?.airing || !(d > 0) ? 0 : Math.min(100, this.previewElapsed / d * 100); },
    async init() {
      this.publicFetchedAt = Date.now();
      document.querySelector('body > audio').volume = this.previewVolume / 100;
      await Promise.all([this.loadSettings(), this.loadPublic(), this.loadClips()]);
      this.publicTimer = setInterval(() => { if (this.tab === 'dashboard' && !document.hidden) this.loadPublic(); }, 3000);
      this.clipsTimer = setInterval(() => { if (this.tab === 'dashboard' && !document.hidden) this.loadClips(); }, 5000);
      this.$watch('tab', value => { if (value === 'dashboard') Promise.all([this.loadSettings(), this.loadPublic(), this.loadClips()]); });
    },
    destroy() { clearInterval(this.publicTimer); clearInterval(this.clipsTimer); },
    async loadClips() {
      try {
        this.clips = await this.r.call('clips');
        if (this.manualJingleName && !this.clips.jingles.some(j => j.name === this.manualJingleName)) this.manualJingleName = '';
      } catch { /* login screen or toast shown */ }
    },
    async playManualJingle() {
      if (!this.manualJingleName || this.manualBusy || this.clips?.manual?.remaining > 0) return;
      this.manualBusy = true;
      try {
        this.clips = await this.r.call('clips/play', { name: this.manualJingleName });
        this.r.toast('جینگل روی صدای در حال پخش شروع شد');
      } catch { /* toast shown */ }
      this.manualBusy = false;
    },
    async loadSettings() {
      try {
        this.settings = await this.r.call('settings');
        this.eqEnabled = !!this.settings.equalizer?.enabled;
        this.eqGains = [...(this.settings.equalizer?.gains || [0, 0, 0, 0, 0, 0, 0])];
        this.eqPreset = this.matchEqPreset();
      } catch { /* login screen or toast shown */ }
    },
    eqPresets() { return { flat: [0, 0, 0, 0, 0, 0, 0], warm: [2, 1.5, .5, 0, -.5, -.5, 0], clear: [-1, -.5, 0, .5, 1.5, 2, 1], bass: [4, 3, 1, 0, -.5, 0, 0], voice: [-2, -1, 0, 1.5, 2.5, 1, -1] }; },
    matchEqPreset() {
      return Object.entries(this.eqPresets()).find(([, gains]) => gains.every((gain, i) => gain === Number(this.eqGains[i])))?.[0] || 'custom';
    },
    setEqBand(i, value) {
      const gain = Number(value);
      if (!Number.isFinite(gain)) return;
      this.eqGains[i] = Math.max(-9, Math.min(9, Math.round(gain * 2) / 2));
      this.eqSelected = i;
      this.eqPreset = this.matchEqPreset();
    },
    eqX(i) { return 44 + Math.log10(this.eqHz[i] / 20) / 3 * 684; },
    eqY(gain) { return 114 - Number(gain) * 10; },
    get eqCurve() {
      const points = [{ x: 44, y: 114 }, ...this.eqGains.map((g, i) => ({ x: this.eqX(i), y: this.eqY(g) })), { x: 728, y: 114 }];
      return points.slice(1).reduce((path, p, i) => {
        const before = points[i], mid = (before.x + p.x) / 2;
        return `${path} C${mid},${before.y} ${mid},${p.y} ${p.x},${p.y}`;
      }, 'M44,114');
    },
    get eqArea() { return this.eqCurve + ' L728,114 L44,114 Z'; },
    eqValue(i) { const gain = Number(this.eqGains[i]); return (gain > 0 ? '+' : '') + gain.toFixed(1) + ' dB'; },
    beginEqPoint(event, i) {
      if (!this.settings || this.eqBusy || this.eqDrag || event.button !== 0) return;
      const y = this.eqPointerY(event);
      if (y === null) return;
      event.preventDefault();
      event.currentTarget.focus?.();
      this.eqSelected = i;
      this.eqDrag = { index: i, pointer: event.pointerId, before: [...this.eqGains], startY: y };
      this.$refs.eqChart.setPointerCapture(event.pointerId);
    },
    eqPointerY(event) {
      const svg = this.$refs.eqChart, matrix = svg.getScreenCTM();
      if (!matrix) return null;
      const point = svg.createSVGPoint();
      point.x = event.clientX; point.y = event.clientY;
      return point.matrixTransform(matrix.inverse()).y;
    },
    moveEqPoint(event) {
      if (!this.eqDrag || event.pointerId !== this.eqDrag.pointer) return;
      const y = this.eqPointerY(event);
      if (y === null) return;
      this.setEqBand(this.eqDrag.index, this.eqDrag.before[this.eqDrag.index] + (this.eqDrag.startY - y) / 10);
    },
    finishEqPoint(event) {
      if (!this.eqDrag || event.pointerId !== this.eqDrag.pointer) return;
      this.moveEqPoint(event);
      const changed = this.eqDrag.before.some((gain, i) => gain !== this.eqGains[i]);
      this.eqDrag = null;
      if (this.$refs.eqChart.hasPointerCapture(event.pointerId)) this.$refs.eqChart.releasePointerCapture(event.pointerId);
      if (changed) this.saveEq();
    },
    cancelEqPoint(event) {
      if (!this.eqDrag || event.pointerId !== this.eqDrag.pointer) return;
      this.eqGains = this.eqDrag.before;
      this.eqDrag = null;
      this.eqPreset = this.matchEqPreset();
    },
    eqPointKey(event, i) {
      if (!this.settings || this.eqBusy || this.eqDrag) return;
      const value = Number(this.eqGains[i]);
      const gains = { ArrowUp: value + .5, ArrowRight: value + .5, ArrowDown: value - .5, ArrowLeft: value - .5, PageUp: value + 3, PageDown: value - 3, Home: -9, End: 9, '0': 0, '۰': 0, '٠': 0 };
      if (!(event.key in gains)) return;
      event.preventDefault();
      this.setEqBand(i, gains[event.key]);
      if (value !== this.eqGains[i]) this.eqKeyDirty = true;
    },
    finishEqKey() {
      if (!this.eqKeyDirty) return;
      this.eqKeyDirty = false;
      this.saveEq();
    },
    resetEqPoint(i) {
      if (!this.settings || this.eqBusy || this.eqDrag || Number(this.eqGains[i]) === 0) return;
      this.setEqBand(i, 0);
      this.saveEq();
    },
    async setEqEnabled(enabled) { this.eqEnabled = enabled; await this.saveEq(); },
    async applyEqPreset(name) {
      const gains = this.eqPresets()[name];
      if (!gains) return;
      this.eqGains = [...gains];
      this.eqPreset = name;
      await this.saveEq();
    },
    async saveEq() {
      if (!this.settings || this.eqBusy) return;
      this.eqBusy = true;
      try {
        this.settings = await this.r.call('settings/equalizer', { enabled: this.eqEnabled, gains: this.eqGains.map(Number) });
        this.eqGains = [...this.settings.equalizer.gains];
        this.eqEnabled = this.settings.equalizer.enabled;
        this.eqPreset = this.matchEqPreset();
        this.r.toast('اکولایزر پخش اعمال شد');
      } catch {
        this.eqGains = [...this.settings.equalizer.gains];
        this.eqEnabled = this.settings.equalizer.enabled;
        this.eqPreset = this.matchEqPreset();
      }
      this.eqBusy = false;
    },
    async loadPublic() {
      const loadId = ++this.publicLoadId;
      try {
        const data = await this.r.call(this.r.channelId ? 'channels/listen?channel=' + this.r.channelId : 'now');
        if (loadId === this.publicLoadId) { this.publicNow = data; this.publicFetchedAt = Date.now(); }
      } catch { /* toast shown */ }
    },
    coverUrl(file) { return file ? '/api/cover?f=' + encodeURIComponent(file) : ''; },
    trackTitle(track) { return track.title || (track.file ? this.r.base(track.file) : 'موسیقی'); },
    trackArtist(track) { return track.artist || (track.file ? this.r.dir(track.file) : ''); },
    when(at) { const m = Math.max(0, Math.round(((this.publicNow?.time || 0) - at) / 60)); return m < 1 ? 'همین الان' : `${this.r.fa(m)} دقیقه پیش`; },
    setPreviewVolume(ev) { this.previewVolume = +ev.target.value; document.querySelector('body > audio').volume = this.previewVolume / 100; },
    async saveLists(patch) {
      if (!this.settings || this.settingsBusy) return;
      this.settingsBusy = true;
      try {
        const cur = await this.r.call('settings');   // the settings section edits the same two switches
        this.settings = await this.r.call('settings/lists', { show_next: cur.show_next, show_recent: cur.show_recent, ...patch });
        this.r.toast('نمایش فهرست‌ها ذخیره شد');
      } catch { /* toast shown */ }
      this.settingsBusy = false;
    },
    async publishNotice() {
      if (this.noticeBusy || !(this.noticeTitle.trim() || this.noticeBody.trim())) return;
      this.noticeBusy = true;
      try {
        await this.r.call('notices', { title: this.noticeTitle, body: this.noticeBody, style: this.noticeStyle, ttl: +this.noticeTtl, image: '', reply_to: 0 });
        this.noticeTitle = this.noticeBody = '';
        this.r.toast('اعلان نمایش داده شد');
        window.dispatchEvent(new Event('radio:notices-changed'));
        this.loadPublic();
      } catch { /* toast shown */ }
      this.noticeBusy = false;
    },
    async endNotice(id) {
      try {
        await this.r.call('notices/end', { id });
        window.dispatchEvent(new Event('radio:notices-changed'));
        this.loadPublic();
      } catch { /* toast shown */ }
    },
    async openNote() {
      const file = this.r.playing;
      if (!file || this.noteBusy) return;
      this.noteBusy = true;
      try {
        const note = await this.r.call('notes?file=' + encodeURIComponent(file));
        this.noteFile = file;
        this.noteDescription = note.description;
        this.noteFacts = note.facts;
      } catch { /* toast shown */ }
      this.noteBusy = false;
    },
    async saveNote() {
      if (!this.noteFile || this.noteBusy) return;
      this.noteBusy = true;
      try {
        const note = await this.r.call('notes', { file: this.noteFile, description: this.noteDescription, facts: this.noteFacts });
        this.noteDescription = note.description;
        this.noteFacts = note.facts;
        this.r.toast('توضیحات آهنگ ذخیره شد');
        this.loadPublic();
      } catch { /* toast shown */ }
      this.noteBusy = false;
    },
  }));

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
    noteFile: '', noteDescription: '', noteFacts: '', noteBusy: false, noteLoadId: 0,
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
    async editNote(f) {
      const loadId = ++this.noteLoadId;
      this.noteFile = f;
      this.noteDescription = this.noteFacts = '';
      this.noteBusy = true;
      try {
        const note = await this.r.call('notes?file=' + encodeURIComponent(f));
        if (loadId === this.noteLoadId) { this.noteDescription = note.description; this.noteFacts = note.facts; }
      } catch { if (loadId === this.noteLoadId) this.noteFile = ''; }
      if (loadId !== this.noteLoadId) return;
      this.noteBusy = false;
      this.$nextTick(() => this.$refs.noteEditor?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }));
    },
    async saveNote() {
      if (this.noteBusy || !this.noteFile) return;
      this.noteBusy = true;
      try {
        const note = await this.r.call('notes', { file: this.noteFile, description: this.noteDescription, facts: this.noteFacts });
        this.noteDescription = note.description;
        this.noteFacts = note.facts;
        this.r.toast('توضیحات ذخیره شد');
      } catch { /* toast shown */ }
      this.noteBusy = false;
    },
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
        window.addEventListener('radio:' + path + '-changed', () => this.load());
      },
    };
  }

  Alpine.data('messages', () => ({
    ...inbox('messages', 'messages_unread'),
    act(a, id) { return this.load('/' + a, { id }); },
    // the answer is written in the notices section, which shows the message beside it
    reply(m) { this.r.replyTo = m; location.hash = '#/notices'; },
  }));

  Alpine.data('channels', () => ({
    d: [], maxChannels: null, selected: 0, newName: '', editName: '', search: '', busy: false,
    get r() { return store(); },
    get channel() { return this.d.find(c => c.id === +this.selected) || null; },
    get listenerUrl() { return this.channel ? `http://${location.hostname}:8000${this.channel.id ? '/channel/' + this.channel.id : '/radio'}` : ''; },
    get streamUrl() { return this.channel ? `http://${location.hostname}:8000${this.channel.id ? '/channel-' + this.channel.id : '/stream'}` : ''; },
    get matches() {
      const q = this.search.trim().toLowerCase();
      return q ? this.r.lib.filter(f => f.toLowerCase().includes(q) && !this.channel.tracks.includes(f)).slice(0, 25) : [];
    },
    init() {
      this.selected = this.r.channelId;
      this.load();
      this.$watch('selected', () => { this.editName = this.channel?.name || ''; });
      setInterval(() => { if (location.hash === '#/channels' && !this.busy) this.load(); }, 5000);
    },
    async load() {
      try {
        const [channels, limits] = await Promise.all([this.r.call('channels/manage'), this.r.call('channels/limits')]);
        this.d = channels;
        this.maxChannels = limits.max_channels;
        if (!this.channel) this.selected = 0;
        if (!this.editName && this.channel) this.editName = this.channel.name;
      } catch { /* login screen or toast already shown */ }
    },
    async create() {
      const name = this.newName.trim();
      if (!name || this.busy || this.maxChannels === null || this.d.length >= this.maxChannels) return;
      this.busy = true;
      try {
        this.d = await this.r.call('channels/create', { name });
        this.selected = this.d.at(-1).id;
        this.editName = name;
        this.newName = '';
        this.r.toast('کانال ساخته شد');
        await this.r.loadChannels();
        this.r.selectChannel(this.selected);
      } catch { /* toast shown */ }
      this.busy = false;
    },
    async action(action, values = {}) {
      if (!this.channel || this.busy) return;
      this.busy = true;
      try {
        this.d = await this.r.call('channels/action', {
          id: this.channel.id, action, name: values.name ?? '', file: values.file ?? '',
          mode: values.mode ?? '', paused: values.paused ?? false, tracks: values.tracks ?? [],
        });
        if (action === 'rename') { this.editName = this.channel.name; await this.r.loadChannels(); }
        return true;
      } catch { /* toast shown */ } finally { this.busy = false; }
      return false;
    },
    add(file) { if (this.channel) this.action('tracks', { tracks: [...this.channel.tracks, file] }); },
    removeTrack(i) { if (this.channel) this.action('tracks', { tracks: this.channel.tracks.filter((_, n) => n !== i) }); },
    move(i, direction) {
      if (!this.channel) return;
      const rows = [...this.channel.tracks], j = i + direction;
      if (j < 0 || j >= rows.length) return;
      [rows[i], rows[j]] = [rows[j], rows[i]];
      this.action('tracks', { tracks: rows });
    },
    async remove() {
      if (!this.channel || !this.channel.id || !confirm(`کانال «${this.channel.name}» حذف شود؟`)) return;
      if (!(await this.action('delete'))) return;
      await this.r.loadChannels();
      this.r.selectChannel(0);
    },
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

  /* notices: what every listener sees on the page - a text, a picture, or a public answer to a message */
  Alpine.data('notices', () => ({
    d: null, busy: false, preview: '', timer: 0, events: null,
    form: { title: '', body: '', style: 'banner', ttl: 3600, image: '' },
    get r() { return store(); },
    get reply() { return this.r.replyTo; },
    get active() { return (this.d ? this.d.items : []).filter(n => n.active); },
    get past() { return (this.d ? this.d.items : []).filter(n => !n.active); },
    get can() { const f = this.form; return !this.busy && (this.reply ? !!f.body.trim() : !!(f.title.trim() || f.body.trim() || f.image)); },
    async load(path = '', body) { try { this.d = await this.r.call('notices' + path, body); } catch { /* toast shown */ } },
    init() {
      this.load();
      this.timer = setInterval(() => { if (location.hash === '#/notices') this.load(); }, 8000);
      this.events = new AbortController();
      window.addEventListener('radio:notices-changed', () => this.load(), { signal: this.events.signal });
      window.addEventListener('hashchange', () => { if (location.hash === '#/notices') this.load(); }, { signal: this.events.signal });
    },
    destroy() { clearInterval(this.timer); this.events?.abort(); },
    async pickImage(ev) {
      const f = ev.target.files[0];
      ev.target.value = '';
      if (!f) return;
      if (f.size > 3 * 1048576) return this.r.toast('حجم عکس بیشتر از ۳ مگابایت است');
      this.busy = true;
      try {
        const { image } = await this.r.raw('notices/image', f);
        this.dropImage();
        this.form.image = image;
        this.preview = URL.createObjectURL(f);
      } catch { /* toast shown */ }
      this.busy = false;
    },
    dropImage() { if (this.preview) URL.revokeObjectURL(this.preview); this.preview = ''; this.form.image = ''; },
    async publish() {
      const f = this.form;
      try {
        this.d = await this.r.call('notices', { title: f.title, body: f.body, style: f.style, ttl: +f.ttl, image: f.image, reply_to: this.reply ? this.reply.id : 0 });
        if (this.reply) window.dispatchEvent(new Event('radio:messages-changed'));
        this.r.toast('برای همه نمایش داده شد');
        this.clear();
      } catch { /* toast shown */ }
    },
    clear() { this.dropImage(); this.form.title = ''; this.form.body = ''; this.r.replyTo = null; },
    again(n) { this.clear(); Object.assign(this.form, { title: n.title, body: n.body, style: n.style }); window.scrollTo({ top: 0, behavior: 'smooth' }); },
    end(id) { return this.load('/end', { id }); },
    async remove(id) {
      if (!confirm('این اعلان برای همیشه پاک شود؟')) return;
      await this.load('/delete', { id });
      window.dispatchEvent(new Event('radio:messages-changed'));
    },
    left(n) {
      if (!n.expires) return 'تا وقتی برش داری';
      const m = Math.max(1, Math.round((n.expires * 1000 - this.r.now) / 60000));
      return m >= 90 ? `${this.r.fa(Math.round(m / 60))} ساعت دیگر` : `${this.r.fa(m)} دقیقه دیگر`;
    },
  }));

  /* stats: numbers from the radio's database, charts from Prometheus (asked through the radio) */
  Alpine.data('stats', () => ({
    days: 7, range: '24h', d: null, listeners: null, plays: null, promError: '', statsError: '', timer: 0, events: null,
    get r() { return store(); },
    async init() {
      await Promise.all([this.loadStats(), ...(this.r.channelId === 0 ? [this.loadSeries()] : [])]);
      this.$watch('days', () => this.loadStats());
      this.$watch('range', () => { if (this.r.channelId === 0) this.loadSeries(); });
      this.timer = setInterval(() => { if (location.hash === '#/stats') this.loadStats(); }, 15000);
      this.events = new AbortController();
      window.addEventListener('hashchange', () => { if (location.hash === '#/stats') this.loadStats(); }, { signal: this.events.signal });
    },
    destroy() { clearInterval(this.timer); this.events?.abort(); },
    async loadStats() {
      try { this.d = await this.r.call('stats?days=' + this.days); this.statsError = ''; }
      catch { this.statsError = 'دریافت آمار ممکن نشد؛ دوباره تلاش می‌کنیم.'; }
    },
    async series(q) {
      const res = await fetch(`/api/stats/series?q=${q}&range=${this.range}`);
      if (res.status === 401) { this.r.loggedOut = true; return null; }
      const j = await res.json().catch(() => ({}));
      if (!res.ok) { this.promError = j.error || 'Prometheus در دسترس نیست'; return null; }
      const hit = j.data && j.data.result && j.data.result[0];
      return hit ? hit.values.map(([t, v]) => [t, +v]) : [];
    },
    async loadSeries() {
      this.promError = '';
      this.listeners = this.chart(await this.series('listeners'));
      this.plays = this.chart(await this.series('plays'));
    },
    chart(pts) {
      if (!pts || !pts.length) return null;
      const W = 600, H = 140, max = Math.max(1, ...pts.map(p => p[1]));
      const x = i => (pts.length < 2 ? 0 : i / (pts.length - 1) * W);
      const y = v => H - v / max * (H - 10) - 5;
      const line = pts.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)} ${y(p[1]).toFixed(1)}`).join('');
      return { line, area: `${line}L${W} ${H}L0 ${H}Z`, max: Math.round(max), last: Math.round(pts[pts.length - 1][1]), avg: Math.round(pts.reduce((a, p) => a + p[1], 0) / pts.length * 10) / 10, from: pts[0][0], to: pts[pts.length - 1][0] };
    },
    when(t) { return new Date(t * 1000).toLocaleString('fa-IR', { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' }); },
  }));

  /* jingles and hour announcements: the clips, and how often they air */
  Alpine.data('jingles', () => ({
    d: null, busy: false, timer: 0,
    get r() { return store(); },
    get ready() { return this.d ? this.d.hours.filter(h => h.name).length : 0; },
    async init() {
      this.r.loadAudio();
      await this.load();
      this.timer = setInterval(() => { if (location.hash === '#/jingles') this.load(); }, 5000);
    },
    destroy() { clearInterval(this.timer); },
    async load() { try { this.d = await this.r.call('clips'); } catch { /* toast shown */ } },
    async play(name) {
      if (this.busy || this.d?.manual?.remaining > 0) return;
      this.busy = true;
      try {
        this.d = await this.r.call('clips/play', { name });
        this.r.toast('جینگل روی صدای در حال پخش شروع شد');
      } catch { /* toast shown */ }
      this.busy = false;
    },
    url(kind, name) { return `/api/clips/audio?kind=${kind}&name=${encodeURIComponent(name)}`; },
    hh: h => String(h).padStart(2, '0'),
    listen(kind, name) { this.$refs.player.src = this.url(kind, name); this.$refs.player.play(); },
    async upload(ev, kind, hour) {
      const f = ev.target.files[0];
      ev.target.value = '';
      if (!f) return;
      if (f.size > this.d.max_bytes) return this.r.toast(`حجم فایل بیشتر از ${this.r.fa(Math.round(this.d.max_bytes / 1048576))} مگابایت است`);
      this.busy = true;
      try {
        this.d = await this.r.raw('clips/upload', f, { 'X-Kind': kind, 'X-Hour': String(hour ?? 0), 'X-Filename': encodeURIComponent(f.name) });
        this.r.toast('اضافه شد');
      } catch { /* toast shown */ }
      this.busy = false;
    },
    async remove(kind, name) {
      if (!confirm(`«${name}» پاک شود؟`)) return;
      try { this.d = await this.r.call('clips/delete', { kind, name }); } catch { /* toast shown */ }
    },
  }));

  Alpine.data('settings', () => ({
    d: null,
    get r() { return store(); },
    get dbUrl() { return `http://${location.hostname}:8002`; },
    async init() {
      await this.load();
      setInterval(() => { if (this.tab === 'settings' && !document.hidden) this.r.loadAudio(); }, 10000);   // the loudness count moves while the radio measures
      this.$watch('tab', value => { if (value === 'settings') this.load(); });
    },
    async load() {
      try { this.d = await this.r.call('settings'); this.r.audio = this.d; } catch { /* login screen */ }
    },
    async setCatalog(on) {
      try { this.d = await this.r.call('settings', { catalog_public: on }); this.r.audio = this.d; this.r.toast(on ? 'شنونده‌ها فهرست آهنگ‌ها را می‌بینند' : 'فهرست آهنگ‌ها بسته شد'); } catch { /* toast shown */ }
    },
    async setMode(auto) {
      try { await this.r.call('requests/mode', { mode: auto ? 'auto' : 'manual' }); } catch { /* toast shown */ }
      await this.load();
    },
    // the two lists under the player can be hidden separately; the dashboard edits the same switches
    async saveLists(patch) {
      try {
        const cur = await this.r.call('settings');
        this.d = await this.r.call('settings/lists', { show_next: cur.show_next, show_recent: cur.show_recent, ...patch });
        this.r.audio = this.d;
        this.r.toast('ذخیره شد');
      } catch { /* toast shown */ }
    },
  }));
});
