import { platform, isTauri } from './platform.js';
import { t, setLanguage, resolveLanguage, currentLanguage } from './i18n.js';
import { renderMarkdown, renderDiagrams } from './render.js';
import { createEditor } from './editor.js';
import { welcome } from './welcome.js';

const $ = (selector) => document.querySelector(selector);
const repository = 'glozahn/md-lite';

// ---------------------------------------------------------------- icons

const icons = {
  book: '<path d="M3 3.2A1.2 1.2 0 0 1 4.2 2H12.5v10H4.5A1.5 1.5 0 0 0 3 13.5Z"/><path d="M3 13.5A1.5 1.5 0 0 1 4.5 12h8v2H4.5A1.5 1.5 0 0 1 3 13.5Z"/>',
  plus: '<path d="M8 3.5v9M3.5 8h9"/>',
  note: '<path d="M10.8 2.7 13.3 5.2 6.8 11.7H4.3V9.2Z"/><path d="M3 14h10"/>',
  clipboard: '<rect x="3.5" y="3" width="9" height="11" rx="1.6"/><path d="M6 3.2V2h4v1.2M6 7h4M6 9.8h4"/>',
  sparkle: '<path d="M8 2.2c.4 2.6 1.2 3.4 3.8 3.8-2.6.4-3.4 1.2-3.8 3.8C7.6 7.2 6.8 6.4 4.2 6c2.6-.4 3.4-1.2 3.8-3.8ZM12 10.2c.2 1.2.6 1.6 1.8 1.8-1.2.2-1.6.6-1.8 1.8-.2-1.2-.6-1.6-1.8-1.8 1.2-.2 1.6-.6 1.8-1.8Z"/>',
  file: '<path d="M4 1.8h5l3 3v9.4H4Z"/><path d="M9 1.8v3h3M6 8.5h4M6 11h3"/>',
  sidebar: '<rect x="2" y="3" width="12" height="10" rx="1.6"/><path d="M6 3v10"/>',
  pencil: '<path d="M10.6 2.6 13.4 5.4 5.6 13.2H2.8v-2.8Z"/><path d="M9 4.2l2.8 2.8"/>',
  code: '<path d="M5.5 4.5 2 8l3.5 3.5M10.5 4.5 14 8l-3.5 3.5"/>',
  search: '<circle cx="7" cy="7" r="4.3"/><path d="m10.3 10.3 3.3 3.3"/>',
  star: '<path d="m8 1.9 1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.7l-3.8 2 .7-4.3-3.1-3 4.3-.6Z" fill="currentColor"/>',
  sliders: '<path d="M2.5 4.5h7M12.5 4.5h1M2.5 11.5h2M7.5 11.5h6"/><circle cx="11" cy="4.5" r="1.5"/><circle cx="6" cy="11.5" r="1.5"/>',
  link: '<path d="M6.8 9.2a2.8 2.8 0 0 0 4 0l2-2a2.8 2.8 0 0 0-4-4l-.7.7"/><path d="M9.2 6.8a2.8 2.8 0 0 0-4 0l-2 2a2.8 2.8 0 0 0 4 4l.7-.7"/>',
  list: '<path d="M6 4h7.5M6 8h7.5M6 12h7.5"/><circle cx="3" cy="4" r=".7" fill="currentColor"/><circle cx="3" cy="8" r=".7" fill="currentColor"/><circle cx="3" cy="12" r=".7" fill="currentColor"/>',
  listNumbered: '<path d="M6.5 4h7M6.5 8h7M6.5 12h7M2.5 2.8h1v3M2.3 9.5h1.6l-1.6 2.7h1.7"/>',
  check: '<rect x="2.5" y="2.5" width="11" height="11" rx="2.2"/><path d="m5.3 8.2 1.8 1.8 3.6-4"/>',
  quote: '<path d="M3 4.5h4v4H4.5L3 11.5ZM9 4.5h4v4h-2.5L9 11.5Z"/>',
  braces: '<path d="M5.5 2.5c-1.5 0-2 .6-2 2v1.6c0 1-.5 1.6-1.5 1.9 1 .3 1.5.9 1.5 1.9v1.6c0 1.4.5 2 2 2M10.5 2.5c1.5 0 2 .6 2 2v1.6c0 1 .5 1.6 1.5 1.9-1 .3-1.5.9-1.5 1.9v1.6c0 1.4-.5 2-2 2"/>',
  table: '<rect x="2" y="3" width="12" height="10" rx="1.4"/><path d="M2 6.5h12M2 9.8h12M6.5 3v10"/>',
  minus: '<path d="M3 8h10"/>',
  undo: '<path d="M5.5 3.5 2.5 6.5l3 3"/><path d="M2.5 6.5h7a3.5 3.5 0 0 1 0 7h-2"/>',
  redo: '<path d="m10.5 3.5 3 3-3 3"/><path d="M13.5 6.5h-7a3.5 3.5 0 0 0 0 7h2"/>',
  up: '<path d="m4 10 4-4 4 4"/>',
  down: '<path d="m4 6 4 4 4-4"/>',
  close: '<path d="m4.5 4.5 7 7M11.5 4.5l-7 7"/>',
  text: '<path d="M3 4h10M3 7h10M3 10h7M3 13h5"/>',
  chevron: '<path d="m6 4 4 4-4 4"/>',
  collapse: '<path d="m5 3 3 3 3-3M5 13l3-3 3 3"/>',
  expand: '<path d="m5 6 3-3 3 3M5 10l3 3 3-3"/>',
  gear: '<circle cx="8" cy="8" r="2.2"/><path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1"/>',
  clock: '<circle cx="8" cy="8" r="5.8"/><path d="M8 4.8V8l2.2 1.4"/>',
};
const icon = (name, size = 16) => `<svg viewBox="0 0 16 16" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name] ?? ''}</svg>`;

