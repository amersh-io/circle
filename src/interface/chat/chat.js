// The chat over the image's transcript. The image sends each new entry as
// the event circle-entry; on load, and whenever the image comes back, the
// page asks for the entries it has not seen. ext.js, loaded after this,
// may use window.circle.
(() => {
  const list = document.getElementById('transcript');
  const status = document.getElementById('status');
  const input = document.getElementById('input');
  const form = document.getElementById('composer');
  const tools = new Map();   // tool call id -> its <details>
  const cards = new Map();   // permission id -> its card
  const watchers = [];
  let known = 0;             // entries shown: indices 0 .. known-1
  let online = false;
  let catching = null;

  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  const pretty = (json) => {
    try { return JSON.stringify(JSON.parse(json), null, 2); } catch (e) { return json; }
  };

  const atBottom = () => list.scrollHeight - list.scrollTop - list.clientHeight < 40;

  function show(entry) {
    switch (entry.kind) {
      case 'user':
        return element('div', 'entry user', entry.text);
      case 'assistant':
        return element('div', 'entry assistant', entry.text);
      case 'tool': {
        const box = element('details', 'tool');
        box.dataset.id = entry.id;
        box.append(element('summary', null, entry.name.replace(/^mcp__lisp__/, 'lisp: ')),
                   element('pre', 'input', pretty(entry.input)));
        tools.set(entry.id, box);
        return box;
      }
      case 'tool-result': {
        const box = tools.get(entry.toolUseId);
        const result = element('pre', 'result' + (entry.isError ? ' failed' : ''), entry.text);
        if (box) { box.append(result); return null; }
        return result;
      }
      case 'turn-end':
        return entry.isError ? element('div', 'entry error', entry.text || 'The turn failed.') : null;
      case 'permission': {
        const card = element('div', 'card');
        card.dataset.id = entry.id;
        const buttons = element('div', 'buttons');
        const allow = element('button', 'allow', 'Allow');
        const deny = element('button', 'deny', 'Deny');
        const answer = (yes) => {
          allow.disabled = deny.disabled = true;
          proteus.invoke('circle-answer', {id: entry.id, allow: yes}).catch(() => {
            allow.disabled = deny.disabled = false;
          });
        };
        allow.onclick = () => answer(true);
        deny.onclick = () => answer(false);
        buttons.append(allow, deny);
        card.append(element('div', null, 'The agent asks to use ' + entry.tool + '.'),
                    element('pre', null, pretty(entry.input)), buttons);
        cards.set(entry.id, card);
        return card;
      }
      case 'permission-answer': {
        const card = cards.get(entry.id);
        if (card) {
          card.querySelectorAll('button').forEach((b) => { b.disabled = true; });
          card.append(element('div', 'answer', entry.allow ? 'Allowed.' : entry.reason || 'Denied.'));
        }
        return null;
      }
      default:
        return null;
    }
  }

  function add(entry) {
    if (entry.index !== known) return false;
    known += 1;
    const follow = atBottom();
    const node = show(entry);
    if (node) list.append(node);
    if (follow) list.scrollTop = list.scrollHeight;
    for (const watch of watchers) {
      try { watch(entry); } catch (e) { console.error(e); }
    }
    return true;
  }

  function catchUp() {
    if (!catching) {
      catching = proteus.invoke('circle-transcript', {from: known})
        .then((entries) => { entries.forEach(add); })
        .finally(() => { catching = null; });
    }
    return catching;
  }

  function setOnline(yes) {
    online = yes;
    status.className = 'status ' + (yes ? 'online' : 'offline');
    status.textContent = yes ? 'connected' : 'waiting for the image';
  }

  async function ping() {
    try {
      // A shell may have commands of its own by these names; only the
      // image's say its engine runs.
      const state = await proteus.invoke('circle-status');
      if (!state.running) throw new Error('the image is not running');
      if (!online) { setOnline(true); await catchUp(); }
    } catch (e) {
      setOnline(false);
    }
  }

  proteus.listen('circle-entry', (entry) => {
    if (!add(entry) && entry.index > known) catchUp();
  });

  function send(text) {
    return proteus.invoke('circle-send', {text});
  }

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    send(text).then(() => { input.value = ''; }, (e) => { setOnline(false); console.error(e); });
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      form.requestSubmit();
    }
  });

  // For ext.js: send text, hear entries, see how many there are.
  window.circle = Object.freeze({
    send,
    onEntry: (fn) => { watchers.push(fn); },
    entries: () => known,
  });

  setInterval(ping, 1000);
  ping();
})();
