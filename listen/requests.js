/* Song requests on the listener page.
 *   search ─> /api/catalog (every track a listener may ask for, fetched once) ─> pick ─> POST /api/request
 *   not found, or the admin keeps the library closed ─> the typed text goes to the admin as a note (POST /api/request with text)
 *   file ─> POST /api/upload (raw body) ─> quarantine until the admin approves it
 *   poll ─> show(now.mine) ─> where each of my requests stands; a change is announced in the hint line
 * The server enforces every limit; the page only reads its answer out loud. */
(function () {
  const $ = s => document.querySelector(s);
  const FA = '۰۱۲۳۴۵۶۷۸۹'; const fa = x => String(x).replace(/\d/g, d => FA[d]);
  const MAX_BYTES = 30 * 1024 * 1024;
  const AUDIO = /\.(mp3|m4a|ogg|oga|opus|flac|wav|aac)$/i;
  const STATE = { pending: 'منتظر تأیید مدیر', queued: 'در صف پخش 🎶', played: 'پخش شد ✅', rejected: 'رد شد', done: 'انجام شد ✅' };
  function store(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } }
  function load(k) { try { return localStorage.getItem(k); } catch { return null; } }
  function say(t) { if (typeof window.hint === 'function') window.hint(t); }

  const openBtn = $('#req-open'); const box = $('#req'); const q = $('#req-q'); const list = $('#req-list');
  const name = $('#req-name'); const mine = $('#req-mine'); const file = $('#req-file'); const bar = $('#req-bar');
  let catalog = null; let loading = false; let seen = new Map(); let open = false;

  // "ي" and "ك" typed on an Arabic keyboard, ZWNJ, diacritics and punctuation must not stop a match
  const norm = s => s.toLowerCase().replace(/ي/g, 'ی').replace(/ك/g, 'ک').replace(/‌/g, '').replace(/\p{M}/gu, '').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
  const label = f => f.split('/').pop().replace(/\.[A-Za-z0-9]+$/, '');
  const folder = f => f.includes('/') ? f.split('/').slice(0, -1).join(' / ') : '';

  async function ensureCatalog() {
    if (!open || catalog || loading) return;
    loading = true;
    try {
      const res = await fetch('/api/catalog' + window.RadioChannel.query);
      const files = res.ok ? await res.json() : [];
      catalog = files.map(f => ({ f, key: norm(f) }));
    } catch { catalog = null; }
    loading = false;
    search();
  }

  function row(text, sub, btn) {
    const li = document.createElement('li');
    const span = document.createElement('span');
    span.textContent = text;
    if (sub) { const s = document.createElement('small'); s.textContent = sub; span.append(s); }
    li.append(span, btn);
    return li;
  }
  function button(text, onclick) {
    const b = document.createElement('button');
    b.type = 'button'; b.textContent = text; b.title = text; b.addEventListener('click', onclick);
    return b;
  }

  function search() {
    list.replaceChildren();
    const words = norm(q.value).split(' ').filter(Boolean);
    if (!words.length) return;
    // library closed: nothing to search, the typed name goes to the admin
    if (!open) { list.append(row(q.value.trim(), 'برای مدیر فرستاده می‌شود', button('ارسال', () => send({ file: '', text: q.value.trim() })))); return; }
    if (!catalog) { const li = document.createElement('li'); li.className = 'none'; li.textContent = 'در حال بارگذاری فهرست…'; list.append(li); return; }
    const hits = catalog.filter(c => words.every(w => c.key.includes(w))).slice(0, 8);
    for (const c of hits) list.append(row(label(c.f), folder(c.f), button('درخواست', () => send({ file: c.f, text: '' }))));
    if (!hits.length) {
      const li = row('پیدا نشد.', '', button('اسمش را برای مدیر بفرست', () => send({ file: '', text: q.value.trim() })));
      li.className = 'none'; list.append(li);
    }
  }

  async function send(body) {
    store('radio.name', name.value.trim());
    try {
      const res = await fetch('/api/request' + window.RadioChannel.query, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ listener: RadioLikes.listenerId, name: name.value.trim(), ...body }) });
      const r = await res.json().catch(() => ({}));
      if (res.ok) {
        say(r.status === 'queued' ? 'درخواستت در صف پخش رفت 🎶' : 'درخواستت ثبت شد، منتظر تأیید مدیر 🙏');
        q.value = ''; list.replaceChildren();
      } else say(r.error || 'نشد ثبت کنم؛ دوباره امتحان کن');
    } catch { say('رادیو در دسترس نیست'); }
  }

  q.addEventListener('input', search);
  openBtn.addEventListener('click', () => { box.hidden = !box.hidden; if (!box.hidden) { ensureCatalog(); q.focus(); } });
  $('#req-close').addEventListener('click', () => { box.hidden = true; });

  file.addEventListener('change', () => {
    const f = file.files[0]; file.value = '';
    if (!f) return;
    if (!AUDIO.test(f.name)) { say('فقط فایل صوتی (mp3، m4a، ogg، flac، wav) را می‌شود فرستاد'); return; }
    if (f.size > MAX_BYTES) { say(`حجم فایل بیشتر از ${fa(30)} مگابایت است`); return; }
    store('radio.name', name.value.trim());
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/upload' + window.RadioChannel.query);
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    xhr.setRequestHeader('X-Listener', RadioLikes.listenerId);
    xhr.setRequestHeader('X-Name', encodeURIComponent(name.value.trim()));
    xhr.setRequestHeader('X-Filename', encodeURIComponent(f.name));
    bar.hidden = false; bar.value = 0;
    xhr.upload.addEventListener('progress', e => { if (e.lengthComputable) bar.value = e.loaded / e.total; });
    xhr.addEventListener('loadend', () => {
      bar.hidden = true;
      let r = {}; try { r = JSON.parse(xhr.responseText); } catch { /* not json: nginx's own page */ }
      if (xhr.status === 200) say('آهنگ فرستاده شد؛ بعد از تأیید مدیر به کتابخانه می‌رود 🎶');
      else if (xhr.status === 413) say(`حجم فایل بیشتر از ${fa(30)} مگابایت است`);
      else if (xhr.status === 429 && !r.error) say('یه کم صبر کن و دوباره بفرست');
      else say(r.error || 'نشد بفرستم؛ دوباره امتحان کن');
    });
    xhr.send(f);
  });

  q.placeholder = 'اسم آهنگ یا خواننده‌ای که می‌خواهی را بنویس…';   // until the radio says the library is open
  name.value = load('radio.name') || '';

  /* items = now.mine: [{ id, label, status }] - announces a change, lists what is still open; isOpen = the
   * admin lets listeners search the library */
  function show(items, isOpen) {
    if (isOpen !== open) {
      open = isOpen;
      q.placeholder = open ? 'اسم آهنگ یا خواننده…' : 'اسم آهنگ یا خواننده‌ای که می‌خواهی را بنویس…';
      if (!box.hidden) { ensureCatalog(); search(); }
    }
    const next = new Map();
    for (const it of items || []) {
      next.set(it.id, it.status);
      if (seen.has(it.id) && seen.get(it.id) !== it.status && STATE[it.status]) say(`«${it.label}» ${STATE[it.status]}`);
    }
    seen = next;
    mine.replaceChildren(...(items || []).map(it => { const li = document.createElement('li'); li.textContent = `${it.label} — ${STATE[it.status] || it.status}`; return li; }));
    mine.hidden = !(items && items.length);
  }

  window.RadioRequests = { show };
})();