// ---------------------------------------------------------------- settings

const defaults = { theme: 'system', width: 'normal', language: 'system', accent: 'blue', fontSize: 17, remote: false, updates: false, sidebar: true };
const settings = { ...defaults, ...safeJSON(localStorage.getItem('mdlite.settings')) };
const accents = { system: '#0a84ff', blue: '#0a84ff', teal: '#2a9fa8', purple: '#8e5cd9', pink: '#e0457b', orange: '#e8830c', green: '#2f9e44' };
const widths = { narrow: '620px', normal: '780px', wide: '980px', full: '100%' };

function safeJSON(text) { try { return JSON.parse(text) ?? {}; } catch { return {}; } }
function saveSettings() { try { localStorage.setItem('mdlite.settings', JSON.stringify(settings)); } catch {} }

const darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
const isDark = () => settings.theme === 'dark' || (settings.theme === 'system' && darkQuery.matches);

// ---------------------------------------------------------------- document state

const doc = { path: null, kind: 'welcome', text: '', dirty: false, lastWritten: null, mtime: 0, remote: settings.remote, outline: [], blocked: 0, savedAt: null };
let mode = 'read';
let lastEditMode = 'edit';
let currentHeading = null;
let focusMode = false;
let loading = false;
let renderTimer, saveTimer;
const collapsed = new Set();
const imageCache = new Map();

const reader = $('#reader');
const article = $('#doc');
const editor = createEditor($('#editor'), { onChange: editorChanged });

function isWelcome() { return doc.kind === 'welcome'; }

function title() {
  if (doc.path) return doc.path.split(/[\\/]/).pop().replace(/\.(md|markdown|mdown|mkd|txt)$/i, '');
  if (doc.kind === 'note') return t('Nueva nota');
  if (doc.kind === 'pasted') return t('Texto pegado');
  return t('Bienvenido');
}

function load(kind, text, path = null) {
  doc.kind = kind;
  doc.path = path;
  doc.text = text;
  doc.dirty = false;
  doc.lastWritten = path ? text : null;
  doc.remote = settings.remote;
  doc.savedAt = null;
  collapsed.clear();
  loading = true;
  editor.load(text);
  loading = false;
  render({ keepScroll: false });
  reader.scrollTop = 0;
  updateChrome();
}

// ---------------------------------------------------------------- rendering

function render({ keepScroll = true } = {}) {
  clearTimeout(renderTimer);
  const scroll = reader.scrollTop;
  const { fragment, outline, blocked } = renderMarkdown(doc.text, { allowRemote: doc.remote });
  article.replaceChildren(fragment);
  doc.outline = outline;
  doc.blocked = blocked;
  if (keepScroll) reader.scrollTop = scroll;
  resolveImages();
  renderDiagrams(article, isDark());
  renderOutline();
  updateStats();
  updateBanner();
}

function scheduleRender() {
  clearTimeout(renderTimer);
  renderTimer = setTimeout(() => render(), mode === 'read' ? 30 : 280);
}

