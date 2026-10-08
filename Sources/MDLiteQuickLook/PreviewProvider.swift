import Foundation
import Markdown
import QuickLookUI
import UniformTypeIdentifiers

/// Space bar in Finder: Markdown as a readable page. Text only, nothing loaded from the network;
/// diagrams and formulas show as their source, the app draws them.
@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let text = size <= 5_000_000 ? ((try? String(contentsOf: url, encoding: .utf8)) ?? "") : ""
        var images = LocalImages(folder: url.deletingLastPathComponent())
        let document = images.visit(Document(parsing: Self.dropFrontMatter(text))) as? Document ?? Document()
        let body = HTMLFormatter.format(document)
        let title = url.deletingPathExtension().lastPathComponent
        let page = Self.page(title: title, body: body)
        let attachments = images.attachments
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 1000)) { reply in
            reply.stringEncoding = .utf8
            reply.title = title
            reply.attachments = attachments
            return Data(page.utf8)
        }
    }

    static func dropFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return text
        }
        return String(text[end.upperBound...])
    }

    static func page(title: String, body: String) -> String {
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src cid: data: https:; style-src 'unsafe-inline'">
        <title>\(escaped)</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; font: 15px/1.6 -apple-system, system-ui, sans-serif; color: #1f2328; background: #fbfaf7; }
        article { max-width: 760px; margin: 0 auto; padding: 32px 36px 60px; }
        h1, h2 { border-bottom: 1px solid rgba(0,0,0,.1); padding-bottom: .3em; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 .6em; }
        a { color: #0a84ff; text-decoration: none; }
        img { max-width: 100%; }
        code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: .86em; }
        :not(pre) > code { background: rgba(0,0,0,.055); border-radius: 5px; padding: .12em .36em; }
        pre { background: rgba(0,0,0,.035); border: 1px solid rgba(0,0,0,.06); border-radius: 10px; padding: 12px 14px; overflow-x: auto; }
        blockquote { margin: 0 0 1em; padding: .1em 1em; border-left: 3px solid rgba(0,0,0,.15); color: #5f6670; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid rgba(0,0,0,.12); padding: .4em .75em; }
        th { background: rgba(0,0,0,.04); }
        hr { border: 0; border-top: 1px solid rgba(0,0,0,.12); margin: 1.6em 0; }
        @media (prefers-color-scheme: dark) {
          body { color: #e6e8eb; background: #16181c; }
          h1, h2 { border-color: rgba(255,255,255,.12); }
          :not(pre) > code { background: rgba(255,255,255,.1); }
          pre { background: rgba(255,255,255,.05); border-color: rgba(255,255,255,.07); }
          th, td { border-color: rgba(255,255,255,.12); }
          th { background: rgba(255,255,255,.05); }
          blockquote { color: #a2a8b1; border-color: rgba(255,255,255,.2); }
        }
        </style></head><body><article>
        \(body)
        </article></body></html>
        """
    }
}

/// Images next to the document travel with the preview as attachments (`cid:` links);
/// one that cannot be read becomes its description, never a broken picture.
struct LocalImages: MarkupRewriter {
    let folder: URL
    var attachments: [String: QLPreviewReplyAttachment] = [:]
    private var total = 0

    init(folder: URL) { self.folder = folder }

    mutating func visitImage(_ image: Image) -> Markup? {
        guard let source = image.source, !source.isEmpty, Self.isLocal(source) else { return image }
        if let name = attach(source) {
            var copy = image
            copy.source = "cid:" + name
            return copy
        }
        let alt = image.plainText.isEmpty ? URL(fileURLWithPath: source).lastPathComponent : image.plainText
        return Emphasis(Text(alt))
    }

    // READMEs often place the logo with raw HTML: `<img src="docs/logo.svg">`.
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> Markup? {
        HTMLBlock(rewritingSources(in: html.rawHTML))
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> Markup? {
        InlineHTML(rewritingSources(in: html.rawHTML))
    }

    private mutating func rewritingSources(in html: String) -> String {
        guard html.range(of: "src", options: .caseInsensitive) != nil,
              let pattern = try? NSRegularExpression(pattern: #"(\bsrcset|\bsrc)\s*=\s*"([^"]*)""#, options: .caseInsensitive) else { return html }
        var result = html
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let whole = Range(match.range, in: html), let value = Range(match.range(at: 2), in: html),
                  let attribute = Range(match.range(at: 1), in: html) else { continue }
            let source = String(html[value]).components(separatedBy: " ")[0]
            guard Self.isLocal(source) else { continue }
            let replacement = attach(source).map { "cid:" + $0 } ?? ""
            result.replaceSubrange(whole, with: "\(html[attribute])=\"\(replacement)\"")
        }
        return result
    }

    private static func isLocal(_ source: String) -> Bool {
        !(source.hasPrefix("http:") || source.hasPrefix("https:") || source.hasPrefix("data:") || source.hasPrefix("cid:"))
    }

    /// The attachment name for an image file next to the document, or nil when it cannot be read.
    private mutating func attach(_ source: String) -> String? {
        let path = (source.removingPercentEncoding ?? source).components(separatedBy: "#")[0]
        let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: file), total + data.count <= 20_000_000 else { return nil }
        let name = "image\(attachments.count)"
        attachments[name] = QLPreviewReplyAttachment(data: data, contentType: type)
        total += data.count
        return name
    }
}
