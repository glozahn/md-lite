import { EditorState, EditorSelection, Compartment } from '@codemirror/state';
import { EditorView, keymap, drawSelection, dropCursor, ViewPlugin, Decoration, WidgetType } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab, undo, redo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { syntaxHighlighting, HighlightStyle, syntaxTree } from '@codemirror/language';
import { search, searchKeymap, openSearchPanel, highlightSelectionMatches, findNext, findPrevious } from '@codemirror/search';
import { tags } from '@lezer/highlight';
import { t } from './i18n.js';

const markStyle = HighlightStyle.define([
  { tag: tags.heading1, fontWeight: '700' },
  { tag: [tags.heading2, tags.heading3, tags.heading4, tags.heading5, tags.heading6], fontWeight: '650' },
  { tag: tags.strong, fontWeight: '700' },
  { tag: tags.emphasis, fontStyle: 'italic' },
  { tag: tags.strikethrough, textDecoration: 'line-through' },
  { tag: tags.link, color: 'var(--accent)' },
  { tag: tags.url, color: 'var(--muted)' },
  { tag: tags.monospace, fontFamily: 'var(--mono-font)', fontSize: '0.9em' },
  { tag: tags.quote, color: 'var(--muted)' },
  { tag: [tags.processingInstruction, tags.meta, tags.contentSeparator], color: 'var(--faint)' },
  { tag: tags.list, color: 'var(--muted)' },
]);

class CheckboxWidget extends WidgetType {
  constructor(checked, from) { super(); this.checked = checked; this.from = from; }
  eq(other) { return other.checked === this.checked && other.from === this.from; }
  toDOM(view) {
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.className = 'cm-task';
    box.checked = this.checked;
    box.addEventListener('mousedown', (event) => {
      event.preventDefault();
      view.dispatch({ changes: { from: this.from + 1, to: this.from + 2, insert: this.checked ? ' ' : 'x' } });
    });
    return box;
  }
  ignoreEvent() { return false; }
}

class BulletWidget extends WidgetType {
  eq() { return true; }
  toDOM() {
    const span = document.createElement('span');
    span.className = 'cm-bullet';
    span.textContent = '•';
    return span;
  }
}

class RuleWidget extends WidgetType {
  eq() { return true; }
  toDOM() {
    const span = document.createElement('span');
    span.className = 'cm-rule';
    return span;
  }
}

const hidden = Decoration.replace({});
const bullet = Decoration.replace({ widget: new BulletWidget() });
const rule = Decoration.replace({ widget: new RuleWidget() });
const lineClass = (name) => Decoration.line({ class: name });

