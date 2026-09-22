// Thin wrapper over Tauri. In a plain browser (vite dev) it falls back to in-memory files
// so the interface can be developed and tested without the native shell.

export const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

const memory = new Map();
let core, dialog, opener, windowApi, pathApi, appApi;

async function tauri() {
  if (!core) {
    [core, dialog, opener, windowApi, pathApi, appApi] = await Promise.all([
      import('@tauri-apps/api/core'),
      import('@tauri-apps/plugin-dialog'),
      import('@tauri-apps/plugin-opener'),
      import('@tauri-apps/api/window'),
      import('@tauri-apps/api/path'),
      import('@tauri-apps/api/app'),
    ]);
  }
  return { core, dialog, opener, windowApi, pathApi, appApi };
}

const markdownFilter = [{ name: 'Markdown', extensions: ['md', 'markdown', 'mdown', 'mkd', 'txt'] }];

export const platform = {
  async readText(path) {
    if (!isTauri) {
      if (memory.has(path)) return memory.get(path);
      throw new Error('not-found');
    }
    const { core } = await tauri();
    return core.invoke('read_text', { path });
  },

  async writeText(path, contents) {
    if (!isTauri) { memory.set(path, contents); return; }
    const { core } = await tauri();
    await core.invoke('write_text', { path, contents });
  },

  async modified(path) {
    if (!isTauri) return 0;
    const { core } = await tauri();
    return core.invoke('modified', { path });
  },

  /** Returns an object URL for a local image, or null. */
  async imageURL(path) {
    if (!isTauri) return null;
    const { core } = await tauri();
    const bytes = await core.invoke('read_image', { path });
    const lower = path.toLowerCase();
    const type = lower.endsWith('.svg') ? 'image/svg+xml' : undefined;
    return URL.createObjectURL(new Blob([bytes], type ? { type } : {}));
  },

  async initialFile() {
    if (!isTauri) return null;
    const { core } = await tauri();
    return core.invoke('initial_file');
  },

  async listMarkdown(path) {
    if (!isTauri) return [];
    const { core } = await tauri();
    return core.invoke('list_markdown', { path });
  },

  async isDirectory(path) {
    if (!isTauri) return false;
    const { core } = await tauri();
    return core.invoke('is_dir', { path });
  },

  async folderDialog() {
    if (!isTauri) return null;
    const { dialog } = await tauri();
    const result = await dialog.open({ multiple: false, directory: true });
    return typeof result === 'string' ? result : null;
  },

  async openDialog() {
    if (!isTauri) return null;
    const { dialog } = await tauri();
    const result = await dialog.open({ multiple: false, directory: false, filters: markdownFilter });
    return typeof result === 'string' ? result : null;
  },

  async saveDialog(defaultPath) {
    if (!isTauri) {
      const name = window.prompt('Save as', defaultPath);
      return name ? '/memory/' + name : null;
    }
    const { dialog } = await tauri();
    return dialog.save({ defaultPath, filters: [{ name: 'Markdown', extensions: ['md'] }] });
  },

  /** Three-way question. Resolves to 'yes', 'no' or 'cancel'. */
  async ask3(message, detail, labels) {
    if (!isTauri) {
      if (window.confirm(`${message}\n\n${detail}\n\nOK = ${labels.yes}`)) return 'yes';
      return window.confirm(labels.no + '?') ? 'no' : 'cancel';
    }
    const { dialog } = await tauri();
    const result = await dialog.message(`${message}\n\n${detail}`, {
      kind: 'warning',
      buttons: { yes: labels.yes, no: labels.no, cancel: labels.cancel },
    });
    if (result === labels.yes || result === 'Yes') return 'yes';
    if (result === labels.no || result === 'No') return 'no';
    return 'cancel';
  },

  async message(text, title) {
    if (!isTauri) { window.alert(text); return; }
    const { dialog } = await tauri();
    await dialog.message(text, { title });
  },

  async confirm(text, okLabel, cancelLabel) {
    if (!isTauri) return window.confirm(text);
    const { dialog } = await tauri();
    return dialog.confirm(text, { okLabel, cancelLabel });
  },

  async openURL(url) {
    if (!isTauri) { window.open(url, '_blank', 'noopener'); return; }
    const { opener } = await tauri();
    await opener.openUrl(url);
  },

  async dirname(path) {
    if (!isTauri) return path.replace(/[\\/][^\\/]*$/, '') || '/';
    const { pathApi } = await tauri();
    return pathApi.dirname(path);
  },

  async resolve(base, relative) {
    if (!isTauri) return base.replace(/\/$/, '') + '/' + relative;
    const { pathApi } = await tauri();
    return pathApi.resolve(base, relative);
  },

  async basename(path) {
    if (!isTauri) return path.split(/[\\/]/).pop();
    const { pathApi } = await tauri();
    return pathApi.basename(path);
  },

  async setTitle(title) {
    document.title = title;
    if (!isTauri) return;
    const { windowApi } = await tauri();
    await windowApi.getCurrentWindow().setTitle(title);
  },

  async version() {
    if (!isTauri) return '0.3.2';
    const { appApi } = await tauri();
    return appApi.getVersion();
  },

  async onDrop(handler) {
    if (!isTauri) {
      window.addEventListener('dragover', (event) => event.preventDefault());
      window.addEventListener('drop', async (event) => {
        event.preventDefault();
        const file = event.dataTransfer?.files?.[0];
        if (!file) return;
        const path = '/memory/' + file.name;
        memory.set(path, await file.text());
        handler([path]);
      });
      return;
    }
    const { windowApi } = await tauri();
    await windowApi.getCurrentWindow().onDragDropEvent((event) => {
      if (event.payload.type === 'drop' && event.payload.paths?.length) handler(event.payload.paths);
    });
  },

  /** `handler` returns true when the window may close. */
  async onCloseRequested(handler) {
    if (!isTauri) {
      window.addEventListener('beforeunload', (event) => {
        if (!handler.sync()) event.preventDefault();
      });
      return;
    }
    const { windowApi } = await tauri();
    const current = windowApi.getCurrentWindow();
    await current.onCloseRequested(async (event) => {
      event.preventDefault();
      if (await handler()) await current.destroy();
    });
  },

  /** Seeds the in-memory file system for browser previews. */
  seed(path, text) { memory.set(path, text); },
};
