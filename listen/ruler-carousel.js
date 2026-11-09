/* Framework-free counterpart of the supplied RulerCarousel, using the site's bundled GSAP. */
window.createRulerCarousel = function (root, items, { selectedId, onSelect = () => {} } = {}) {
  const count = items.length;
  if (!count) { root.hidden = true; return { setSelectedId() {}, refresh() {}, destroy() {} }; }
  const life = new AbortController();
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const mod = index => ((index % count) + count) % count;
  const copies = count > 1 ? 3 : 1;
  const middle = count > 1 ? count : 0;
  let activeIndex = middle + Math.max(0, items.findIndex(item => item.id === selectedId));
  let width = 0, step = 0, tween = null, settleTimer = 0, clickTimer = 0;
  let drag = null, suppressClick = false, destroyed = false;
  const node = (tag, cls, text) => {
    const element = document.createElement(tag);
    if (cls) element.className = cls;
    if (text) element.textContent = text;
    return element;
  };
  function lines(bottom = false) {
    const ruler = node('div', 'ruler-lines' + (bottom ? ' bottom' : ''));
    ruler.setAttribute('aria-hidden', 'true');
    for (let i = 0; i <= 80; i++) {
      const mark = node('span', 'ruler-line' + (i === 40 ? ' center' : i % 5 === 0 ? ' major' : ''));
      mark.style.left = (i / 80 * 100) + '%';
      ruler.append(mark);
    }
    return ruler;
  }
  root.setAttribute('role', 'group');
  root.setAttribute('aria-roledescription', 'کاروسل');
  const viewport = node('div', 'ruler-viewport');
  viewport.tabIndex = 0;
  viewport.setAttribute('aria-label', 'انتخاب کانال با کشیدن یا کلیدهای چپ و راست');
  const track = node('div', 'ruler-track');
  const buttons = [];
  for (let copy = 0; copy < copies; copy++) {
    items.forEach((item, originalIndex) => {
      const button = node('button', 'ruler-item', item.title);
      button.type = 'button';
      button.dir = 'auto';
      button.title = item.title;
      button.tabIndex = -1;
      if (copies > 1 && copy !== 1) button.setAttribute('aria-hidden', 'true');
      button.addEventListener('click', () => {
        if (suppressClick) return;
        const candidates = Array.from({ length: copies }, (_, set) => originalIndex + set * count);
        activeIndex = candidates.reduce((best, index) => Math.abs(index - activeIndex) < Math.abs(best - activeIndex) ? index : best);
        render(true, true);
      }, { signal: life.signal });
      buttons.push(button);
      track.append(button);
    });
  }
  viewport.append(track);
  const controls = node('div', 'ruler-controls');
  const control = (label, path) => {
    const button = node('button', 'ruler-control');
    button.type = 'button';
    button.disabled = count < 2;
    button.setAttribute('aria-label', label);
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    const shape = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    shape.setAttribute('d', path);
    svg.append(shape); button.append(svg);
    return button;
  };
  const previous = control('کانال قبلی', 'm11 19-9-7 9-7v14Zm11 0-9-7 9-7v14Z');
  const next = control('کانال بعدی', 'm2 5 9 7-9 7V5Zm11 0 9 7-9 7V5Z');
  const pages = node('div', 'ruler-pages');
  const currentPage = node('span', 'ruler-page-current');
  pages.append(currentPage, node('span', '', '/'), node('span', '', String(count)));
  const status = node('p', 'ruler-status');
  status.setAttribute('aria-live', 'polite');
  status.setAttribute('aria-atomic', 'true');
  controls.append(previous, pages, next);
  root.replaceChildren(node('p', 'ruler-label', 'کانال‌ها'), lines(), viewport, lines(true), controls, status);

  const xFor = index => viewport.clientWidth / 2 - width / 2 - index * step;
  function stopMotion() {
    tween?.kill(); tween = null;
    clearTimeout(settleTimer);
  }
  function setX(x) {
    if (window.gsap) window.gsap.set(track, { x });
    else track.style.transform = 'translate3d(' + x + 'px,0,0)';
  }
  function paint() {
    buttons.forEach((button, index) => {
      const active = index === activeIndex;
      button.classList.toggle('is-active', active);
      button.setAttribute('aria-current', String(mod(index) === mod(activeIndex)));
      button.tabIndex = index === middle + mod(activeIndex) ? 0 : -1;
    });
    currentPage.textContent = String(mod(activeIndex) + 1);
    status.textContent = items[mod(activeIndex)].id === selectedId ? 'کانال انتخاب‌شده' : 'در حال تغییر کانال…';
  }
  function settle(commit) {
    if (destroyed) return;
    // Recenter in the middle copy after the spring ends, so wrapping has no visible jump.
    activeIndex = middle + mod(activeIndex);
    setX(xFor(activeIndex));
    paint();
    if (commit) {
      const item = items[mod(activeIndex)];
      if (item.id !== selectedId) { selectedId = item.id; onSelect(item.id); }
      status.textContent = 'کانال انتخاب‌شده: ' + item.title;
    }
  }
  function render(animate, commit) {
    stopMotion();
    paint();
    const x = xFor(activeIndex);
    if (animate && !reduced.matches && window.gsap) {
      tween = window.gsap.to(track, { x, duration: .68, ease: 'elastic.out(1,0.75)', onComplete: () => settle(commit) });
    } else {
      setX(x);
      if (commit) settleTimer = setTimeout(() => settle(true), 0);
    }
  }
  function move(delta) {
    if (count < 2) return;
    activeIndex += delta;
    if (activeIndex < 0 || activeIndex >= count * copies) activeIndex = middle + mod(activeIndex);
    render(true, true);
  }
  function measure() {
    if (!viewport.clientWidth) return;
    width = buttons[0].offsetWidth;
    step = width + (parseFloat(getComputedStyle(track).columnGap) || 0);
    activeIndex = middle + Math.max(0, items.findIndex(item => item.id === selectedId));
    render(false, false);
  }
  previous.addEventListener('click', () => move(-1), { signal: life.signal });
  next.addEventListener('click', () => move(1), { signal: life.signal });
  root.addEventListener('keydown', event => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    event.preventDefault();
    move(event.key === 'ArrowLeft' ? -1 : 1);
  }, { signal: life.signal });
  viewport.addEventListener('pointerdown', event => {
    if (count < 2 || !event.isPrimary || (event.pointerType === 'mouse' && event.button !== 0)) return;
    stopMotion();
    drag = { x: event.clientX, y: event.clientY, offset: track.getBoundingClientRect().left - viewport.getBoundingClientRect().left, moved: false, delta: 0 };
  }, { signal: life.signal });
  viewport.addEventListener('pointermove', event => {
    if (!drag) return;
    const delta = event.clientX - drag.x;
    if (!drag.moved && Math.abs(event.clientY - drag.y) > Math.abs(delta) + 8) { drag = null; render(true, true); return; }
    if (!drag.moved && Math.abs(delta) > 8) { drag.moved = true; viewport.setPointerCapture(event.pointerId); viewport.classList.add('dragging'); }
    if (!drag.moved) return;
    event.preventDefault();
    drag.delta = delta;
    setX(drag.offset + delta);
  }, { signal: life.signal });
  function release(event) {
    if (!drag) return;
    const last = drag; drag = null;
    viewport.classList.remove('dragging');
    if (viewport.hasPointerCapture(event.pointerId)) viewport.releasePointerCapture(event.pointerId);
    if (last.moved) {
      suppressClick = true;
      clearTimeout(clickTimer);
      clickTimer = setTimeout(() => { suppressClick = false; }, 0);
      const delta = Math.abs(last.delta) > 35 ? Math.round(-last.delta / step) || Math.sign(-last.delta) : 0;
      move(delta);
    } else render(true, true);
  }
  viewport.addEventListener('pointerup', release, { signal: life.signal });
  viewport.addEventListener('pointercancel', release, { signal: life.signal });
  const observer = new ResizeObserver(measure);
  observer.observe(viewport);
  measure();
  return {
    refresh: measure,
    setSelectedId(id) {
      const index = items.findIndex(item => item.id === id);
      if (index < 0) return;
      selectedId = id;
      activeIndex = middle + index;
      render(false, false);
    },
    destroy() { destroyed = true; stopMotion(); clearTimeout(clickTimer); observer.disconnect(); life.abort(); },
  };
};