/** Typora-style live preview: Markdown markers disappear outside the lines being edited. */
const livePreview = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = this.build(view); }
  update(update) {
    if (update.docChanged || update.viewportChanged || update.selectionSet || syntaxTree(update.startState) !== syntaxTree(update.state)) {
      this.decorations = this.build(update.view);
    }
  }
  build(view) {
    const { state } = view;
    const active = new Set();
    for (const range of state.selection.ranges) {
      const first = state.doc.lineAt(range.from).number, last = state.doc.lineAt(range.to).number;
      for (let n = first; n <= last; n++) active.add(n);
    }
    const isActive = (from, to = from) => {
      const a = state.doc.lineAt(from).number, b = state.doc.lineAt(to).number;
      for (let n = a; n <= b; n++) if (active.has(n)) return true;
      return false;
    };
    const decorations = [];
    const hide = (from, to) => { if (to > from) decorations.push(hidden.range(from, to)); };
    for (const { from, to } of view.visibleRanges) {
      syntaxTree(state).iterate({
        from, to,
        enter: (node) => {
          const name = node.name;
          const heading = /^(?:ATX|Setext)Heading(\d)$/.exec(name);
          if (heading) {
            for (let pos = node.from; pos <= node.to;) {
              const line = state.doc.lineAt(pos);
              decorations.push(lineClass(`cm-h cm-h${heading[1]}`).range(line.from));
              pos = line.to + 1;
            }
            return;
          }
          switch (name) {
            case 'HeaderMark': {
              if (isActive(node.from)) return;
              const next = state.sliceDoc(node.to, node.to + 1);
              hide(node.from, node.to + (next === ' ' ? 1 : 0));
              return;
            }
            case 'EmphasisMark':
            case 'StrikethroughMark':
              if (!isActive(node.from)) hide(node.from, node.to);
              return;
            case 'LinkMark':
            case 'URL': {
              // Only real links lose their syntax; `[!NOTE]` and undefined references stay visible.
              const parent = node.node.parent;
              if (!parent || (parent.name !== 'Link' && parent.name !== 'Image') || !parent.getChild('URL')) return;
              if (!isActive(node.from)) hide(node.from, node.to);
              return;
            }
            case 'Table':
              for (let pos = node.from; pos <= node.to;) {
                const line = state.doc.lineAt(pos);
                decorations.push(lineClass('cm-table').range(line.from));
                pos = line.to + 1;
              }
              return;
            case 'CodeMark':
              if (node.node.parent?.name === 'InlineCode' && !isActive(node.from)) hide(node.from, node.to);
              return;
            case 'InlineCode':
              decorations.push(Decoration.mark({ class: 'cm-inline-code' }).range(node.from, node.to));
              return;
            case 'FencedCode': {
              const block = isActive(node.from, node.to);
              for (let pos = node.from; pos <= node.to;) {
                const line = state.doc.lineAt(pos);
                const edge = line.from === state.doc.lineAt(node.from).from || line.to === state.doc.lineAt(node.to).to;
                const first = line.from === state.doc.lineAt(node.from).from;
                const last = line.to === state.doc.lineAt(node.to).to;
                decorations.push(lineClass(`cm-code${first ? ' cm-code-first' : ''}${last ? ' cm-code-last' : ''}${edge && !block ? ' cm-fence-hidden' : ''}`).range(line.from));
                if (edge && !block && /^\s*(`{3,}|~{3,})/.test(line.text)) hide(line.from, line.to);
                pos = line.to + 1;
              }
              return false;
            }
            case 'Blockquote':
              for (let pos = node.from; pos <= node.to;) {
                const line = state.doc.lineAt(pos);
                decorations.push(lineClass('cm-quote').range(line.from));
                pos = line.to + 1;
              }
              return;
            case 'QuoteMark':
              if (!isActive(node.from)) {
                const next = state.sliceDoc(node.to, node.to + 1);
                hide(node.from, node.to + (next === ' ' ? 1 : 0));
              }
              return;
            case 'ListMark': {
              const item = node.node.parent;
              const task = item?.getChild('Task');
              if (task && !isActive(node.from)) {
                hide(node.from, task.from);
              } else if (item?.parent?.name === 'BulletList' && !task) {
                decorations.push(bullet.range(node.from, node.to));
              }
              return;
            }
            case 'TaskMarker':
              if (!isActive(node.from)) {
                const checked = /x/i.test(state.sliceDoc(node.from, node.to));
                decorations.push(Decoration.replace({ widget: new CheckboxWidget(checked, node.from) }).range(node.from, node.to));
              }
              return;
            case 'HorizontalRule':
              if (!isActive(node.from)) decorations.push(rule.range(node.from, node.to));
              return;
            default:
              return;
          }
        },
      });
    }
    return Decoration.set(decorations, true);
  }
}, { decorations: (plugin) => plugin.decorations });

const liveTheme = EditorView.theme({
  '.cm-content': { fontFamily: 'var(--body-font)', fontSize: 'var(--font-size)', lineHeight: '1.65' },
  '.cm-h1': { fontSize: '2em', fontWeight: '700', lineHeight: '1.3', paddingTop: '0.35em' },
  '.cm-h2': { fontSize: '1.5em', fontWeight: '650', lineHeight: '1.3', paddingTop: '0.6em' },
  '.cm-h3': { fontSize: '1.25em', fontWeight: '650', paddingTop: '0.4em' },
  '.cm-h4': { fontSize: '1.08em', fontWeight: '650' },
  '.cm-h6': { color: 'var(--muted)' },
  '.cm-code': { fontFamily: 'var(--mono-font)', fontSize: '0.82em', background: 'var(--code-bg)', paddingLeft: '18px !important', paddingRight: '18px !important' },
  '.cm-code-first': { borderTopLeftRadius: '10px', borderTopRightRadius: '10px', paddingTop: '10px' },
  '.cm-code-last': { borderBottomLeftRadius: '10px', borderBottomRightRadius: '10px', paddingBottom: '10px' },
  '.cm-fence-hidden': { fontSize: '4px', lineHeight: '4px' },
  '.cm-quote': { borderLeft: '3px solid var(--rule)', paddingLeft: '16px !important', color: 'var(--muted)' },
  '.cm-table': { fontFamily: 'var(--mono-font)', fontSize: '0.84em' },
  '.cm-inline-code': { background: 'var(--inline-code)', borderRadius: '4px', padding: '1px 3px' },
  '.cm-bullet': { color: 'var(--muted)', padding: '0 0.2em' },
  '.cm-task': { accentColor: 'var(--accent)', margin: '0 6px 0 0', transform: 'translateY(2px)', cursor: 'pointer' },
  '.cm-rule': { display: 'inline-block', width: '100%', borderTop: '1px solid var(--rule)', verticalAlign: 'middle' },
});

const sourceTheme = EditorView.theme({
  '.cm-content': { fontFamily: 'var(--mono-font)', fontSize: 'calc(var(--font-size) * 0.84)', lineHeight: '1.6' },
});

function wrapSelection(view, marker, placeholder) {
  const m = marker.length;
  view.dispatch(view.state.changeByRange((range) => {
    const text = view.state.sliceDoc(range.from, range.to);
    const before = view.state.sliceDoc(range.from - m, range.from);
    const after = view.state.sliceDoc(range.to, range.to + m);
    if (before === marker && after === marker) {
      return { changes: [{ from: range.from - m, to: range.from }, { from: range.to, to: range.to + m }],
        range: EditorSelection.range(range.from - m, range.to - m) };
    }
    if (text.length >= 2 * m && text.startsWith(marker) && text.endsWith(marker)) {
      return { changes: { from: range.from, to: range.to, insert: text.slice(m, -m) },
        range: EditorSelection.range(range.from, range.to - 2 * m) };
    }
    const inner = text || placeholder;
    return { changes: { from: range.from, to: range.to, insert: marker + inner + marker },
      range: EditorSelection.range(range.from + m, range.from + m + inner.length) };
  }));
  return true;
}

function transformLines(view, transform) {
  const { state } = view;
  const lines = [];
  for (const range of state.selection.ranges) {
    for (let n = state.doc.lineAt(range.from).number; n <= state.doc.lineAt(range.to).number; n++) {
      if (!lines.includes(n)) lines.push(n);
    }
  }
  const texts = lines.map((n) => state.doc.line(n).text);
  const next = transform(texts);
  view.dispatch({ changes: lines.map((n, i) => ({ from: state.doc.line(n).from, to: state.doc.line(n).to, insert: next[i] })) });
  return true;
}

const listPrefix = /^(\s*)(?:[-+*]|\d{1,9}[.)])\s+(?:\[[ xX]\]\s+)?/;

function toggleList(view, make, kind) {
  return transformLines(view, (lines) => {
    const content = lines.filter((l) => l.trim());
    const same = content.length && content.every((l) => {
      const m = listPrefix.exec(l);
      if (!m) return false;
      const task = /\[[ xX]\]/.test(m[0]);
      const numbered = /\d/.test(m[0].trim()[0]);
      return kind === 'task' ? task : kind === 'numbered' ? numbered && !task : !numbered && !task;
    });
    let index = 0;
    return lines.map((line) => {
      if (!line.trim()) return line;
      const m = listPrefix.exec(line);
      const indent = m ? m[1] : '';
      const body = m ? line.slice(m[0].length) : line;
      return same ? indent + body : indent + make(index++) + body;
    });
  });
}

export const formatActions = {
  bold: (view) => wrapSelection(view, '**', t('texto')),
  italic: (view) => wrapSelection(view, '*', t('texto')),
  strikethrough: (view) => wrapSelection(view, '~~', t('texto')),
  code: (view) => wrapSelection(view, '`', t('código')),
  link: (view) => {
    view.dispatch(view.state.changeByRange((range) => {
      const text = view.state.sliceDoc(range.from, range.to) || t('enlace');
      const insert = `[${text}](https://)`;
      const start = range.from + text.length + 3;
      return { changes: { from: range.from, to: range.to, insert }, range: EditorSelection.range(start, start + 8) };
    }));
    return true;
  },
  heading1: (view) => setHeading(view, 1),
  heading2: (view) => setHeading(view, 2),
  heading3: (view) => setHeading(view, 3),
  paragraph: (view) => setHeading(view, 0),
  bulletList: (view) => toggleList(view, () => '- ', 'bullet'),
  numberedList: (view) => toggleList(view, (i) => `${i + 1}. `, 'numbered'),
  taskList: (view) => toggleList(view, () => '- [ ] ', 'task'),
  quote: (view) => transformLines(view, (lines) => {
    const all = lines.every((l) => !l.trim() || l.startsWith('>'));
    return lines.map((l) => (all ? l.replace(/^>\s?/, '') : '> ' + l));
  }),
  codeBlock: (view) => insertBlock(view, '```\n\n```', 4),
  table: (view) => insertBlock(view, `| ${t('Columna')} 1 | ${t('Columna')} 2 |\n| --- | --- |\n|  |  |`, 2),
  rule: (view) => insertBlock(view, '---', 3),
};

function setHeading(view, level) {
  return transformLines(view, (lines) => lines.map((line) => {
    const current = /^\s{0,3}(#{1,6})\s/.exec(line)?.[1].length ?? 0;
    const stripped = line.replace(/^\s{0,3}#{1,6}\s+/, '');
    return level === 0 || current === level ? stripped : '#'.repeat(level) + ' ' + stripped;
  }));
}

function insertBlock(view, block, caret) {
  const { state } = view;
  const line = state.doc.lineAt(state.selection.main.head);
  const empty = !line.text.trim();
  const from = empty ? line.from : line.to;
  const insert = empty ? block : '\n\n' + block;
  view.dispatch({ changes: { from, to: empty ? line.to : line.to, insert },
    selection: { anchor: from + (empty ? 0 : 2) + caret } });
  view.focus();
  return true;
}

const formatKeymap = [
  { key: 'Mod-b', run: formatActions.bold },
  { key: 'Mod-i', run: formatActions.italic },
  { key: 'Mod-Shift-x', run: formatActions.strikethrough },
  { key: 'Mod-Shift-k', run: formatActions.code },
  { key: 'Mod-k', run: formatActions.link },
  { key: 'Mod-Alt-1', run: formatActions.heading1 },
  { key: 'Mod-Alt-2', run: formatActions.heading2 },
  { key: 'Mod-Alt-3', run: formatActions.heading3 },
  { key: 'Mod-Alt-0', run: formatActions.paragraph },
  { key: 'Mod-Shift-7', run: formatActions.bulletList },
  { key: 'Mod-Shift-9', run: formatActions.numberedList },
  { key: 'Mod-Shift-l', run: formatActions.taskList },
  { key: "Mod-'", run: formatActions.quote },
  { key: 'Mod-Shift-m', run: formatActions.codeBlock },
  { key: 'Mod-Alt-t', run: formatActions.table },
  { key: 'Mod-Shift-z', run: redo, preventDefault: true },
  { key: 'Mod-y', run: redo, preventDefault: true },
];

export function createEditor(parent, { onChange }) {
  const modeSlot = new Compartment();
  const extensions = (mode) => [
    history(),
    drawSelection(),
    dropCursor(),
    EditorView.lineWrapping,
    EditorState.allowMultipleSelections.of(true),
    markdown({ base: markdownLanguage }),
    syntaxHighlighting(markStyle),
    search({ top: true }),
    highlightSelectionMatches(),
    keymap.of([...formatKeymap, ...searchKeymap, ...historyKeymap, indentWithTab, ...defaultKeymap]),
    modeSlot.of(mode === 'edit' ? [livePreview, liveTheme] : [sourceTheme]),
    EditorView.contentAttributes.of({ spellcheck: 'true', autocapitalize: 'off' }),
    EditorView.updateListener.of((update) => { if (update.docChanged) onChange(update.state.doc.toString()); }),
  ];
  let mode = 'edit';
  const view = new EditorView({ parent, state: EditorState.create({ doc: '', extensions: extensions(mode) }) });

  return {
    view,
    get text() { return view.state.doc.toString(); },
    /** Replaces the document and forgets undo history (a different file). */
    load(text) { view.setState(EditorState.create({ doc: text, extensions: extensions(mode) })); },
    /** A fresh state for another tab; swapping states keeps each tab's undo history. */
    createState(text, stateMode = 'edit') { return EditorState.create({ doc: text, extensions: extensions(stateMode) }); },
    get state() { return view.state; },
    restore(state, stateMode) {
      mode = stateMode === 'split' ? 'source' : stateMode;
      view.setState(state);
      view.dispatch({ effects: modeSlot.reconfigure(mode === 'edit' ? [livePreview, liveTheme] : [sourceTheme]) });
      view.contentDOM.spellcheck = mode === 'edit';
    },
    /** Replaces the text keeping history (reload after an external change). */
    replace(text) { view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } }); },
    setMode(next) {
      mode = next === 'split' ? 'source' : next;
      view.dispatch({ effects: modeSlot.reconfigure(mode === 'edit' ? [livePreview, liveTheme] : [sourceTheme]) });
      view.contentDOM.spellcheck = next === 'edit';
    },
    focus() { view.focus(); },
    format(action) { formatActions[action]?.(view); view.focus(); },
    undo() { undo(view); },
    redo() { redo(view); },
    find() { openSearchPanel(view); },
    findNext() { findNext(view); },
    findPrevious() { findPrevious(view); },
    toggleTask(lineIndex) {
      const line = view.state.doc.line(lineIndex + 1);
      const match = /\[( |x|X)\]/.exec(line.text);
      if (!match) return;
      const at = line.from + match.index + 1;
      view.dispatch({ changes: { from: at, to: at + 1, insert: match[1] === ' ' ? 'x' : ' ' } });
    },
    topLine() {
      const block = view.lineBlockAtHeight(view.scrollDOM.scrollTop - view.documentTop + view.scrollDOM.getBoundingClientRect().top + 8);
      return view.state.doc.lineAt(block.from).number - 1;
    },
    scrollToLine(lineIndex, select = true) {
      const line = view.state.doc.line(Math.min(view.state.doc.lines, Math.max(1, lineIndex + 1)));
      view.dispatch({
        selection: select ? { anchor: line.from } : undefined,
        effects: EditorView.scrollIntoView(line.from, { y: 'start', yMargin: 24 }),
      });
    },
  };
}