async function resolveImages() {
  const images = [...article.querySelectorAll('img[data-local]')];
  if (!images.length || !doc.path) return;
  const folder = await platform.dirname(doc.path);
  for (const image of images) {
    const source = image.dataset.local;
    try {
      const decoded = decodeURIComponent(source.split(/[?#]/)[0]);
      const absolute = /^([a-zA-Z]:[\\/]|\/)/.test(decoded) ? decoded : await platform.resolve(folder, decoded);
      let url = imageCache.get(absolute);
      if (!url) {
        url = await platform.imageURL(absolute);
        if (url) imageCache.set(absolute, url);
      }
      if (url) image.src = url;
    } catch {
      image.replaceWith(Object.assign(document.createElement('span'), { className: 'image-chip', textContent: image.alt || source }));
    }
  }
}

function updateStats() {
  const words = (doc.text.match(/\S+/g) || []).length;
  $('#stat-words').textContent = `${words} ${t('palabras')}`;
  $('#stat-minutes').textContent = `${Math.max(1, Math.ceil(words / 220))} ${t('min de lectura')}`;
}

function updateBanner() {
  const show = mode === 'read' && doc.blocked > 0 && !doc.remote;
  $('#banner').hidden = !show;
  if (show) $('#banner-text').textContent = t('%d imágenes remotas bloqueadas para proteger tu privacidad.', doc.blocked);
}

// ---------------------------------------------------------------- editing and saving

function editorChanged(text) {
  if (loading) return;
  doc.text = text;
  if (!doc.dirty) { doc.dirty = true; updateChrome(); }
  scheduleRender();
  clearTimeout(saveTimer);
  if (doc.path) saveTimer = setTimeout(() => save(), 900);
  else updateSaveState();
}

async function write(path) {
  try {
    await platform.writeText(path, doc.text);
    doc.lastWritten = doc.text;
    doc.dirty = false;
    doc.savedAt = Date.now();
    doc.mtime = await platform.modified(path).catch(() => 0);
    updateChrome();
    return true;
  } catch (error) {
    toast(`${t('No se pudo guardar')}: ${error}`);
    return false;
  }
}

async function save() {
  clearTimeout(saveTimer);
  if (!doc.path) return saveAs();
  return write(doc.path);
}

async function saveAs() {
  const heading = doc.outline[0]?.title?.replace(/[\\/:*?"<>|]/g, '').slice(0, 60);
  const suggested = (doc.path ? title() : heading || t('Sin título')) + '.md';
  const path = await platform.saveDialog(suggested);
  if (!path) return false;
  if (!(await write(path))) return false;
  doc.path = path;
  doc.kind = 'file';
  addRecent(path);
  render();
  updateChrome();
  return true;
}

async function confirmDiscard() {
  if (!doc.dirty) return true;
  if (doc.path) return save();
  const answer = await platform.ask3(t('¿Guardar los cambios de “%s”?', title()), t('Si no los guardas, se perderán.'),
    { yes: t('Guardar…'), no: t('No guardar'), cancel: t('Cancelar') });
  if (answer === 'yes') return saveAs();
  if (answer === 'no') { doc.dirty = false; return true; }
  return false;
}

async function openPath(path) {
  if (!path) return;
  if (path === doc.path) return;
  if (!(await confirmDiscard())) return;
  try {
    const text = await platform.readText(path);
    load('file', text, path);
    doc.mtime = await platform.modified(path).catch(() => 0);
    addRecent(path);
  } catch (error) {
    const reason = String(error).includes('too-large') ? t('Elige un archivo de texto UTF-8 de hasta 5 MB.') : String(error);
    toast(`${t('No se pudo abrir')} ${path.split(/[\\/]/).pop()}. ${reason}`);
  }
}

async function openDialog() { openPath(await platform.openDialog()); }

async function newNote() {
  if (!(await confirmDiscard())) return;
  load('note', `# ${t('Nueva nota')}\n\n`);
  setMode('edit');
  editor.view.dispatch({ selection: { anchor: editor.view.state.doc.length } });
}

async function showWelcome() {
  if (!(await confirmDiscard())) return;
  load('welcome', welcome[currentLanguage()]);
  setMode('read');
}

async function reload() {
  if (!doc.path) return;
  if (doc.dirty && !(await platform.confirm(t('¿Descartar tus cambios y volver a cargar el archivo?'), t('Volver a cargar'), t('Cancelar')))) return;
  const text = await platform.readText(doc.path);
  load('file', text, doc.path);
}

// Picks up changes saved by other editors while the file is clean.
setInterval(async () => {
  if (!doc.path || doc.dirty || document.hidden) return;
  try {
    const mtime = await platform.modified(doc.path);
    if (!mtime || mtime === doc.mtime) return;
    doc.mtime = mtime;
    const text = await platform.readText(doc.path);
    if (text === doc.text || text === doc.lastWritten) return;
    doc.text = text;
    doc.lastWritten = text;
    loading = true;
    editor.load(text);
    loading = false;
    render();
  } catch {}
}, 2500);

function toggleTask(line) {
  editor.toggleTask(line);
  render();
}

// ---------------------------------------------------------------- modes and navigation

function readerTopLine() {
  const top = reader.getBoundingClientRect().top + 16;
  let best = 0;
  for (const node of article.querySelectorAll('[data-line]')) {
    const rect = node.getBoundingClientRect();
    if (rect.top > top) break;
    best = Number(node.dataset.line);
  }
  return best;
}

function scrollReaderToLine(line) {
  let target = null;
  for (const node of article.querySelectorAll('[data-line]')) {
    if (Number(node.dataset.line) > line) break;
    target = node;
  }
  if (target) reader.scrollTop += target.getBoundingClientRect().top - reader.getBoundingClientRect().top - 20;
  else reader.scrollTop = 0;
}

function setMode(next) {
  if (next === mode) return;
  const anchor = mode === 'read' ? readerTopLine() : editor.topLine();
  const previous = mode;
  mode = next;
  if (next !== 'read') lastEditMode = next;
  $('#reader').hidden = next !== 'read';
  $('#editor').hidden = next === 'read';
  $('#formatbar').hidden = next === 'read' || focusMode;
  if (next === 'read') {
    render();
    requestAnimationFrame(() => { scrollReaderToLine(anchor); reader.focus({ preventScroll: true }); });
  } else {
    editor.setMode(next);
    requestAnimationFrame(() => {
      if (previous === 'read') editor.scrollToLine(anchor);
      editor.focus();
    });
  }
  updateChrome();
}

function toggleEditing() { setMode(mode === 'read' ? lastEditMode : 'read'); }

function format(action) {
  if (action === 'undo') return editor.undo();
  if (action === 'redo') return editor.redo();
  if (mode === 'read') setMode('edit');
  requestAnimationFrame(() => editor.format(action));
}

function navigate(item) {
  currentHeading = item.index;
  if (mode === 'read') {
    const target = article.querySelector(`#${CSS.escape(item.id)}`) ?? article.querySelectorAll('h1,h2,h3,h4,h5,h6')[item.index];
    if (target) reader.scrollTop += target.getBoundingClientRect().top - reader.getBoundingClientRect().top - 18;
  } else {
    editor.scrollToLine(item.line);
    editor.focus();
  }
  renderOutline();
}

function navigateRelative(delta) {
  if (!doc.outline.length) return;
  const index = currentHeading ?? (delta > 0 ? -1 : doc.outline.length);
  navigate(doc.outline[Math.min(doc.outline.length - 1, Math.max(0, index + delta))]);
}

function trackPosition() {
  let active = null;
  let progress = 0;
  if (mode === 'read') {
    const top = reader.getBoundingClientRect().top + 90;
    const headings = article.querySelectorAll('h1,h2,h3,h4,h5,h6');
    headings.forEach((heading, index) => { if (heading.getBoundingClientRect().top <= top) active = index; });
    const max = reader.scrollHeight - reader.clientHeight;
    progress = max > 1 ? reader.scrollTop / max : 1;
  } else {
    const line = editor.topLine();
    doc.outline.forEach((item) => { if (item.line <= line) active = item.index; });
    const scroller = editor.view.scrollDOM;
    const max = scroller.scrollHeight - scroller.clientHeight;
    progress = max > 1 ? scroller.scrollTop / max : 1;
  }
  if (active === null && doc.outline.length) active = doc.outline[0].index;
  $('#stat-progress').textContent = `${Math.round(progress * 100)}%`;
  if (active !== currentHeading) { currentHeading = active; renderOutline(); }
}

let tracking = false;
const onScroll = () => {
  if (tracking) return;
  tracking = true;
  requestAnimationFrame(() => { tracking = false; trackPosition(); });
};
reader.addEventListener('scroll', onScroll, { passive: true });
editor.view.scrollDOM.addEventListener('scroll', onScroll, { passive: true });

// ---------------------------------------------------------------- sidebar

function renderOutline() {
  const outline = doc.outline;
  const list = $('#outline');
  const filter = $('#outline-filter');
  $('#outline-count').hidden = !outline.length;
  $('#outline-count').textContent = outline.length;
  filter.hidden = outline.length <= 10;
  const query = filter.value.trim().toLowerCase();
  const min = Math.min(...outline.map((item) => item.level), 6);
  const hasChildren = (i) => i + 1 < outline.length && outline[i + 1].level > outline[i].level;
  const collapseButton = $('#collapse-all');
  collapseButton.hidden = !outline.some((_, i) => hasChildren(i));
  collapseButton.innerHTML = icon(collapsed.size ? 'expand' : 'collapse', 12);
  collapseButton.title = collapsed.size ? t('Expandir todo') : t('Contraer todo');

  if (!outline.length) {
    list.innerHTML = `<p class="empty">${t('Los títulos aparecerán aquí.')}</p>`;
    return;
  }
  // The row that owns the current position, even when it is folded away.
  const visible = [];
  let hideBelow = null;
  outline.forEach((item, i) => {
    if (query) { if (item.title.toLowerCase().includes(query)) visible.push(item); return; }
    if (hideBelow !== null && item.level > hideBelow) return;
    hideBelow = collapsed.has(item.index) ? item.level : null;
    visible.push(item);
  });
  let active = currentHeading;
  if (active !== null && !visible.some((item) => item.index === active)) {
    let level = outline[active]?.level ?? 1;
    for (let i = active - 1; i >= 0; i--) {
      if (outline[i].level < level) {
        if (visible.some((item) => item.index === i)) { active = i; break; }
        level = outline[i].level;
      }
    }
  }
  list.replaceChildren(...visible.map((item) => {
    const depth = Math.min(4, item.level - min);
    const row = document.createElement('div');
    row.className = `outline-row depth-${Math.min(depth, 2)}` + (item.index === active ? ' active' : '');
    row.style.setProperty('--depth', depth);
    row.title = item.title;
    const parent = !query && hasChildren(item.index);
    row.innerHTML = `<span class="rail"></span><button class="chevron${collapsed.has(item.index) ? ' closed' : ''}"${parent ? '' : ' hidden'}>${icon('chevron', 10)}</button><span class="label"></span>`;
    row.querySelector('.label').textContent = item.title;
    row.addEventListener('click', () => navigate(item));
    row.querySelector('.chevron').addEventListener('click', (event) => {
      event.stopPropagation();
      if (collapsed.has(item.index)) collapsed.delete(item.index); else collapsed.add(item.index);
      renderOutline();
    });
    return row;
  }));
  const activeRow = list.querySelector('.outline-row.active');
  const scroller = $('.sidebar-scroll');
  if (activeRow) {
    const row = activeRow.getBoundingClientRect(), box = scroller.getBoundingClientRect();
    if (row.top < box.top) scroller.scrollTop -= box.top - row.top + 8;
    else if (row.bottom > box.bottom) scroller.scrollTop += row.bottom - box.bottom + 8;
  }
}

$('#outline-filter').addEventListener('input', renderOutline);
$('#collapse-all').addEventListener('click', () => {
  if (collapsed.size) collapsed.clear();
  else doc.outline.forEach((item, i) => { if (i + 1 < doc.outline.length && doc.outline[i + 1].level > item.level) collapsed.add(item.index); });
  renderOutline();
});

function recentFiles() { return safeJSON(localStorage.getItem('mdlite.recent')).list ?? []; }
function addRecent(path) {
  const list = [path, ...recentFiles().filter((item) => item !== path)].slice(0, 12);
  try { localStorage.setItem('mdlite.recent', JSON.stringify({ list })); } catch {}
  renderRecent();
}
function renderRecent() {
  const list = recentFiles().slice(0, 5);
  $('#recent-block').hidden = !list.length;
  const names = list.map((path) => path.split(/[\\/]/).pop());
  $('#recent').replaceChildren(...list.map((path, i) => {
    const button = document.createElement('button');
    button.className = 'recent-row';
    button.title = path;
    const parts = path.split(/[\\/]/);
    const duplicate = names.filter((name) => name === names[i]).length > 1;
    button.innerHTML = `${icon('file', 13)}<span class="name"></span>${duplicate ? '<span class="folder"></span>' : ''}`;
    button.querySelector('.name').textContent = names[i];
    if (duplicate) button.querySelector('.folder').textContent = parts[parts.length - 2] ?? '';
    button.addEventListener('click', () => openPath(path));
    return button;
  }));
}

// ---------------------------------------------------------------- chrome

function updateSaveState() {
  const state = $('#save-state');
  if (doc.dirty) state.textContent = doc.path ? t('Guardando…') : t('Sin guardar · Ctrl+S');
  else if (doc.path && doc.savedAt) state.textContent = '✓ ' + t('Guardado');
  else state.textContent = '';
}

function updateChrome() {
  const name = title();
  $('#doc-title').textContent = name;
  $('#dirty-dot').hidden = !doc.dirty;
  $('.title .ext').hidden = doc.dirty;
  $('#welcome-row').classList.toggle('active', isWelcome());
  const current = $('#current-row');
  current.hidden = isWelcome();
  current.querySelector('.name').textContent = name;
  current.querySelector('.dot').hidden = !doc.dirty;
  for (const button of document.querySelectorAll('#modes button')) {
    const active = button.dataset.mode === mode;
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', String(active));
  }
  $('#mode-label').textContent = { read: t('LECTURA'), edit: t('EDITOR'), source: t('CÓDIGO FUENTE') }[mode];
  $('#app').classList.toggle('no-sidebar', !settings.sidebar || focusMode);
  $('#app').classList.toggle('focus', focusMode);
  $('#formatbar').hidden = mode === 'read' || focusMode;
  $('#zoom-reset').textContent = settings.fontSize;
  updateSaveState();
  updateBanner();
  platform.setTitle(`${doc.dirty ? '• ' : ''}${name} — MD Lite`);
}

function applySettings() {
  const root = document.documentElement;
  root.dataset.theme = settings.theme === 'system' ? (darkQuery.matches ? 'dark' : 'light') : settings.theme;
  root.style.setProperty('--accent', accents[settings.accent] ?? accents.blue);
  root.style.setProperty('--font-size', `${settings.fontSize}px`);
  root.style.setProperty('--column', widths[settings.width] ?? widths.normal);
  const language = resolveLanguage(settings.language);
  const languageChanged = language !== currentLanguage() || !document.body.dataset.translated;
  setLanguage(language);
  if (languageChanged) {
    translate();
    if (isWelcome() && !doc.dirty) load('welcome', welcome[language]);
  }
  for (const group of document.querySelectorAll('[data-setting]')) {
    for (const button of group.querySelectorAll('button')) button.classList.toggle('active', button.value === settings[group.dataset.setting]);
  }
  for (const swatch of document.querySelectorAll('#accents button')) swatch.classList.toggle('active', swatch.dataset.accent === settings.accent);
  $('#remote-setting').checked = settings.remote;
  $('#update-setting').checked = settings.updates;
  saveSettings();
  updateChrome();
}

darkQuery.addEventListener('change', () => { applySettings(); render(); });

const tips = {
  '#sidebar-button': ['Mostrar u ocultar la barra lateral', 'Ctrl+\\'],
  '#find-button': ['Buscar', 'Ctrl+F'],
  '#zoom-out': ['Reducir texto', 'Ctrl+−'],
  '#zoom-reset': ['Tamaño original', 'Ctrl+0'],
  '#zoom-in': ['Aumentar texto', 'Ctrl++'],
  '#star-button': ['Dejar una estrella en GitHub', ''],
  '#settings-button': ['Preferencias', 'Ctrl+,'],
  '#sidebar-settings': ['Preferencias', 'Ctrl+,'],
  '[data-mode="read"]': ['Lectura', 'Ctrl+1'],
  '[data-mode="edit"]': ['Editor', 'Ctrl+2'],
  '[data-mode="source"]': ['Código', 'Ctrl+3'],
  '#new-button': ['Nueva nota', 'Ctrl+N'],
  '#paste-button': ['Pegar Markdown', 'Ctrl+Shift+V'],
  '[data-format="heading1"]': ['Título 1', 'Ctrl+Alt+1'],
  '[data-format="heading2"]': ['Título 2', 'Ctrl+Alt+2'],
  '[data-format="heading3"]': ['Título 3', 'Ctrl+Alt+3'],
  '[data-format="bold"]': ['Negrita', 'Ctrl+B'],
  '[data-format="italic"]': ['Cursiva', 'Ctrl+I'],
  '[data-format="strikethrough"]': ['Tachado', 'Ctrl+Shift+X'],
  '[data-format="code"]': ['Código en línea', 'Ctrl+Shift+K'],
  '[data-format="link"]': ['Enlace', 'Ctrl+K'],
  '[data-format="bulletList"]': ['Lista', 'Ctrl+Shift+7'],
  '[data-format="numberedList"]': ['Lista numerada', 'Ctrl+Shift+9'],
  '[data-format="taskList"]': ['Lista de tareas', 'Ctrl+Shift+L'],
  '[data-format="quote"]': ['Cita', "Ctrl+'"],
  '[data-format="codeBlock"]': ['Bloque de código', 'Ctrl+Shift+M'],
  '[data-format="table"]': ['Tabla', 'Ctrl+Alt+T'],
  '[data-format="rule"]': ['Separador', ''],
  '[data-format="undo"]': ['Deshacer', 'Ctrl+Z'],
  '[data-format="redo"]': ['Rehacer', 'Ctrl+Y'],
};

function translate() {
  document.body.dataset.translated = 'true';
  for (const node of document.querySelectorAll('[data-t]')) node.textContent = t(node.dataset.t);
  for (const [selector, [label, keys]] of Object.entries(tips)) {
    for (const node of document.querySelectorAll(selector)) {
      node.title = keys ? `${t(label)} · ${keys}` : t(label);
      node.setAttribute('aria-label', t(label));
    }
  }
  $('#outline-filter').placeholder = t('Filtrar títulos');
  $('#find-input').placeholder = t('Buscar en el documento');
  buildShortcuts();
  renderOutline();
  renderRecent();
}

function toast(message) {
  const node = $('#toast');
  node.textContent = message;
  node.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { node.hidden = true; }, 4500);
}

// ---------------------------------------------------------------- dialogs

const shortcutSections = [
  ['Vista', [['Lectura', 'Ctrl 1'], ['Editor', 'Ctrl 2'], ['Código', 'Ctrl 3'], ['Alternar lectura y edición', 'Ctrl E'],
    ['Mostrar u ocultar la barra lateral', 'Ctrl \\'], ['Modo enfoque', 'Ctrl ⇧ F'], ['Aumentar / reducir texto', 'Ctrl + −'], ['Tamaño original', 'Ctrl 0']]],
  ['Archivo', [['Nueva nota', 'Ctrl N'], ['Abrir', 'Ctrl O'], ['Guardar', 'Ctrl S'], ['Guardar como…', 'Ctrl ⇧ S'],
    ['Pegar Markdown', 'Ctrl ⇧ V'], ['Volver a cargar', 'Ctrl R'], ['Preferencias', 'Ctrl ,']]],
  ['Edición', [['Deshacer', 'Ctrl Z'], ['Rehacer', 'Ctrl Y'], ['Buscar', 'Ctrl F'], ['Buscar siguiente / anterior', 'F3 ⇧F3'],
    ['Continuar lista o cita', '↵'], ['Sangrar / quitar sangría', '⇥ ⇧⇥']]],
  ['Formato', [['Negrita', 'Ctrl B'], ['Cursiva', 'Ctrl I'], ['Tachado', 'Ctrl ⇧ X'], ['Código en línea', 'Ctrl ⇧ K'], ['Enlace', 'Ctrl K'],
    ['Título 1, 2, 3', 'Ctrl Alt 1–3'], ['Texto normal', 'Ctrl Alt 0'], ['Lista', 'Ctrl ⇧ 7'], ['Lista numerada', 'Ctrl ⇧ 9'],
    ['Lista de tareas', 'Ctrl ⇧ L'], ['Cita', "Ctrl '"], ['Bloque de código', 'Ctrl ⇧ M'], ['Tabla', 'Ctrl Alt T']]],
  ['Navegación', [['Título anterior', 'Ctrl Alt ↑'], ['Título siguiente', 'Ctrl Alt ↓'], ['Atajos de teclado', 'Ctrl /']]],
];

function buildShortcuts() {
  $('#shortcut-grid').replaceChildren(...shortcutSections.map(([section, rows]) => {
    const card = document.createElement('section');
    card.innerHTML = `<h3></h3>`;
    card.querySelector('h3').textContent = t(section);
    for (const [label, keys] of rows) {
      const row = document.createElement('div');
      row.className = 'shortcut';
      row.innerHTML = `<span></span><span class="keys">${keys.split(' ').map((k) => `<kbd>${k.replace(/</g, '&lt;')}</kbd>`).join('')}</span>`;
      row.firstElementChild.textContent = t(label);
      card.append(row);
    }
    return card;
  }));
}

function showDialog(id) {
  for (const dialog of document.querySelectorAll('dialog[open]')) dialog.close();
  $(id).showModal();
}

async function checkForUpdates(userInitiated) {
  try {
    const response = await fetch(`https://api.github.com/repos/${repository}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
    if (!response.ok) throw new Error(response.status);
    const release = await response.json();
    localStorage.setItem('mdlite.lastUpdateCheck', String(Date.now()));
    const latest = String(release.tag_name).replace(/^v/i, '');
    const current = await platform.version();
    if (newer(latest, current)) {
      if (await platform.confirm(t('MD Lite %s está disponible. Tienes la versión %s. ¿Abrir la página de descarga?', latest, current), t('Descargar'), t('Más tarde'))) {
        platform.openURL(release.html_url);
      }
    } else if (userInitiated) {
      platform.message(t('Tienes la versión más reciente (%s).', current), t('MD Lite está al día'));
    }
  } catch {
    if (userInitiated) platform.message(t('No se pudo buscar actualizaciones'), 'MD Lite');
  }
}

function newer(a, b) {
  const parse = (v) => v.split('-')[0].split('.').map((n) => Number(n) || 0);
  const x = parse(a), y = parse(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) > (y[i] ?? 0);
  return false;
}

// ---------------------------------------------------------------- find in reading view

function showFind() {
  if (mode !== 'read') { editor.find(); return; }
  $('#findbar').hidden = false;
  const input = $('#find-input');
  input.focus();
  input.select();
}

function findInReader(backwards = false) {
  const term = $('#find-input').value;
  if (!term) return;
  const selection = window.getSelection();
  if (selection && !article.contains(selection.anchorNode)) selection.removeAllRanges();
  const found = typeof window.find === 'function' && window.find(term, false, backwards, true, false, false, false);
  $('#find-status').textContent = found ? '' : t('Sin resultados');
  if (found) $('#find-input').focus();
}

$('#find-input').addEventListener('keydown', (event) => {
  if (event.key === 'Enter') { event.preventDefault(); findInReader(event.shiftKey); }
  if (event.key === 'Escape') { $('#findbar').hidden = true; reader.focus({ preventScroll: true }); }
});
$('#find-next').addEventListener('click', () => findInReader(false));
$('#find-prev').addEventListener('click', () => findInReader(true));
$('#find-close').addEventListener('click', () => { $('#findbar').hidden = true; });

// ---------------------------------------------------------------- events

article.addEventListener('click', async (event) => {
  const copy = event.target.closest('.copy');
  if (copy) {
    const code = copy.closest('.codeblock')?.querySelector('code')?.textContent ?? '';
    await navigator.clipboard.writeText(code).catch(() => {});
    copy.classList.add('copied');
    copy.title = t('Copiado');
    setTimeout(() => { copy.classList.remove('copied'); copy.title = t('Copiar'); }, 1500);
    return;
  }
  const task = event.target.closest('input.task');
  if (task) {
    event.preventDefault();
    if (task.dataset.line) toggleTask(Number(task.dataset.line));
    return;
  }
  const link = event.target.closest('a[href]');
  if (!link) return;
  event.preventDefault();
  const href = link.getAttribute('href');
  if (href.startsWith('#')) {
    const target = document.getElementById(decodeURIComponent(href.slice(1))) ?? article.querySelector(`[id="${CSS.escape(decodeURIComponent(href.slice(1)).toLowerCase())}"]`);
    if (target) reader.scrollTop += target.getBoundingClientRect().top - reader.getBoundingClientRect().top - 18;
    return;
  }
  if (/^(https?:|mailto:)/i.test(href)) { platform.openURL(href); return; }
  if (doc.path && /\.(md|markdown|mdown|mkd)(#.*)?$/i.test(href)) {
    const folder = await platform.dirname(doc.path);
    openPath(await platform.resolve(folder, decodeURIComponent(href.split('#')[0])));
  }
});

$('#open-button').addEventListener('click', openDialog);
$('#new-button').addEventListener('click', newNote);
$('#paste-button').addEventListener('click', () => openPaste());
$('#welcome-row').addEventListener('click', showWelcome);
$('#sidebar-button').addEventListener('click', toggleSidebar);
$('#find-button').addEventListener('click', showFind);
$('#zoom-in').addEventListener('click', () => zoom(1));
$('#zoom-out').addEventListener('click', () => zoom(-1));
$('#zoom-reset').addEventListener('click', () => zoom(0));
$('#star-button').addEventListener('click', () => platform.openURL(`https://github.com/${repository}`));
$('#settings-button').addEventListener('click', () => showDialog('#settings'));
$('#sidebar-settings').addEventListener('click', () => showDialog('#settings'));
$('#settings-shortcuts').addEventListener('click', () => showDialog('#shortcuts'));
$('#check-updates').addEventListener('click', () => checkForUpdates(true));
$('#banner-button').addEventListener('click', () => { doc.remote = true; render(); });
for (const button of document.querySelectorAll('#modes button')) button.addEventListener('click', () => setMode(button.dataset.mode));
for (const button of document.querySelectorAll('[data-format]')) {
  button.addEventListener('mousedown', (event) => event.preventDefault());
  button.addEventListener('click', () => format(button.dataset.format));
}
for (const group of document.querySelectorAll('[data-setting]')) {
  for (const button of group.querySelectorAll('button')) {
    button.addEventListener('click', () => { settings[group.dataset.setting] = button.value; applySettings(); render(); });
  }
}
$('#accents').replaceChildren(...Object.entries(accents).filter(([name]) => name !== 'system').map(([name, color]) => {
  const swatch = document.createElement('button');
  swatch.type = 'button';
  swatch.dataset.accent = name;
  swatch.style.background = color;
  swatch.title = name;
  swatch.addEventListener('click', () => { settings.accent = name; applySettings(); });
  return swatch;
}));
$('#remote-setting').addEventListener('change', (event) => { settings.remote = event.target.checked; if (settings.remote) doc.remote = true; applySettings(); render(); });
$('#update-setting').addEventListener('change', (event) => { settings.updates = event.target.checked; applySettings(); });

function openPaste() {
  $('#paste-text').value = doc.kind === 'pasted' ? doc.text : '';
  showDialog('#paste');
  $('#paste-text').focus();
}
$('#paste').addEventListener('close', async () => {
  if ($('#paste').returnValue !== 'read') return;
  const text = $('#paste-text').value;
  if (!text.trim()) return;
  if (!(await confirmDiscard())) return;
  load('pasted', text);
  setMode('read');
});

function toggleSidebar() {
  if (focusMode) { focusMode = false; settings.sidebar = true; }
  else settings.sidebar = !settings.sidebar;
  applySettings();
}

function zoom(delta) {
  settings.fontSize = delta === 0 ? 17 : Math.min(28, Math.max(12, settings.fontSize + delta));
  applySettings();
}

document.addEventListener('keydown', (event) => {
  if (event.defaultPrevented) return;
  const mod = event.ctrlKey || event.metaKey;
  const key = event.key.toLowerCase();
  const run = (action) => { event.preventDefault(); action(); };
  if (event.key === 'F3') return run(() => (mode === 'read' ? findInReader(event.shiftKey) : event.shiftKey ? editor.findPrevious() : editor.findNext()));
  if (!mod) return;
  if (event.altKey) {
    if (key === 'arrowup') return run(() => navigateRelative(-1));
    if (key === 'arrowdown') return run(() => navigateRelative(1));
    const altFormats = { 1: 'heading1', 2: 'heading2', 3: 'heading3', 0: 'paragraph', t: 'table' };
    const code = event.code.replace(/^(Digit|Key)/, '').toLowerCase();
    if (mode === 'read' && altFormats[code]) return run(() => format(altFormats[code]));
    return;
  }
  if (event.shiftKey) {
    if (key === 's') return run(saveAs);
    if (key === 'v') return run(openPaste);
    if (key === 'f') return run(() => { focusMode = !focusMode; applySettings(); });
    if (mode === 'read') {
      const shiftFormats = { x: 'strikethrough', k: 'code', 7: 'bulletList', 9: 'numberedList', l: 'taskList', m: 'codeBlock' };
      const code = event.code.replace(/^(Digit|Key)/, '').toLowerCase();
      if (shiftFormats[code]) return run(() => format(shiftFormats[code]));
    }
    return;
  }
  switch (key) {
    case 'o': return run(openDialog);
    case 'n': return run(newNote);
    case 's': return run(save);
    case 'r': return run(reload);
    case 'e': return run(toggleEditing);
    case '1': return run(() => setMode('read'));
    case '2': return run(() => setMode('edit'));
    case '3': return run(() => setMode('source'));
    case '\\': return run(toggleSidebar);
    case '/': return run(() => showDialog('#shortcuts'));
    case ',': return run(() => showDialog('#settings'));
    case 'f': return run(showFind);
    case 'g': return run(() => (mode === 'read' ? findInReader(false) : editor.findNext()));
    case '=': case '+': return run(() => zoom(1));
    case '-': return run(() => zoom(-1));
    case '0': return run(() => zoom(0));
    case 'b': if (mode === 'read') return run(() => format('bold')); return;
    case 'i': if (mode === 'read') return run(() => format('italic')); return;
    case 'k': if (mode === 'read') return run(() => format('link')); return;
    case "'": if (mode === 'read') return run(() => format('quote')); return;
    case 'w': return run(() => { const open = document.querySelector('dialog[open]'); if (open) open.close(); });
    default: return;
  }
});

// ---------------------------------------------------------------- start

for (const node of document.querySelectorAll('[data-icon]')) node.insertAdjacentHTML('afterbegin', icon(node.dataset.icon));
platform.onDrop((path) => openPath(path));
const closeCheck = async () => confirmDiscard();
closeCheck.sync = () => !doc.dirty;
platform.onCloseRequested(closeCheck);

applySettings();
if (!doc.text) load('welcome', welcome[currentLanguage()]);
updateChrome();
trackPosition();

(async () => {
  const initial = await platform.initialFile();
  if (initial) await openPath(initial);
  if (!isTauri) {
    platform.seed('/memory/sample.md', welcome.en);
    window.mdlite = { openPath, setMode, doc };
  }
  const last = Number(localStorage.getItem('mdlite.lastUpdateCheck') || 0);
  if (settings.updates && Date.now() - last > 86_400_000) checkForUpdates(false);
})();
