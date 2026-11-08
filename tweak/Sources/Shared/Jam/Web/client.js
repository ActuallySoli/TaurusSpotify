'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const text = (id, value) => { $(id).textContent = value || ''; };
  const save = (key, value) => { try { localStorage.setItem(key, value); } catch (_) {} };
  const read = key => { try { return localStorage.getItem(key); } catch (_) { return null; } };
  const validCover = value => typeof value === 'string' && /^https:\/\/i\.scdn\.co\/image\/[a-fA-F0-9]{32,128}$/.test(value);
  const trackLink = uri => typeof uri === 'string' && /^spotify:track:[A-Za-z0-9]{22}$/.test(uri) ? 'https://open.spotify.com/track/' + uri.slice(14) : null;
  const guest = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 14);
  const clocks = new Set(), sources = new Set();
  let snapshot = null, receivedAt = 0, session = '', online = false, loading = false, adding = false;
  let wanted = false, context = null, gain = null, nextAt = 0, epoch = 0, sequence = 0, audioRun = 0, audioRevision = 0;
  let audioFetch = null, stateFetch = null, failures = 0, destroyed = false, listCache = new Map();
  $('name').value = (read('webjam.name') || '').slice(0, 32);
  const storedVolume = Number(read('webjam.volume') ?? 75);
  $('volume').value = Number.isFinite(storedVolume) ? Math.max(0, Math.min(100, storedVolume)) : 75;
  function volume() {
    const value = Number($('volume').value);
    text('volumeValue', value + '%'); save('webjam.volume', String(value));
    if (gain && context) gain.gain.setTargetAtTime(value / 100, context.currentTime, 0.015);
  }
  $('volume').addEventListener('input', volume); volume();
  $('name').addEventListener('change', () => { save('webjam.name', $('name').value.trim()); load(); });
  function say(message, error = false) { text('msg', message); $('msg').dataset.error = String(error); }
  function status(message) { text('audioNote', message); }
  const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function request(path, options = {}, timeout = 6000, type = 'json') {
    const controller = new AbortController();
    if (type === 'audio') audioFetch = controller;
    else if (path.startsWith('/state')) stateFetch = controller;
    const timer = setTimeout(() => controller.abort(), timeout);
    try {
      const response = await fetch(path, {...options, credentials: 'omit', cache: 'no-store', signal: controller.signal});
      if (type === 'audio') {
        if (response.status === 204) return null;
        if (!response.ok) throw new Error('Audio connection interrupted.');
        const bytes = await response.arrayBuffer();
        if (bytes.byteLength < 60 || bytes.byteLength > 200000) throw new Error('The audio packet is invalid.');
        return bytes;
      }
      const data = await response.json().catch(() => { throw new Error('The host returned an unreadable response.'); });
      if (!response.ok) throw new Error(data.error || 'The host could not complete this request.');
      return data;
    } catch (error) {
      if (error.name === 'AbortError') throw new Error('The host took too long. Check the queue before retrying.');
      if (error instanceof TypeError) throw new Error('Cannot reach the host. Stay on the same Wi-Fi and keep Spotify open.');
      throw error;
    } finally {
      clearTimeout(timer);
      if (audioFetch === controller) audioFetch = null;
      if (stateFetch === controller) stateFetch = null;
    }
  }
  function row(item, index, mode) {
    const li = document.createElement('li'), number = document.createElement('span');
    number.className = 'index'; number.textContent = mode === 'queue' ? String(index + 1) : item.kind === 'playlist' ? '≡' : '♪';
    number.setAttribute('aria-hidden', 'true');
    const copy = document.createElement('div'); copy.className = 'copy';
    const title = document.createElement('p'); title.className = 'song'; title.textContent = item.title || 'Requested song';
    const detail = document.createElement('p'); detail.className = 'detail';
    const artist = item.artist && item.artist !== 'Guest' ? item.artist : '';
    detail.textContent = mode === 'recent' ? artist : [item.kind === 'playlist' ? 'Playlist' : artist, 'From ' + (item.by || 'Guest')].filter(Boolean).join(' · ');
    copy.append(title, detail); li.append(number, copy);
    if (mode === 'requests') {
      const badge = document.createElement('span'); badge.className = 'badge';
      const value = ['Queued', 'Playing', 'Played', 'Unavailable'].includes(item.status) ? item.status : 'Queued';
      badge.textContent = value; badge.dataset.status = value; li.appendChild(badge);
    }
    return li;
  }
  function list(id, empty, items, mode) {
    const safe = Array.isArray(items) ? items.slice(0, 100) : [];
    const signature = JSON.stringify(safe);
    if (listCache.get(id) !== signature) {
      const fragment = document.createDocumentFragment();
      safe.forEach((item, i) => fragment.appendChild(row(item || {}, i, mode)));
      $(id).replaceChildren(fragment); listCache.set(id, signature);
    }
    $(empty).hidden = safe.length > 0;
  }
  function render(data) {
    if (session && data.session && session !== data.session) {
      stopAudio('The host started a new session. Tap Start listening to join it.'); listCache.clear();
    }
    session = data.session || session; snapshot = data; receivedAt = performance.now();
    const now = data.now || {};
    text('nowTitle', now.title || 'Your listening room'); text('nowArtist', now.artist || 'Waiting for the host');
    text('nowState', data.playing ? 'Host is playing' : 'Host is paused');
    if (validCover(now.art)) { if ($('art').getAttribute('src') !== now.art) $('art').src = now.art; $('art').hidden = false; }
    else { $('art').hidden = true; $('art').removeAttribute('src'); }
    const link = trackLink(now.uri); $('trackLink').hidden = !link;
    if (link) $('trackLink').href = link; else $('trackLink').removeAttribute('href');
    list('queue', 'empty', data.queue, 'queue'); list('requests', 'requestsEmpty', data.requests, 'requests'); list('recent', 'recentEmpty', data.recent, 'recent');
    text('count', data.queue && data.queue.length ? String(data.queue.length) : '');
    const guests = Array.isArray(data.guests) ? data.guests.slice(0, 64) : [];
    text('guestCount', guests.length > 1 ? guests.length + ' guests' : 'Just you');
    text('guestList', guests.length ? guests.map(g => (g.name || 'Guest') + (g.listening ? ' — listening' : '')).join(', ') : 'You are in the room.');
    text('hostStatus', data.status || '');
    if (wanted && data.audio && epoch && data.audio.epoch !== epoch) resetScheduled();
    if (wanted && !data.playing) { resetScheduled(); status('The host paused. Listening resumes with the music.'); }
    progress();
  }
  function time(value) { value = Math.max(0, Math.floor(Number(value) || 0)); return Math.floor(value / 60) + ':' + String(value % 60).padStart(2, '0'); }
  function progress() {
    if (!snapshot) return;
    const duration = Math.max(0, Number(snapshot.duration) || 0);
    const elapsed = snapshot.playing && online ? Math.min(3, (performance.now() - receivedAt) / 1000) * (Number(snapshot.speed) || 1) : 0;
    const position = Math.min(duration, Math.max(0, (Number(snapshot.position) || 0) + elapsed));
    const percent = duration ? position / duration * 100 : 0;
    $('progressFill').style.width = percent + '%'; $('progress').setAttribute('aria-valuenow', String(Math.round(percent)));
    text('position', time(position)); text('duration', time(duration));
  }
  async function load() {
    if (loading || destroyed || (document.hidden && !wanted)) return;
    loading = true;
    try {
      const params = new URLSearchParams({guest, name: $('name').value.trim() || 'Guest', listening: wanted ? '1' : '0'});
      const data = await request('/state?' + params);
      if (destroyed) return;
      online = true; failures = 0; $('connection').dataset.online = 'true'; text('connectionText', 'In the room'); render(data);
    } catch (_) {
      if (destroyed) return;
      online = false; failures++; $('connection').dataset.online = 'false'; text('connectionText', 'Reconnecting');
      text('nowState', 'Host unreachable'); $('art').hidden = true;
      if (failures >= 3 && wanted) stopAudio('Host unreachable. Reopen the current Web Jam link and try listening again.');
    } finally { loading = false; }
  }
  function resetScheduled() {
    audioRevision++;
    for (const node of sources) { try { node.stop(); } catch (_) {} node.disconnect(); }
    sources.clear(); nextAt = 0; epoch = 0; sequence = 0;
  }
  function stopAudio(message) {
    wanted = false; audioRun++; if (audioFetch) audioFetch.abort(); resetScheduled();
    const old = context; context = gain = null;
    if (old) { old.onstatechange = null; old.close().catch(() => {}); }
    $('listen').dataset.listening = 'false'; $('listen').disabled = false; text('listenLabel', 'Start listening');
    status(message || 'Hear the host here, with a short Wi-Fi delay.');
  }
  async function pump(run) {
    let misses = 0;
    while (wanted && run === audioRun && !destroyed) {
      if (!context || context.state !== 'running') { await delay(200); continue; }
      if (snapshot && !snapshot.playing) { await delay(200); continue; }
      if (nextAt - context.currentTime > 0.9) { await delay(80); continue; }
      try {
        const revision = audioRevision;
        const bytes = await request('/audio?epoch=' + epoch + '&after=' + sequence, {}, 3500, 'audio');
        if (!wanted || run !== audioRun || !context) return;
        if (!bytes) {
          if (nextAt <= context.currentTime) status(snapshot && snapshot.audio && !snapshot.audio.supported ? 'Waiting for local audio. The host may need to play on this iPhone.' : 'Waiting for the host’s audio…');
          await delay(80); continue;
        }
        const view = new DataView(bytes);
        if (view.getUint32(0, false) !== 0x574a414d) throw new Error('The audio packet is invalid.');
        const incomingEpoch = view.getUint32(4, true), incomingSequence = view.getUint32(8, true), reset = view.getUint32(12, true);
        if (!incomingSequence || (!reset && epoch === incomingEpoch && incomingSequence !== sequence + 1)) throw new Error('Audio sequence changed.');
        const active = context;
        const buffer = await active.decodeAudioData(bytes.slice(16));
        if (!wanted || run !== audioRun || context !== active) return;
        if (revision !== audioRevision || (snapshot && !snapshot.playing) ||
            (snapshot && snapshot.audio && snapshot.audio.epoch > incomingEpoch)) continue;
        if (reset || incomingEpoch !== epoch) resetScheduled();
        epoch = incomingEpoch; sequence = incomingSequence;
        if (buffer.duration <= 0 || buffer.duration > 0.5) throw new Error('The audio packet is invalid.');
        if (!nextAt || nextAt < active.currentTime + 0.025) {
          for (const node of sources) { try { node.stop(); } catch (_) {} node.disconnect(); }
          sources.clear(); nextAt = active.currentTime + 0.3;
        }
        const node = active.createBufferSource(); node.buffer = buffer; node.connect(gain);
        node.onended = () => { sources.delete(node); node.disconnect(); };
        sources.add(node); node.start(nextAt); nextAt += buffer.duration;
        misses = 0; status('Listening live. A short delay keeps your audio smooth.');
      } catch (error) {
        if (!wanted || run !== audioRun) return;
        resetScheduled(); misses++;
        if (misses >= 3) { stopAudio('Audio interrupted. Tap Start listening to reconnect.'); return; }
        status('Reconnecting to the host’s audio…'); await delay(600);
      }
    }
  }
  $('listen').addEventListener('click', async () => {
    if (wanted && context && context.state !== 'running') {
      try { await context.resume(); text('listenLabel', 'Stop listening'); } catch (_) { stopAudio('Your browser could not resume audio. Tap to try again.'); }
      return;
    }
    if (wanted) { stopAudio(); load(); return; }
    const Audio = window.AudioContext || window.webkitAudioContext;
    if (!Audio) { status('This browser does not support live audio. Try Safari or Chrome.'); return; }
    const run = ++audioRun; $('listen').disabled = true;
    try {
      context = new Audio({latencyHint: 'playback'}); gain = context.createGain(); gain.connect(context.destination); volume();
      await context.resume();
      if (run !== audioRun || destroyed) return;
      wanted = true; $('listen').dataset.listening = 'true'; text('listenLabel', 'Stop listening'); status('Connecting your audio…');
      context.onstatechange = () => {
        if (!wanted || !context) return;
        if (context.state !== 'running') { resetScheduled(); text('listenLabel', 'Resume listening'); status('Your browser paused audio. Tap Resume listening.'); }
        else text('listenLabel', 'Stop listening');
      };
      pump(run); load();
    } catch (_) { stopAudio('Audio could not start. Tap to try again.'); }
    finally { $('listen').disabled = false; }
  });
  $('add').addEventListener('submit', async event => {
    event.preventDefault(); if (adding || destroyed) return;
    const value = $('url').value.trim(); if (!value) { say('Paste a Spotify song or playlist link first.', true); return; }
    adding = true; $('send').disabled = true; $('add').setAttribute('aria-busy', 'true'); say('Sending your request…');
    const name = $('name').value.trim() || 'Guest'; save('webjam.name', $('name').value.trim());
    try {
      const data = await request('/add', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({url: value, name})});
      if (!data || !data.ok) throw new Error('The host did not confirm your request. Check Requests before retrying.');
      say('Requested ' + (data.title || 'your pick') + '.'); if ($('url').value.trim() === value) $('url').value = ''; load();
    } catch (error) { say(error.message, true); }
    finally { adding = false; $('send').disabled = false; $('add').removeAttribute('aria-busy'); }
  });
  const tabs = [...document.querySelectorAll('[role=tab]')];
  function selectTab(tab) {
    tabs.forEach(button => { const active = button === tab; button.setAttribute('aria-selected', String(active)); button.tabIndex = active ? 0 : -1; $(button.dataset.panel).hidden = !active; });
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => selectTab(tab));
    tab.addEventListener('keydown', event => {
      let next; if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      else if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
      else if (event.key === 'Home') next = 0; else if (event.key === 'End') next = tabs.length - 1;
      if (next !== undefined) { event.preventDefault(); selectTab(tabs[next]); tabs[next].focus(); }
    });
  });
  $('guestsToggle').addEventListener('click', () => { const open = $('guestList').hidden; $('guestList').hidden = !open; $('guestsToggle').setAttribute('aria-expanded', String(open)); });
  $('art').addEventListener('error', () => { $('art').hidden = true; });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) { if (wanted) resetScheduled(); load(); } });
  window.addEventListener('pagehide', () => { destroyed = true; stopAudio(); if (stateFetch) stateFetch.abort(); for (const timer of clocks) clearInterval(timer); });
  window.addEventListener('pageshow', event => { if (event.persisted) location.reload(); });
  clocks.add(setInterval(load, 1000)); clocks.add(setInterval(progress, 250)); load();
})();
