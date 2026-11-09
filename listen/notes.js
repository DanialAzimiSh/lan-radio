/* Details written by the admin for the current track. Text nodes keep notes as plain text. */
window.RadioNotes = (() => {
  const card = document.getElementById('track-notes');
  const description = document.getElementById('track-description');
  const facts = document.getElementById('track-facts');
  let previous = '';

  function show(now, live) {
    const visible = !!now?.file && !now.kind && !live?.airing && !!(now.description || now.facts);
    card.hidden = !visible;
    if (!visible) { previous = ''; return; }
    const key = JSON.stringify([now.file, now.description, now.facts]);
    if (key === previous) return;
    previous = key;
    description.textContent = now.description || '';
    description.hidden = !now.description;
    facts.replaceChildren(...(now.facts || '').split('\n').map(s => s.trim()).filter(Boolean).map(s => {
      const li = document.createElement('li');
      li.textContent = s;
      return li;
    }));
    facts.hidden = !facts.childElementCount;
  }

  return { show };
})();
