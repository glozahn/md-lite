import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import DOMPurify from 'dompurify';
import hljs from 'highlight.js/lib/core';
import bash from 'highlight.js/lib/languages/bash';
import c from 'highlight.js/lib/languages/c';
import cpp from 'highlight.js/lib/languages/cpp';
import csharp from 'highlight.js/lib/languages/csharp';
import css from 'highlight.js/lib/languages/css';
import diff from 'highlight.js/lib/languages/diff';
import dockerfile from 'highlight.js/lib/languages/dockerfile';
import go from 'highlight.js/lib/languages/go';
import ini from 'highlight.js/lib/languages/ini';
import java from 'highlight.js/lib/languages/java';
import javascript from 'highlight.js/lib/languages/javascript';
import json from 'highlight.js/lib/languages/json';
import kotlin from 'highlight.js/lib/languages/kotlin';
import markdown from 'highlight.js/lib/languages/markdown';
import php from 'highlight.js/lib/languages/php';
import python from 'highlight.js/lib/languages/python';
import ruby from 'highlight.js/lib/languages/ruby';
import rust from 'highlight.js/lib/languages/rust';
import sql from 'highlight.js/lib/languages/sql';
import swift from 'highlight.js/lib/languages/swift';
import typescript from 'highlight.js/lib/languages/typescript';
import xml from 'highlight.js/lib/languages/xml';
import yaml from 'highlight.js/lib/languages/yaml';
import { t } from './i18n.js';

const languages = { bash, c, cpp, csharp, css, diff, dockerfile, go, ini, java, javascript, json, kotlin, markdown, php, python, ruby, rust, sql, swift, typescript, xml, yaml };
for (const [name, definition] of Object.entries(languages)) hljs.registerLanguage(name, definition);
hljs.registerAliases(['sh', 'shell', 'zsh', 'console'], { languageName: 'bash' });
hljs.registerAliases(['toml', 'env', 'conf'], { languageName: 'ini' });
hljs.registerAliases(['html', 'svg', 'plist', 'vue'], { languageName: 'xml' });
hljs.registerAliases(['js', 'jsx', 'mjs', 'cjs'], { languageName: 'javascript' });
hljs.registerAliases(['ts', 'tsx'], { languageName: 'typescript' });
hljs.registerAliases(['yml'], { languageName: 'yaml' });
hljs.registerAliases(['cs', 'c#'], { languageName: 'csharp' });
hljs.registerAliases(['py'], { languageName: 'python' });
hljs.registerAliases(['rs'], { languageName: 'rust' });
hljs.registerAliases(['md'], { languageName: 'markdown' });
hljs.registerAliases(['kt'], { languageName: 'kotlin' });

/** GitHub-style heading anchor. */
export function slug(text) {
  return text.toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s/g, '-');
}

const md = new MarkdownIt({ html: true, linkify: true, typographer: false });
md.use(footnote);
md.linkify.set({ fuzzyLink: true, fuzzyEmail: true });
// GFM extended autolinks: scheme links, e-mail, and bare domains only when they start with "www.".
const linkifyMatch = md.linkify.match.bind(md.linkify);
md.linkify.match = (text) => {
  const found = (linkifyMatch(text) || []).filter((m) => m.schema !== '' || m.raw.toLowerCase().startsWith('www.') || m.url.startsWith('mailto:'));
  return found.length ? found : null;
};

// Source line numbers on every block, used for scroll sync and task toggles.
md.core.ruler.push('source_lines', (state) => {
  const counts = new Map();
  for (let i = 0; i < state.tokens.length; i++) {
    const token = state.tokens[i];
    if (token.map && token.nesting >= 0 && token.level === 0 || token.map && ['list_item_open', 'heading_open', 'fence', 'code_block', 'blockquote_open', 'paragraph_open'].includes(token.type)) {
      token.attrSet('data-line', String(token.map[0]));
    }
    if (token.type === 'heading_open') {
      const title = state.tokens[i + 1]?.children?.filter((c) => c.type === 'text' || c.type === 'code_inline').map((c) => c.content).join('') ?? '';
      const base = slug(title);
      const count = counts.get(base) ?? 0;
      counts.set(base, count + 1);
      token.attrSet('id', count ? `${base}-${count}` : base);
    }
  }
});

