import AppKit

enum FormatAction: String, CaseIterable {
    case bold, italic, strikethrough, code, link
    case heading1, heading2, heading3, paragraph
    case bulletList, numberedList, taskList, quote
    case codeBlock, table, rule
}

private let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]?)*[ \t]*)(?:([-+*])|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)
private let quotePattern = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]?)+)"#)

extension MDTextView {
    private var text: NSString { textStorage?.mutableString ?? "" }

    /// Replaces text through NSTextView so the change is undoable and notifies the delegate.
    func replace(_ range: NSRange, with string: String, selecting selection: NSRange? = nil) {
        guard NSMaxRange(range) <= text.length, shouldChangeText(in: range, replacementString: string) else { return }
        textStorage?.replaceCharacters(in: range, with: string)
        didChangeText()
        if let selection { setSelectedRange(selection) }
    }

    func perform(_ action: FormatAction) {
        switch action {
        case .bold: toggleWrap("**", placeholder: localize("texto"))
        case .italic: toggleWrap("*", placeholder: localize("texto"))
        case .strikethrough: toggleWrap("~~", placeholder: localize("texto"))
        case .code: toggleWrap("`", placeholder: localize("código"))
        case .link: insertLink()
        case .heading1: setHeading(1)
        case .heading2: setHeading(2)
        case .heading3: setHeading(3)
        case .paragraph: setHeading(0)
        case .bulletList: toggleList { _ in "- " }
        case .numberedList: toggleList { "\($0 + 1). " }
        case .taskList: toggleList { _ in "- [ ] " }
        case .quote: toggleQuote()
        case .codeBlock: insertCodeBlock()
        case .table: insertBlock("| \(localize("Columna")) 1 | \(localize("Columna")) 2 |\n| --- | --- |\n|  |  |\n", caretOffset: 2)
        case .rule: insertBlock("---\n", caretOffset: 4)
        }
    }

