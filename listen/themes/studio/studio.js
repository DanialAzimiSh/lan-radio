/* Additional artwork uses the same public response as the shared player. No stock covers. */
(() => {
  const artwork = document.getElementById('studio-cover');
  const next = document.getElementById('studio-next-cover');
  const later = document.getElementById('studio-later-cover');
  const watermark = document.getElementById('studio-watermark');
  let artist = null;
  function artistName(value) {
    if (value === artist) return;
    artist = value;
    const track = document.createElement('span');
    track.className = 'studio-watermark-track';
    for (let i = 0; i < 2; i++) {
      const name = document.createElement('span');
      name.dir = 'auto';
      name.textContent = value;
      track.append(name);
    }
    watermark.replaceChildren(track);
    watermark.hidden = !value;
  }
  function cover(img, file) {
    if (img.dataset.file === file) return;
    img.dataset.file = file;
    img.hidden = true;
    img.removeAttribute('src');
    if (!file) return;
    img.onload = () => { img.hidden = false; };
    img.onerror = () => { img.hidden = true; };
    img.src = '/api/cover?f=' + encodeURIComponent(file);
  }
  window.addEventListener('radio:now', ({ detail }) => {
    const live = detail.live?.airing;
    cover(artwork, live ? '' : detail.now.file || '');
    const coming = detail.lists?.next === false ? [] : detail.upcoming || [];
    cover(next, coming[0]?.file || '');
    cover(later, coming[1]?.file || '');
    artistName(live ? 'ON AIR' : detail.now.artist || 'VINYL');
  });
  window.addEventListener('radio:channel-changed', () => {
    [artwork, next, later].forEach(img => cover(img, ''));
    artistName('');
  });
})();
