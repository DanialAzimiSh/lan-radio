/* Channel identity and routing for the listener page. The channels sit on a small ruler carousel in the middle of
 * the header (ruler-carousel.js), always open, hidden while the station has only one; a pick switches the stream
 * in place, no reload. */
(() => {
  const channelFromUrl = () => {
    const match = location.pathname.match(/^\/channel\/(\d+)$/);
    const raw = Number(match?.[1] || new URLSearchParams(location.search).get('channel') || 0);
    return Number.isInteger(raw) && raw > 0 ? raw : 0;
  };
  const channel = window.RadioChannel = {
    id: channelFromUrl(),
    get stream() { return this.id ? '/channel-' + this.id : '/stream'; },
    get now() { return this.id ? '/api/channels/listen?channel=' + this.id : '/api/now'; },
    get query() { return this.id ? '?channel=' + this.id : ''; },
  };
  const themeSelect = document.getElementById('theme-select');
  if (themeSelect) themeSelect.addEventListener('change', () => {
    const url = new URL(location.href);
    url.pathname = channel.id ? '/channel/' + channel.id : '/radio';
    url.searchParams.delete('channel');
    url.searchParams.set('theme', themeSelect.value);
    location.assign(url.href);
  });
  const root = document.getElementById('channel-ruler');
  if (!root) return;
  const toggle = document.querySelector('[data-channel-toggle]');
  if (toggle) toggle.disabled = true;
  fetch('/api/channels', { cache: 'no-store' }).then(response => {
    if (!response.ok) throw new Error('channels');
    return response.json();
  }).then(items => {
    if (!Array.isArray(items) || !items.length) return;
    if (!items.some(item => item.id === channel.id)) { location.replace('/radio'); return; }
    function label() {
      const current = items.find(item => item.id === channel.id);
      const brand = document.querySelector('.brand b');
      if (brand) brand.textContent = current.name;
      document.title = current.name + ' · رادیو';
    }
    function select(id, writeHistory = true) {
      const next = items.find(item => item.id === id);
      if (!next || id === channel.id) return;
      channel.id = id;
      if (writeHistory) {
        const url = new URL(location.href);
        url.pathname = id ? '/channel/' + id : '/radio';
        url.searchParams.delete('channel');
        history.pushState({}, '', url.pathname + url.search);
      }
      label();
      ruler.setSelectedId(id);
      if (toggle) { root.hidden = true; toggle.setAttribute('aria-expanded', 'false'); toggle.focus(); }
      window.dispatchEvent(new CustomEvent('radio:channel-changed', { detail: { id, name: next.name } }));
    }
    label();
    root.hidden = !!toggle || items.length < 2;
    const ruler = window.createRulerCarousel(root, items.map(item => ({ id: item.id, title: item.name })), {
      selectedId: channel.id,
      onSelect: id => select(id),
    });
    const life = new AbortController();
    if (toggle) {
      toggle.disabled = items.length < 2;
      const close = () => { root.hidden = true; toggle.setAttribute('aria-expanded', 'false'); ruler.setSelectedId(channel.id); };
      toggle.addEventListener('click', () => {
        root.hidden = !root.hidden;
        toggle.setAttribute('aria-expanded', String(!root.hidden));
        if (!root.hidden) { ruler.refresh(); root.querySelector('.ruler-viewport')?.focus(); }
      }, { signal: life.signal });
      document.addEventListener('pointerdown', e => { if (!root.contains(e.target) && !toggle.contains(e.target)) close(); }, { signal: life.signal });
      document.addEventListener('keydown', e => { if (e.key === 'Escape' && !root.hidden) { close(); toggle.focus(); } }, { signal: life.signal });
    }
    window.addEventListener('popstate', () => select(channelFromUrl(), false), { signal: life.signal });
    window.addEventListener('pagehide', event => {
      if (!event.persisted) { ruler.destroy(); life.abort(); }
    }, { signal: life.signal });
  }).catch(() => { root.hidden = true; });
})();