    private func toggleWrap(_ marker: String, placeholder: String) {
        let selection = selectedRange()
        let length = (marker as NSString).length
        if selection.location >= length, NSMaxRange(selection) + length <= text.length,
           text.substring(with: NSRange(location: selection.location - length, length: length)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(selection), length: length)) == marker {
            let outer = NSRange(location: selection.location - length, length: selection.length + length * 2)
            replace(outer, with: text.substring(with: selection), selecting: NSRange(location: outer.location, length: selection.length))
            return
        }
        let selected = text.substring(with: selection)
        if selected.count >= marker.count * 2, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            replace(selection, with: inner, selecting: NSRange(location: selection.location, length: (inner as NSString).length))
            return
        }
        if selection.length == 0 {
            replace(selection, with: marker + placeholder + marker,
                    selecting: NSRange(location: selection.location + length, length: (placeholder as NSString).length))
        } else {
            replace(selection, with: marker + selected + marker, selecting: NSRange(location: selection.location + length, length: selection.length))
        }
    }

    private func insertLink() {
        let selection = selectedRange()
        let selected = text.substring(with: selection)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            let label = localize("enlace")
            replace(selection, with: "[\(label)](\(selected))", selecting: NSRange(location: selection.location + 1, length: (label as NSString).length))
        } else {
            let label = selected.isEmpty ? localize("enlace") : selected
            let value = "[\(label)](https://)"
            replace(selection, with: value, selecting: NSRange(location: selection.location + (label as NSString).length + 3, length: 8))
        }
    }

    private var selectedLines: NSRange { text.lineRange(for: selectedRange()) }

    private func transformLines(_ transform: ([String]) -> [String]) {
        let range = selectedLines
        let selection = selectedRange()
        var block = text.substring(with: range)
        let newline = block.hasSuffix("\n")
        if newline { block.removeLast() }
        let lines = block.components(separatedBy: "\n")
        let replacement = transform(lines).joined(separator: "\n") + (newline ? "\n" : "")
        let newLength = (replacement as NSString).length - (newline ? 1 : 0)
        if lines.count == 1, selection.length == 0 {
            let delta = newLength - (range.length - (newline ? 1 : 0))
            let caret = max(range.location, min(range.location + newLength, selection.location + delta))
            replace(range, with: replacement, selecting: NSRange(location: caret, length: 0))
        } else {
            replace(range, with: replacement, selecting: NSRange(location: range.location, length: newLength))
        }
    }

    private func setHeading(_ level: Int) {
        transformLines { lines in
            lines.map { line in
                let stripped = line.replacingOccurrences(of: #"^[ \t]{0,3}#{1,6}[ \t]+"#, with: "", options: .regularExpression)
                let current = line.range(of: #"^[ \t]{0,3}#{1,6}[ \t]"#, options: .regularExpression).map { line[$0].filter { $0 == "#" }.count } ?? 0
                if level == 0 || current == level { return stripped }
                return String(repeating: "#", count: level) + " " + stripped
            }
        }
    }

    private func listPrefix(_ line: String) -> NSTextCheckingResult? {
        listPattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private func toggleList(_ marker: @escaping (Int) -> String) {
        let sample = marker(0)
        transformLines { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let all = !content.isEmpty && content.allSatisfy { line in
                guard let match = listPrefix(line) else { return false }
                let numbered = match.range(at: 3).location != NSNotFound
                let task = match.range(at: 6).location != NSNotFound
                return numbered == (sample.first?.isNumber ?? false) && task == sample.contains("[")
            }
            var index = 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let ns = line as NSString
                var indent = ""
                var body = line
                if let match = listPrefix(line) {
                    indent = ns.substring(with: match.range(at: 1))
                    body = ns.substring(from: NSMaxRange(match.range))
                }
                if all { return indent + body }
                defer { index += 1 }
                return indent + marker(index) + body
            }
        }
    }

    private func toggleQuote() {
        transformLines { lines in
            let all = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix(">") }
            return lines.map { line in
                if all { return line.replacingOccurrences(of: #"^>[ ]?"#, with: "", options: .regularExpression) }
                return "> " + line
            }
        }
    }

    private func insertCodeBlock() {
        let selection = selectedRange()
        if selection.length > 0 {
            let range = selectedLines
            var block = text.substring(with: range)
            if !block.hasSuffix("\n") { block += "\n" }
            replace(range, with: "```\n" + block + "```\n", selecting: NSRange(location: range.location + 3, length: 0))
        } else {
            insertBlock("```\n\n```\n", caretOffset: 3)
        }
    }

    /// Inserts a block on its own line and places the caret `caretOffset` characters into it.
    private func insertBlock(_ block: String, caretOffset: Int) {
        let selection = selectedRange()
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineText = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        if lineText.isEmpty {
            let target = NSRange(location: line.location, length: max(0, line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0)))
            replace(target, with: block.hasSuffix("\n") && NSMaxRange(line) < text.length ? String(block.dropLast()) : block,
                    selecting: NSRange(location: line.location + caretOffset, length: 0))
        } else {
            let end = NSMaxRange(line)
            let needsNewline = end == text.length && !text.substring(with: line).hasSuffix("\n")
            let insertion = (needsNewline ? "\n" : "") + "\n" + block
            replace(NSRange(location: end, length: 0), with: insertion,
                    selecting: NSRange(location: end + (insertion as NSString).length - (block as NSString).length + caretOffset, length: 0))
        }
    }

    /// Continues lists and quotes on Return. Returns false when the default newline should run.
    func continueBlockOnNewline() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        var content = text.substring(with: line)
        if content.hasSuffix("\n") { content.removeLast() }
        let ns = content as NSString
        let caret = selection.location - line.location
        if let match = listPrefix(content) {
            guard caret >= match.range.length else { return false }
            let body = ns.substring(from: match.range.length).trimmingCharacters(in: .whitespaces)
            if body.isEmpty {
                replace(NSRange(location: line.location, length: ns.length), with: "", selecting: NSRange(location: line.location, length: 0))
                return true
            }
            let indent = ns.substring(with: match.range(at: 1))
            var marker: String
            if match.range(at: 2).location != NSNotFound {
                marker = ns.substring(with: match.range(at: 2))
            } else {
                let number = Int(ns.substring(with: match.range(at: 3))) ?? 1
                marker = "\(number + 1)" + ns.substring(with: match.range(at: 4))
            }
            marker += ns.substring(with: match.range(at: 5))
            if match.range(at: 6).location != NSNotFound { marker += "[ ] " }
            let insertion = "\n" + indent + marker
            replace(selection, with: insertion, selecting: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
            return true
        }
        if let match = quotePattern.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)), caret >= match.range.length {
            if ns.substring(from: match.range.length).trimmingCharacters(in: .whitespaces).isEmpty {
                replace(NSRange(location: line.location, length: ns.length), with: "", selecting: NSRange(location: line.location, length: 0))
                return true
            }
            var prefix = ns.substring(with: match.range)
            if !prefix.hasSuffix(" ") { prefix += " " }
            replace(selection, with: "\n" + prefix, selecting: NSRange(location: selection.location + 1 + (prefix as NSString).length, length: 0))
            return true
        }
        return false
    }

    /// Indents or outdents list items with Tab / Shift-Tab. Returns false outside lists.
    func shiftListItems(outdent: Bool) -> Bool {
        let range = selectedLines
        let block = text.substring(with: range)
        let lines = block.components(separatedBy: "\n")
        guard let first = lines.first, let match = listPrefix(first) else { return false }
        let ns = first as NSString
        let width = max(2, ns.substring(with: NSRange(location: match.range(at: 1).length,
                                                     length: match.range.length - match.range(at: 1).length - (match.range(at: 6).location == NSNotFound ? 0 : match.range(at: 6).length))).count)
        let pad = String(repeating: " ", count: width)
        let selection = selectedRange()
        let shifted = lines.enumerated().map { index, line -> String in
            if line.isEmpty && index == lines.count - 1 { return line }
            if outdent {
                var result = Substring(line)
                var removed = 0
                while removed < width, result.first == " " { result.removeFirst(); removed += 1 }
                if removed == 0, result.first == "\t" { result.removeFirst() }
                return String(result)
            }
            return pad + line
        }.joined(separator: "\n")
        let delta = (shifted as NSString).length - range.length
        replace(range, with: shifted, selecting: lines.count <= 2 && selection.length == 0
                ? NSRange(location: max(range.location, selection.location + (outdent ? max(delta, -width) : width)), length: 0)
                : NSRange(location: range.location, length: (shifted as NSString).length))
        return true
    }
}
