import SwiftUI
import AppKit

/// App-owned text updates immediately; native macOS dialogs follow the OS language.
enum ReaderLanguage {
    static func resolve(_ selection: String, preferred: [String] = Locale.preferredLanguages) -> String {
        if ["en", "es"].contains(selection) { return selection }
        return preferred.first(where: {
            let code = $0.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            return code == "en" || code == "es"
        }).map { $0.lowercased().hasPrefix("es") ? "es" : "en" } ?? "en"
    }
    static func text(_ key: String, language: String) -> String {
        language == "es" ? key : english[key] ?? key
    }
    static let english: [String: String] = [
        "Texto pegado": "Pasted Text",
        "Pegar Markdown": "Paste Markdown",
        "Nueva nota": "New note",
        "Crear nota": "Create Note",
        "Guardar Markdown": "Save Markdown",
        "Escribir": "Write",
        "Vista previa": "Preview",
        "Título": "Heading",
        "Subtítulo": "Subheading",
        "Negrita": "Bold",
        "Lista": "List",
        "Tabla": "Table",
        "No se pudo guardar": "Unable to save",
        "Suelta un Markdown aquí": "Drop a Markdown file here",
        "o crea una nota nueva": "or create a new note",
        "Lectura local": "Local reading",
        "Acerca de MD Lite": "About MD Lite",
        "Un lector Markdown nativo y ligero para macOS.": "A lightweight native Markdown reader for macOS.",
        "Visitar GitHub y dejar una estrella": "Visit GitHub and leave a star",
        "Pegar y leer": "Paste and Read",
        "Pega o escribe tu Markdown aquí.": "Paste or type your Markdown here.",
        "Vista de lectura": "Reading View",
        "Cancelar": "Cancel",
        "Este texto es temporal y no se guarda al cerrar la app.": "This text is temporary and is not saved when you close the app.",
        "Preferencias": "Preferences",

        "Abrir Markdown…": "Open Markdown…",
        "Abrir reciente": "Open Recent",
        "Buscar en el documento": "Find in Document",
        "Lectura": "Reading",
        "Salir del modo enfoque": "Exit Focus Mode",
        "Modo enfoque": "Focus Mode",
        "Ver código fuente": "Show Source",
        "Aumentar texto": "Increase Text Size",
        "Reducir texto": "Decrease Text Size",
        "Tamaño original": "Actual Size",
        "Actualizar": "Reload",
        "No se pudo leer el archivo": "Unable to Read File",
        "Entendido": "OK",
        "ESPACIO PARA LEER": "A LITTLE SPACE TO READ",
        "Abrir documento": "Open Document",
        "DOCUMENTO": "DOCUMENT",
        "Bienvenido": "Welcome",
        "EN ESTA PÁGINA": "ON THIS PAGE",
        "Los títulos aparecerán aquí.": "Headings will appear here.",
        "RECIENTES": "RECENT",
        "LOCAL. SIMPLE. TUYO.": "LOCAL. SIMPLE. YOURS.",
        "Mostrar barra lateral": "Show Sidebar",
        "Buscar · ⌘F": "Find · ⌘F",
        "Ver código fuente · ⇧⌘S": "Show Source · ⇧⌘S",
        "Apariencia": "Appearance",
        "Sistema": "System",
        "Claro": "Light",
        "Oscuro": "Dark",
        "Tipografía y apariencia": "Reading Preferences",
        "CÓDIGO FUENTE": "SOURCE",
        "MARKDOWN": "MARKDOWN",
        "Idioma": "Language",
        "Color de acento": "Accent Color",
        "palabras": "words",
        "min de lectura": "min read",
        "Verde agua": "Teal",
        "Azul": "Blue",
        "Violeta": "Purple",
        "Rosa": "Pink",
        "Naranja": "Orange",
        "Verde": "Green",
        "No se pudo abrir": "Unable to open",
        "No se pudo actualizar el documento.": "Unable to refresh the document.",
        "Elige un archivo de texto UTF-8 de hasta 5 MB.": "Choose a UTF-8 text file no larger than 5 MB.",
        "Imagen": "Image",
        "abrir imagen": "open image",
    ]
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case system, teal, blue, purple, pink, orange, green
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Sistema"
        case .teal: return "Verde agua"
        case .blue: return "Azul"
        case .purple: return "Violeta"
        case .pink: return "Rosa"
        case .orange: return "Naranja"
        case .green: return "Verde"
        }
    }
    var color: NSColor {
        switch self {
        case .system: return .controlAccentColor
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .orange: return .systemOrange
        case .green: return .systemGreen
        }
    }
}
