// Bluebox docs: the phone menu and the topic search. TOPICS comes from topics.js.
document.documentElement.classList.add('js');
(function () {
  const body = document.body;
  const menu = document.querySelector('.menu');
  if (menu) menu.addEventListener('click', () => {
    const open = body.classList.toggle('nav-open');
    menu.setAttribute('aria-expanded', open);
  });
  document.querySelectorAll('.side a').forEach(a => a.addEventListener('click', () => body.classList.remove('nav-open')));

  // FAQ: the "what's going wrong?" picker shows one group of questions.
  const picker = document.querySelector('.picker');
  if (picker) {
    const showing = document.querySelector('.showing');
    const pick = topic => {
      picker.querySelectorAll('button').forEach(b => b.setAttribute('aria-pressed', b.dataset.topic === topic));
      document.querySelectorAll('.faq-group').forEach(g => { g.hidden = !!topic && g.dataset.topic !== topic; });
      showing.classList.toggle('on', !!topic);
      if (topic) {
        showing.querySelector('span').textContent = picker.querySelector(`[data-topic="${topic}"] b`).textContent;
        const first = document.querySelector(`.faq-group[data-topic="${topic}"]`);
        first.scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    };
    picker.addEventListener('click', e => {
      const b = e.target.closest('button');
      if (b) pick(b.getAttribute('aria-pressed') === 'true' ? null : b.dataset.topic);
    });
    showing.querySelector('button').addEventListener('click', () => pick(null));
  }

  // Step-by-step checkers: one step at a time, "Fixed" or "Next".
  document.querySelectorAll('.checker').forEach(c => {
    const steps = [...c.querySelectorAll('.step')], bar = c.querySelector('.bar i');
    const fixed = c.querySelector('.done.fixed'), stuck = c.querySelector('.done.stuck');
    const show = i => {
      steps.forEach((s, j) => s.classList.toggle('on', j === i));
      fixed.classList.remove('on'); stuck.classList.remove('on');
      if (i >= steps.length) stuck.classList.add('on');
      bar.style.width = Math.min(100, (i / steps.length) * 100) + '%';
    };
    c.addEventListener('click', e => {
      const b = e.target.closest('button'); if (!b) return;
      const at = steps.findIndex(s => s.classList.contains('on'));
      if (b.dataset.do === 'next') show(at + 1);
      else if (b.dataset.do === 'back') show(Math.max(0, at - 1));
      else if (b.dataset.do === 'fixed') { steps.forEach(s => s.classList.remove('on')); fixed.classList.add('on'); bar.style.width = '100%'; }
      else if (b.dataset.do === 'again') show(0);
    });
    show(0);
  });

  const input = document.getElementById('q');
  const box = document.getElementById('results');
  if (!input || !box || typeof TOPICS === 'undefined') return;
  let picked = 0, shown = [];

  const fold = s => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
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
      p.textContent = 'Nothing matches. Try the FAQ or All topics.';
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
    else if (e.key === 'Enter' && shown[picked]) { e.preventDefault(); location.href = shown[picked].u; box.classList.remove('open'); input.blur(); }
    else if (e.key === 'Escape') { input.value = ''; box.classList.remove('open'); input.blur(); }
  });
  document.addEventListener('click', e => { if (!e.target.closest('.search')) box.classList.remove('open'); });
  document.addEventListener('keydown', e => {
    if (e.key === '/' && document.activeElement !== input && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) {
      e.preventDefault(); input.focus();
    }
  });

  // A FAQ link opens its answer.
  function openHash() {
    const el = location.hash && document.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (!el) return;
    const group = el.closest('.faq-group');
    if (group && group.hidden) document.querySelector('.showing button').click();
    if (el.tagName === 'DETAILS') el.open = true;
  }
  window.addEventListener('hashchange', openHash);
  openHash();
})();
