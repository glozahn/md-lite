import SwiftUI
import AppKit

@main
struct MDLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ReaderStore.shared

    var body: some Scene {
        Window("MD Lite", id: "reader") {
            ReaderWindow(store: store)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        }
        .defaultSize(width: 1120, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir Markdown…", action: store.openPanel).keyboardShortcut("o")
                Menu("Abrir reciente") {
                    ForEach(store.recent, id: \.self) { url in
                        Button(url.lastPathComponent) { store.open(url) }
                    }
                }
            }
            CommandGroup(after: .textEditing) {
                Button("Buscar en el documento") { store.findRequest += 1 }.keyboardShortcut("f")
            }
            CommandMenu("Lectura") {
                Button(store.focusMode ? "Salir del modo enfoque" : "Modo enfoque") { store.focusMode.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Toggle("Ver código fuente", isOn: $store.showSource).keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Aumentar texto") { store.zoom(1) }.keyboardShortcut("+")
                Button("Reducir texto") { store.zoom(-1) }.keyboardShortcut("-")
                Button("Tamaño original") { store.fontSize = 17; store.rebuild() }.keyboardShortcut("0")
                Divider()
                Button("Actualizar", action: store.reload).keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { ReaderStore.shared.open(url) }
        application.windows.first?.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ReaderWindow: View {
    @ObservedObject var store: ReaderStore
    @State private var isDropTarget = false
    @Environment(\.colorScheme) private var colorScheme

    private var paper: Color { colorScheme == .dark ? Color(red: 0.085, green: 0.095, blue: 0.11) : Color(red: 0.985, green: 0.981, blue: 0.967) }

    var body: some View {
        HStack(spacing: 0) {
            if !store.focusMode {
                sidebar.frame(width: 238)
                    .background(.ultraThinMaterial)
                Divider()
            }
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                NativeReader(store: store)
                    .frame(maxWidth: 850)
                    .frame(maxWidth: .infinity)
                    .background(paper)
                footer
            }
            .background(paper)
        }
        .tint(.teal)
        .background(.background)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.teal, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            store.open(url)
            return true
        } isTargeted: { isDropTarget = $0 }
        .alert("No se pudo leer el archivo", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Entendido", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(.teal.opacity(0.12)).frame(width: 37, height: 37)
                    Image(systemName: "text.book.closed.fill").font(.system(size: 18, weight: .medium)).foregroundStyle(.teal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("MD Lite").font(.system(size: 16, weight: .semibold))
                    Text("ESPACIO PARA LEER").font(.system(size: 8, weight: .medium)).tracking(1.7).foregroundStyle(.secondary)
                }
            }.padding(.top, 48).padding(.horizontal, 22).padding(.bottom, 26)

            Button(action: store.openPanel) {
                HStack {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    Text("Abrir documento").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("⌘O").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(11).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("DOCUMENTO")
                    Button { store.welcome() } label: {
                        Label("Bienvenido", systemImage: "sparkle").font(.system(size: 12))
                            .foregroundStyle(store.fileURL == nil ? Color.teal : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            .background(store.fileURL == nil ? .teal.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                    if store.fileURL != nil {
                        Label(store.title, systemImage: "doc.text").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.teal).lineLimit(1).padding(9)
                    }
                    sectionLabel("EN ESTA PÁGINA").padding(.top, 16)
                    if store.rendered.outline.isEmpty {
                        Text("Los títulos aparecerán aquí.").font(.system(size: 11)).foregroundStyle(.tertiary).padding(9)
                    }
                    ForEach(store.rendered.outline) { item in
                        Button { store.navigate(item) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                RoundedRectangle(cornerRadius: 1).fill(store.selectedHeading == item.id ? Color.teal : Color.secondary.opacity(0.25))
                                    .frame(width: 2, height: 12).padding(.top, 2)
                                Text(item.title).font(.system(size: 11, weight: store.selectedHeading == item.id ? .medium : .regular))
                                    .foregroundStyle(store.selectedHeading == item.id ? Color.teal : Color.secondary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.padding(.vertical, 7).padding(.leading, 9 + CGFloat(max(0, item.level - 1)) * 9)
                        }.buttonStyle(.plain)
                    }
                    if !store.recent.isEmpty {
                        sectionLabel("RECIENTES").padding(.top, 18)
                        ForEach(store.recent.prefix(5), id: \.self) { url in
                            Button { store.open(url) } label: {
                                Label(url.lastPathComponent, systemImage: "doc.plaintext")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            }.buttonStyle(.plain).help(url.path)
                        }
                    }
                }.padding(16)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(.teal).frame(width: 5, height: 5)
                Text("LOCAL. SIMPLE. TUYO.").font(.system(size: 8, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
            }.padding(23)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.bottom, 5)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            if store.focusMode { Spacer().frame(width: 60) }
            toolButton("sidebar.left", label: store.focusMode ? "Mostrar barra lateral" : "Modo enfoque") { store.focusMode.toggle() }
            HStack(spacing: 7) {
                Image(systemName: "doc.text").foregroundStyle(.tertiary)
                Text(store.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(".md").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            toolButton("magnifyingglass", label: "Buscar · ⌘F") { store.findRequest += 1 }
            toolButton("chevron.left.forwardslash.chevron.right", label: "Ver código fuente · ⇧⌘S", active: store.showSource) { store.showSource.toggle() }
            Menu {
                Button("Aumentar texto") { store.zoom(1) }
                Button("Reducir texto") { store.zoom(-1) }
                Divider()
                Picker("Apariencia", selection: $store.appearance) {
                    Text("Sistema").tag("system")
                    Text("Claro").tag("light")
                    Text("Oscuro").tag("dark")
                }
            } label: { Image(systemName: "textformat.size").font(.system(size: 14)).frame(width: 25, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().help("Tipografía y apariencia")
        }.padding(.horizontal, 24).frame(height: 66)
    }

    private func toolButton(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(active ? Color.teal : Color.secondary)
                .frame(width: 28, height: 28).background(active ? .teal.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft").font(.system(size: 9))
            Text("\(store.wordCount) palabras")
            Text("·")
            Text("\(store.readingMinutes) min de lectura")
            Spacer()
            Text(store.showSource ? "CÓDIGO FUENTE" : "MARKDOWN") .tracking(1.1)
            Circle().fill(.teal.opacity(0.65)).frame(width: 4, height: 4)
            Text("UTF-8")
        }.font(.system(size: 9)).foregroundStyle(.tertiary)
            .padding(.horizontal, 28).frame(height: 34)
            .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.05)).frame(height: 1) }
    }
}
