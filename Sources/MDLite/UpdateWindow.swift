import SwiftUI

/// MD Lite ▸ Check for Updates…: a small window that says what is happening — checking,
/// a download bar while the new version arrives, or that this one is already the newest.
@MainActor
enum UpdateWindow {
    private static var window: NSWindow?

    static func show(_ prefs: AppPreferences) {
        if window == nil {
            let host = NSHostingController(rootView: UpdateView(prefs: prefs))
            let panel = NSWindow(contentViewController: host)
            panel.styleMask = [.titled, .closable, .fullSizeContentView]
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.identifier = NSUserInterfaceItemIdentifier("updates")
            panel.title = prefs.t("Buscar actualizaciones")
            window = panel
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        Updater.shared.checkNow(prefs)
    }

    static func close() { window?.close() }
}

private struct UpdateView: View {
    @ObservedObject var prefs: AppPreferences
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            progress.frame(height: 18)
            HStack(spacing: 10) { buttons }
        }
        .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 22)
        .frame(width: 360)
        .tint(prefs.accentColor)
        .preferredColorScheme(prefs.colorScheme)
    }

    private var current: String { UpdateChecker.currentVersion }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: return prefs.t("Buscando actualizaciones…")
        case .upToDate: return prefs.t("MD Lite está al día")
        case .available(let version, _): return String(format: prefs.t("MD Lite %@ está disponible"), version)
        case .downloading(let version, _): return String(format: prefs.t("Descargando MD Lite %@…"), version)
        case .verifying(let version): return String(format: prefs.t("Comprobando MD Lite %@…"), version)
        case .ready(let version): return String(format: prefs.t("MD Lite %@ está listo"), version)
        case .failed: return prefs.t("No se pudo actualizar")
        }
    }

    private var detail: String {
        switch updater.phase {
        case .idle, .checking: return String(format: prefs.t("Tienes la versión %@."), current)
        case .upToDate: return String(format: prefs.t("Tienes la versión más reciente (%@)."), current)
        case .available: return String(format: prefs.t("Tienes la versión %@. Descárgala desde GitHub e instálala en Aplicaciones."), current)
        case .downloading: return prefs.t("Puedes seguir trabajando; se descarga en segundo plano.")
        case .verifying: return prefs.t("Comprobando la firma del desarrollador y la notarización de Apple.")
        case .ready: return prefs.t("Reinicia ahora para usarla, o se instalará cuando salgas de MD Lite. Tus documentos se vuelven a abrir.")
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var progress: some View {
        switch updater.phase {
        case .idle, .checking, .verifying:
            ProgressView().progressViewStyle(.linear)
        case .downloading(_, let fraction):
            if let fraction {
                HStack(spacing: 8) {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                    Text("\(Int(fraction * 100)) %").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
        case .ready:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundStyle(prefs.accentColor)
        case .available, .failed:
            Color.clear
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.phase {
        case .ready:
            Button(prefs.t("Más tarde")) { UpdateWindow.close() }.keyboardShortcut(.cancelAction)
            Button(prefs.t("Reiniciar y actualizar")) { updater.install(relaunch: true) }.keyboardShortcut(.defaultAction)
        case .available(_, let page):
            Button(prefs.t("Más tarde")) { UpdateWindow.close() }.keyboardShortcut(.cancelAction)
            Button(prefs.t("Descargar")) { NSWorkspace.shared.open(page); UpdateWindow.close() }.keyboardShortcut(.defaultAction)
        case .failed:
            Button(prefs.t("Ver novedades")) {
                if let page = URL(string: "https://github.com/\(UpdateChecker.repository)/releases/latest") { NSWorkspace.shared.open(page) }
            }
            Button(prefs.t("Reintentar")) { updater.checkNow(prefs) }.keyboardShortcut(.defaultAction)
        case .upToDate:
            Button(prefs.t("Ver novedades")) { UpdateWindow.close(); openChangelog() }
            Button(prefs.t("Listo")) { UpdateWindow.close() }.keyboardShortcut(.defaultAction)
        default:
            Button(prefs.t("Ocultar")) { UpdateWindow.close() }.keyboardShortcut(.cancelAction)
        }
    }

    private func openChangelog() {
        guard let bench = DocumentRouter.shared.keyBench ?? DocumentRouter.shared.workbenches.first else { return }
        let target = bench.focusedStore.canReuseForNewDocument ? bench.focusedStore : bench.newTab()
        target.readChangelog()
        bench.window?.makeKeyAndOrderFront(nil)
    }
}
