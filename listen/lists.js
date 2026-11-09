/* The NEXT and LAST boards under the player: each shows one song; a click drops its whole list down under it.
 * One list open at a time; a click elsewhere or Escape closes it. A board with a single song doesn't open. */
window.RadioLists = (() => {
  const boards = [
    { board: document.getElementById('card-next'), face: document.getElementById('next-toggle'), drop: document.getElementById('next-drop') },
    { board: document.getElementById('card-recent'), face: document.getElementById('recent-toggle'), drop: document.getElementById('recent-drop') },
  ];

  function close(item) {
    item.drop.hidden = true;
    item.board.classList.remove('open');
    item.face.setAttribute('aria-expanded', 'false');
  }

  for (const item of boards) {
    item.face.addEventListener('click', () => {
      if (Number(item.board.dataset.count) < 2) return;
      const opening = item.drop.hidden;
      boards.forEach(close);
      if (!opening) return;
      item.drop.hidden = false;
      item.board.classList.add('open');
      item.face.setAttribute('aria-expanded', 'true');
    });
  }
  document.addEventListener('pointerdown', e => { for (const item of boards) if (!item.board.contains(e.target)) close(item); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape') boards.forEach(close); });

  function show(nextCount, recentCount) {
    [nextCount, recentCount].forEach((n, i) => {
      const item = boards[i];
      item.board.dataset.count = String(n);
      item.board.classList.toggle('more', n > 1);
      if (n < 2) close(item);
    });
  }

  return { show };
})();