const alertTitles = { note: 'Nota', tip: 'Consejo', important: 'Importante', warning: 'Advertencia', caution: 'Precaución' };
const alertIcons = {
  note: '<circle cx="8" cy="8" r="6.5"/><path d="M8 7.2v4M8 4.8v.2"/>',
  tip: '<path d="M5.5 11.5h5M6.3 14h3.4M8 1.8a4.4 4.4 0 0 0-2.6 8c.4.3.6.8.6 1.3v.4h4v-.4c0-.5.2-1 .6-1.3A4.4 4.4 0 0 0 8 1.8Z"/>',
  important: '<path d="M2 3.5A1.5 1.5 0 0 1 3.5 2h9A1.5 1.5 0 0 1 14 3.5v6a1.5 1.5 0 0 1-1.5 1.5H8l-3.5 3v-3h-1A1.5 1.5 0 0 1 2 9.5Z"/><path d="M8 4.5v3M8 9.2v.2"/>',
  warning: '<path d="M7.1 2.5 1.6 12.2A1 1 0 0 0 2.5 13.7h11a1 1 0 0 0 .9-1.5L8.9 2.5a1 1 0 0 0-1.8 0Z"/><path d="M8 6v3.2M8 11.2v.2"/>',
  caution: '<path d="M5.2 1.8h5.6l3.4 3.4v5.6l-3.4 3.4H5.2l-3.4-3.4V5.2Z"/><path d="M8 4.8v3.8M8 10.8v.2"/>',
};
const svg = (paths, size = 16) => `<svg viewBox="0 0 16 16" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
export const copyIcon = svg('<rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 5.5V3.8A1.3 1.3 0 0 0 9.2 2.5H3.8a1.3 1.3 0 0 0-1.3 1.3v5.4a1.3 1.3 0 0 0 1.3 1.3h1.7"/>', 14);

function frontMatter(source) {
  const match = /^---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)\r?\n/.exec(source);
  if (!match) return null;
  const lines = match[0].split('\n').length - 1;
  return { yaml: match[1], masked: '\n'.repeat(lines) + source.slice(match[0].length) };
}

/**
 * Renders Markdown to a sanitized DOM fragment plus its outline.
 * Images and diagrams are resolved later by the caller (they are asynchronous).
 */
export function renderMarkdown(source, { allowRemote = false } = {}) {
  let text = source;
  let yaml = null;
  const front = frontMatter(source);
  if (front) { text = front.masked; yaml = front.yaml; }
  let html = md.render(text);
  if (yaml !== null) {
    html = `<pre data-line="0"><code class="language-yaml" data-label="front matter">${md.utils.escapeHtml(yaml)}</code></pre>` + html;
  }
  const fragment = DOMPurify.sanitize(html, {
    ADD_ATTR: ['data-line', 'align', 'data-label'],
    FORBID_TAGS: ['style', 'title', 'textarea', 'xmp', 'iframe', 'noembed', 'noframes', 'plaintext', 'form', 'button', 'select', 'object', 'embed', 'base'],
    FORBID_ATTR: ['style'],
    RETURN_DOM_FRAGMENT: true,
  });

  // GitHub alerts.
  for (const quote of fragment.querySelectorAll('blockquote')) {
    const first = quote.firstElementChild;
    if (!first || first.tagName !== 'P') continue;
    const marker = /^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*/i.exec(first.textContent);
    if (!marker) continue;
    const kind = marker[1].toLowerCase();
    const textNode = first.firstChild;
    if (textNode?.nodeType === Node.TEXT_NODE) {
      textNode.textContent = textNode.textContent.replace(/^\s*\[![A-Za-z]+\]\s*/, '');
      if (first.firstChild?.nodeName === 'BR') first.firstChild.remove();
    }
    if (!first.textContent.trim() && !first.querySelector('img')) first.remove();
    quote.classList.add('alert', `alert-${kind}`);
    const title = document.createElement('p');
    title.className = 'alert-title';
    title.innerHTML = svg(alertIcons[kind]) + `<span>${t(alertTitles[kind])}</span>`;
    quote.prepend(title);
  }

  // Task lists.
  for (const item of fragment.querySelectorAll('li')) {
    const holder = item.firstElementChild?.tagName === 'P' ? item.firstElementChild : item;
    const first = holder.firstChild;
    if (!first || first.nodeType !== Node.TEXT_NODE) continue;
    const match = /^\[( |x|X)\]\s+/.exec(first.textContent);
    if (!match) continue;
    first.textContent = first.textContent.slice(match[0].length);
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.className = 'task';
    box.checked = match[1] !== ' ';
    if (item.dataset.line) box.dataset.line = item.dataset.line;
    holder.prepend(box);
    item.classList.add('task-item');
    if (box.checked) item.classList.add('done');
    item.parentElement?.classList.add('contains-task');
  }
  for (const input of fragment.querySelectorAll('input:not(.task)')) input.disabled = true;

  // Code blocks and diagrams.
  for (const code of fragment.querySelectorAll('pre > code')) {
    const pre = code.parentElement;
    const language = (/language-([\w#+-]+)/.exec(code.className)?.[1] ?? '').toLowerCase();
    const line = code.dataset.line ?? pre.dataset.line;
    if (language === 'mermaid') {
      const diagram = document.createElement('div');
      diagram.className = 'diagram pending';
      diagram.dataset.source = code.textContent;
      if (line) diagram.dataset.line = line;
      diagram.innerHTML = `<pre><code>${md.utils.escapeHtml(code.textContent)}</code></pre><span class="diagram-note">mermaid · ${t('dibujando…')}</span>`;
      pre.replaceWith(diagram);
      continue;
    }
    if (language && hljs.getLanguage(language)) {
      code.innerHTML = hljs.highlight(code.textContent, { language, ignoreIllegals: true }).value;
    }
    code.classList.add('hljs');
    const box = document.createElement('div');
    box.className = 'codeblock';
    if (line) box.dataset.line = line;
    const label = code.dataset.label || language;
    box.innerHTML = `<div class="codehead"><span class="lang"></span><button class="copy" type="button" title="${t('Copiar')}">${copyIcon}</button></div>`;
    box.querySelector('.lang').textContent = label;
    pre.replaceWith(box);
    box.append(pre);
  }

  // Tables scroll horizontally instead of overflowing the column.
  for (const table of fragment.querySelectorAll('table')) {
    const wrap = document.createElement('div');
    wrap.className = 'table-wrap';
    table.replaceWith(wrap);
    wrap.append(table);
  }

  // Images: local files load through the native layer, remote ones wait for consent.
  let blocked = 0;
  for (const source of fragment.querySelectorAll('picture source')) {
    const set = source.getAttribute('srcset') ?? '';
    if (!/^(https?:|data:)/i.test(set) || (!allowRemote && /^https?:/i.test(set))) source.remove();
  }
  for (const image of fragment.querySelectorAll('img')) {
    const src = image.getAttribute('src') ?? '';
    image.loading = 'lazy';
    image.decoding = 'async';
    if (/^data:image\//i.test(src)) continue;
    if (/^https?:/i.test(src)) {
      if (allowRemote) continue;
      blocked++;
      const chip = document.createElement('a');
      chip.className = 'image-chip';
      chip.href = src;
      chip.textContent = image.getAttribute('alt') || src.split('/').pop() || t('Imagen');
      image.replaceWith(chip);
      continue;
    }
    image.dataset.local = src;
    image.removeAttribute('src');
  }

  const outline = [...fragment.querySelectorAll('h1, h2, h3, h4, h5, h6')].map((heading, index) => ({
    index,
    id: heading.id,
    level: Number(heading.tagName[1]),
    title: heading.textContent.trim(),
    line: Number(heading.dataset.line ?? 0),
  })).filter((item) => item.title);

  return { fragment, outline, blocked };
}

let mermaidModule;
const diagramCache = new Map();

/** Draws pending Mermaid blocks inside `root`. Loaded only when a document has a diagram. */
export async function renderDiagrams(root, dark) {
  const pending = [...root.querySelectorAll('.diagram[data-source]')];
  if (!pending.length) return;
  if (!mermaidModule) mermaidModule = (await import('mermaid')).default;
  mermaidModule.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'neutral',
    fontFamily: 'var(--body-font)' });
  for (const node of pending) {
    const source = node.dataset.source;
    const key = (dark ? 'd:' : 'l:') + source;
    try {
      let svgText = diagramCache.get(key);
      if (!svgText) {
        ({ svg: svgText } = await mermaidModule.render('m' + Math.random().toString(36).slice(2), source));
        diagramCache.set(key, svgText);
      }
      node.innerHTML = svgText;
      node.classList.remove('pending', 'failed');
    } catch (error) {
      node.classList.remove('pending');
      node.classList.add('failed');
      const note = node.querySelector('.diagram-note');
      if (note) note.textContent = 'mermaid · ' + String(error?.message ?? error).split('\n')[0];
    }
  }
}
