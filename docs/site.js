// Thermo site: copy buttons, tabs, scroll reveal, a simulated live HUD, and the agent terminal demo.
(() => {
  const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Copy buttons on code blocks
  $$('pre').forEach(p => {
    const b = document.createElement('button'); b.className = 'copy'; b.textContent = 'Copy';
    b.onclick = () => {
      const text = [...p.childNodes].filter(n => n !== b).map(n => n.textContent).join('').trim();
      navigator.clipboard.writeText(text).then(() => { b.textContent = 'Copied'; setTimeout(() => b.textContent = 'Copy', 1300); });
    };
    p.appendChild(b);
  });

  // Segmented tabs: <div class="seg" data-group="x"> buttons[data-t] ; panes .pane[data-group="x"][data-t]
  $$('.seg').forEach(seg => {
    const g = seg.dataset.group;
    $$('button', seg).forEach(btn => btn.onclick = () => {
      $$('button', seg).forEach(x => x.setAttribute('aria-selected', x === btn));
      $$(`.pane[data-group="${g}"]`).forEach(p => p.classList.toggle('on', p.dataset.t === btn.dataset.t));
    });
  });

  // Scroll reveal
  const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); e.target.dispatchEvent(new Event('reveal')); io.unobserve(e.target); } }), { threshold: .18 });
  $$('.rv').forEach(el => io.observe(el));

  // Simulated live readings (gentle random walk, like the real app's 2 s refresh)
  const live = { cpu: 23, ram: 61, gpu: 34, temp: 52 };
  const walk = (v, lo, hi, s) => Math.min(hi, Math.max(lo, v + (Math.random() - .5) * s));
  const hud = $('.hud');
  function paint() {
    live.cpu = walk(live.cpu, 8, 78, 14); live.ram = walk(live.ram, 52, 74, 3); live.gpu = walk(live.gpu, 10, 88, 16); live.temp = walk(live.temp, 44, 74, 3);
    $$('[data-live]').forEach(el => {
      const k = el.dataset.live, v = live[k];
      if (el.classList.contains('ring')) el.style.setProperty('--v', v.toFixed(0));
      else if (el.tagName === 'I') el.style.width = (k === 'temp' ? (v - 25) / 70 * 100 : v) + '%';
      else el.textContent = Math.round(v) + (k === 'temp' ? '°' : '%');
    });
  }
  if ($('[data-live]')) { paint(); if (!reduce) setInterval(paint, 1600); }

  // HUD: expands on click/hover, and demos itself once in view
  if (hud) {
    let user = false;
    const set = o => hud.classList.toggle('open', o);
    hud.addEventListener('mouseenter', () => { user = true; set(true); });
    hud.addEventListener('mouseleave', () => set(false));
    hud.addEventListener('click', () => { user = true; set(!hud.classList.contains('open')); });
    if (!reduce) {
      setTimeout(function loop() { if (!user) { set(true); setTimeout(() => { if (!user) set(false); }, 3800); setTimeout(loop, 7600); } }, 1800);
    }
  }

  // Per-part temperatures: fill bars on reveal, then drift
  const temps = $('#temps');
  if (temps) {
    const parts = [...$$('.p', temps)];
    const draw = () => parts.forEach(p => {
      const base = +p.dataset.v, hot = +p.dataset.hot, v = base + (Math.random() - .5) * 3;
      const c = v >= hot ? 'var(--hot)' : v >= hot - 15 ? 'var(--warm)' : 'var(--cool)';
      $('i', p).style.cssText = `width:${Math.max(6, (v - 20) / (hot - 20) * 100)}%;background:${c}`;
      $('b', p).textContent = Math.round(v) + '°'; $('b', p).style.color = c;
    });
    temps.addEventListener('reveal', () => { draw(); if (!reduce) setInterval(draw, 2200); });
  }

  // Sparklines: <svg class="spark" data-seed="3" data-color="#38d6ff">
  $$('svg.spark').forEach(svg => {
    let seed = +svg.dataset.seed || 1; const rnd = () => (seed = (seed * 9301 + 49297) % 233280) / 233280;
    const n = 60, pts = []; let v = 40;
    for (let i = 0; i < n; i++) { v = Math.min(92, Math.max(8, v + (rnd() - .48) * 16 + (i > 30 && i < 38 ? 9 : 0))); pts.push(v); }
    const W = 600, H = 110, x = i => i / (n - 1) * W, y = v => H - v / 100 * H;
    const d = pts.map((v, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join('');
    const c = svg.dataset.color || '#38d6ff', id = 'g' + Math.random().toString(36).slice(2);
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('preserveAspectRatio', 'none');
    svg.innerHTML = `<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${c}" stop-opacity=".45"/><stop offset="1" stop-color="${c}" stop-opacity="0"/></linearGradient></defs>
      <path d="${d}L${W},${H}L0,${H}Z" fill="url(#${id})"/><path d="${d}" fill="none" stroke="${c}" stroke-width="2.2" vector-effect="non-scaling-stroke" stroke-linejoin="round"/>`;
  });

  // Agent terminal demo: <div class="body" data-script='[["u","text"],["tool","..."],...]'>
  $$('.term .body[data-script]').forEach(body => {
    const script = JSON.parse(body.dataset.script);
    let started = false;
    const run = async () => {
      if (started) return; started = true;
      const sleep = ms => new Promise(r => setTimeout(r, reduce ? 0 : ms));
      while (true) {
        body.innerHTML = '';
        for (const [cls, text, pause = 500] of script) {
          const line = document.createElement('div'); line.className = cls; body.appendChild(line);
          if (cls === 'u' && !reduce) { for (const ch of text) { line.textContent += ch; await sleep(28); } }
          else line.textContent = text;
          await sleep(pause);
        }
        const cur = document.createElement('span'); cur.className = 'cursor'; body.appendChild(cur);
        if (reduce) return;
        await sleep(6000);
      }
    };
    const t = body.closest('.term');
    new IntersectionObserver((es, o) => es.forEach(e => { if (e.isIntersecting) { run(); o.disconnect(); } }), { threshold: .3 }).observe(t);
  });
})();

// Share buttons: native share sheet where available (phones, Safari), otherwise copy the link.
(() => {
  const icon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="m7 8 5-5 5 5"/><path d="M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7"/></svg>';
  const toast = document.createElement('div'); toast.className = 'toast'; document.body.appendChild(toast);
  const say = t => { toast.textContent = t; toast.classList.add('on'); setTimeout(() => toast.classList.remove('on'), 1800); };
  document.querySelectorAll('[data-share]').forEach(b => {
    b.innerHTML = icon + (b.textContent.trim() || 'Share');
    b.addEventListener('click', async () => {
      const url = b.dataset.url || location.href.split('#')[0];
      const data = { title: document.title, text: b.dataset.text || 'Mac stats, right on your notch. Free and open source:', url };
      if (navigator.share) { try { await navigator.share(data); return; } catch (e) { if (e.name === 'AbortError') return; } }
      try { await navigator.clipboard.writeText(url); say('Link copied'); } catch { prompt('Copy this link:', url); }
    });
  });
})();
