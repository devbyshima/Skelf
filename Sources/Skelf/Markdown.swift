// Fonts, SKILL.md frontmatter parsing, GitHub-style markdown rendering, and the sidebar meta card.

import AppKit
import SwiftUI
import Observation
import QuartzCore
import CoreServices
import ServiceManagement
import Carbon.HIToolbox

func skelfFont(_ style: NSFont.TextStyle, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
}
func skelfMono(_ style: NSFont.TextStyle, _ weight: NSFont.Weight = .medium) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: weight)
}

// An opaque bento card: subtle fill + hairline border + concentric corner (content
// surface — deliberately NOT Liquid Glass, which is reserved for the primary action).
final class MetaCardView: NSView {
    private let keyLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init(key: String, value: String, mono: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        keyLabel.stringValue = key.uppercased()
        keyLabel.font = skelfFont(.caption2, .semibold)
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.lineBreakMode = .byTruncatingTail
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.stringValue = value
        valueLabel.font = mono ? skelfMono(.callout, .regular) : skelfFont(.body)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = mono ? .byTruncatingMiddle : .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [keyLabel, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        keyLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

// MARK: - Detail screen

// Split a SKILL.md into its YAML-ish frontmatter rows and the markdown body.
func splitFrontmatter(_ text: String) -> (rows: [(String, String)], body: String) {
    let lines = text.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([], text) }
    var i = 1
    var rows: [(String, String)] = []
    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
        let line = lines[i]
        if !line.hasPrefix(" "), !line.hasPrefix("\t"), let c = line.firstIndex(of: ":") {
            let k = String(line[..<c]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            if v == "|" || v == ">" { v = "" }
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            rows.append((k, v))
        }
        i += 1
    }
    let body = i + 1 < lines.count ? lines[(i + 1)...].joined(separator: "\n") : ""
    return (rows, body)
}

// --- a small GitHub-flavoured markdown → NSAttributedString renderer (inline:
// bold/italic/code/links; block: headings, lists, code fences, blockquotes) ---

private func mdBold(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
private func mdItalic(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }

private func mdInline(_ s: String, base: NSFont, color: NSColor) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let chars = Array(s)
    var i = 0
    func emit(_ str: String, _ font: NSFont, _ col: NSColor, link: String? = nil, code: Bool = false) {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: col]
        if let link = link, let u = URL(string: link) {
            a[.link] = u; a[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if code { a[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.16) }
        out.append(NSAttributedString(string: str, attributes: a))
    }
    while i < chars.count {
        let c = chars[i]
        if c == "`" {
            var j = i + 1, buf = ""
            while j < chars.count, chars[j] != "`" { buf.append(chars[j]); j += 1 }
            if j < chars.count {
                emit(buf, .monospacedSystemFont(ofSize: base.pointSize - 0.5, weight: .regular), color, code: true)
                i = j + 1; continue
            }
        }
        if c == "*" || c == "_" {
            let isDouble = (i + 1 < chars.count && chars[i + 1] == c)
            let marker = isDouble ? String([c, c]) : String(c)
            let rest = String(chars[(i + marker.count)...])
            if let r = rest.range(of: marker) {
                let inner = String(rest[..<r.lowerBound])
                if !inner.isEmpty {
                    emit(inner, isDouble ? mdBold(base) : mdItalic(base), color)
                    i += marker.count + inner.count + marker.count; continue
                }
            }
        }
        if c == "[" {
            let rest = String(chars[i...])
            if let m = rest.range(of: #"^\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#, options: .regularExpression) {
                let matched = String(rest[m])
                if let tr = matched.range(of: #"\[([^\]]+)\]"#, options: .regularExpression),
                   let ur = matched.range(of: #"\(([^)\s]+)"#, options: .regularExpression) {
                    let text = matched[tr].dropFirst().dropLast()
                    let url = matched[ur].dropFirst()
                    emit(String(text), base, .linkColor, link: String(url))
                    i += matched.count; continue
                }
            }
        }
        emit(String(c), base, color)
        i += 1
    }
    return out
}

func renderGitHubMarkdown(_ md: String) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let body = NSColor.labelColor
    let size: CGFloat = 13.5
    func para(_ spacing: CGFloat, before: CGFloat = 0, lead: CGFloat = 0, ls: CGFloat = 4) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing; p.paragraphSpacingBefore = before
        p.firstLineHeadIndent = lead; p.headIndent = lead; p.lineSpacing = ls
        return p
    }
    func line(_ attr: NSAttributedString, _ style: NSParagraphStyle) {
        let m = NSMutableAttributedString(attributedString: attr)
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        out.append(m); out.append(NSAttributedString(string: "\n"))
    }
    let lines = md.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("```") {
            var code = ""; i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code += lines[i] + "\n"; i += 1 }
            i += 1
            let m = NSMutableAttributedString(string: code.hasSuffix("\n") ? String(code.dropLast()) : code,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                             .foregroundColor: NSColor.labelColor,
                             .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.10),
                             .paragraphStyle: para(10, before: 6, lead: 12)])
            out.append(m); out.append(NSAttributedString(string: "\n")); continue
        }
        if t.isEmpty { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 5)])); i += 1; continue }
        if t == "---" || t == "***" || t == "___" {
            line(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]), para(8, before: 6)); i += 1; continue
        }
        if t.hasPrefix("#### ") { line(mdInline(String(t.dropFirst(5)), base: .systemFont(ofSize: 13.5, weight: .semibold), color: body), para(6, before: 12)); i += 1; continue }
        if t.hasPrefix("### ")  { line(mdInline(String(t.dropFirst(4)), base: .systemFont(ofSize: 15, weight: .semibold), color: body), para(6, before: 14)); i += 1; continue }
        if t.hasPrefix("## ")   { line(mdInline(String(t.dropFirst(3)), base: .systemFont(ofSize: 18, weight: .bold), color: body), para(8, before: 18)); i += 1; continue }
        if t.hasPrefix("# ")    { line(mdInline(String(t.dropFirst(2)), base: .systemFont(ofSize: 22, weight: .bold), color: body), para(8, before: 18)); i += 1; continue }
        if t.hasPrefix("> ") || t == ">" {
            line(mdInline(String(t.dropFirst(t.hasPrefix("> ") ? 2 : 1)), base: .systemFont(ofSize: size), color: .secondaryLabelColor), para(6, lead: 14)); i += 1; continue
        }
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            let row = NSMutableAttributedString(string: "•  ", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor])
            row.append(mdInline(String(t.dropFirst(2)), base: .systemFont(ofSize: size), color: body))
            line(row, para(4, lead: 16)); i += 1; continue
        }
        if let m = t.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            let row = NSMutableAttributedString(string: String(t[m]), attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            row.append(mdInline(String(t[m.upperBound...]), base: .systemFont(ofSize: size), color: body))
            line(row, para(4, lead: 18)); i += 1; continue
        }
        line(mdInline(t, base: .systemFont(ofSize: size), color: body), para(9, ls: 4.5)); i += 1
    }
    return out
}

// MARK: - Detail screen (two-column: GitHub-style SKILL.md + sticky sidebar, avatar header)

