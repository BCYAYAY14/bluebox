// Bluebox docs: the phone menu, the search in the top bar, the FAQ filter, and links that open folded sections.
// TOPICS comes from topics.js.
document.documentElement.classList.add('js');
(function () {
  const body = document.body;
  const menu = document.querySelector('.menu');
  if (menu) menu.addEventListener('click', () => {
    const open = body.classList.toggle('nav-open');
    menu.setAttribute('aria-expanded', open);
  });
  document.querySelectorAll('.side a').forEach(a => a.addEventListener('click', () => body.classList.remove('nav-open')));

  const fold = s => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[’‘]/g, "'");

  // A link to a section inside "Technical details" (or to a FAQ answer) opens it.
  function openHash() {
    const el = location.hash && document.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (!el) return;
    const group = el.closest('.faq-group');
    if (group && (group.hidden || el.hidden)) showAll();
    for (let d = el.closest('details'); d; d = d.parentElement.closest('details')) d.open = true;
    if (el.tagName === 'DETAILS') el.open = true;
    el.scrollIntoView();
  }

  // FAQ: the search box and topic chips filter the questions as you type.
  const fq = document.getElementById('faq-q');
  const chips = document.querySelector('.chips');
  let showAll = () => {};
  if (fq && chips) {
    const items = [...document.querySelectorAll('details.qa')];
    const text = new Map(items.map(d => [d, fold(d.textContent + ' ' + (d.dataset.k || ''))]));
    const count = document.querySelector('.faq-count'), empty = document.querySelector('.faq-empty');
    let topic = '';
    const apply = () => {
      const words = fold(fq.value).split(/\s+/).filter(Boolean);
      let n = 0;
      items.forEach(d => {
        const g = d.closest('.faq-group');
        const show = (!topic || g.dataset.topic === topic) && words.every(w => text.get(d).includes(w));
        d.hidden = !show; if (show) n++;
      });
      // A search down to a few questions shows their answers straight away.
      if (words.length && n <= 3) items.forEach(d => { if (!d.hidden) d.open = true; });
      document.querySelectorAll('.faq-group').forEach(g => { g.hidden = !g.querySelector('details.qa:not([hidden])'); });
      count.textContent = words.length || topic ? `${n} question${n === 1 ? '' : 's'}` : '';
      empty.hidden = n > 0;
    };
    chips.addEventListener('click', e => {
      const b = e.target.closest('button'); if (!b) return;
      topic = b.dataset.topic || '';
      chips.querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', x === b));
      apply();
    });
    fq.addEventListener('input', apply);
    fq.addEventListener('keydown', e => { if (e.key === 'Escape') { fq.value = ''; apply(); } });
    showAll = () => { fq.value = ''; topic = ''; chips.querySelectorAll('button').forEach((x, i) => x.setAttribute('aria-pressed', i === 0)); apply(); };
  }
  window.addEventListener('hashchange', openHash);
  openHash();

  // The search in the top bar: every page, section, technical detail and FAQ question.
  const input = document.getElementById('q');
  const box = document.getElementById('results');
  if (!input || !box || typeof TOPICS === 'undefined') return;
  let picked = 0, shown = [];
  function score(t, words) {
    const title = fold(t.t), all = title + ' ' + fold(t.p) + ' ' + fold(t.k || '');
    let s = 0;
    for (const w of words) {
      if (!all.includes(w)) return 0;
      s += title.startsWith(w) ? 4 : title.includes(w) ? 3 : 1;
    }
    return s + (t.q ? 0.5 : 0);
  }
  function render() {
    const words = fold(input.value).split(/\s+/).filter(Boolean);
    if (!words.length) { box.classList.remove('open'); return; }
    shown = TOPICS.map(t => [score(t, words), t]).filter(x => x[0] > 0)
      .sort((a, b) => b[0] - a[0]).slice(0, 12).map(x => x[1]);
    picked = 0;
    box.textContent = '';
    if (!shown.length) {
      const p = document.createElement('p');
      p.textContent = 'Nothing matches. Try the FAQ or the Help page.';
      box.append(p);
    }
    shown.forEach((t, i) => {
      const a = document.createElement('a');
      a.href = t.u;
      a.textContent = t.t;
      const small = document.createElement('small');
      small.textContent = t.p;
      a.append(small);
      if (i === 0) a.className = 'sel';
      a.addEventListener('click', () => { box.classList.remove('open'); setTimeout(openHash, 0); });
      box.append(a);
    });
    box.classList.add('open');
  }
  function select(i) {
    const links = box.querySelectorAll('a');
    if (!links.length) return;
    picked = (i + links.length) % links.length;
    links.forEach((a, j) => a.classList.toggle('sel', j === picked));
    links[picked].scrollIntoView({ block: 'nearest' });
  }
  input.addEventListener('input', render);
  input.addEventListener('focus', render);
  input.addEventListener('keydown', e => {
    if (e.key === 'ArrowDown') { e.preventDefault(); select(picked + 1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); select(picked - 1); }
    else if (e.key === 'Enter' && shown[picked]) { e.preventDefault(); location.href = shown[picked].u; box.classList.remove('open'); input.blur(); setTimeout(openHash, 0); }
    else if (e.key === 'Escape') { input.value = ''; box.classList.remove('open'); input.blur(); }
  });
  document.addEventListener('click', e => { if (!e.target.closest('.search')) box.classList.remove('open'); });
  document.addEventListener('keydown', e => {
    if (e.key === '/' && document.activeElement !== input && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) {
      e.preventDefault(); input.focus();
    }
  });
})();
