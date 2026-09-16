import Foundation

/// A parsed `<form>`: where it submits and which fields it carries.
struct ParsedForm: Sendable {
    var action: URL?
    /// Fields in document order, matching the insertion order the Kotlin code
    /// preserves when it turns the map into a `FormBody`.
    var fields: [FormField]
}

/// The slice of HTML parsing the login flow needs, standing in for Jsoup.
///
/// Only three things are read from the CAS login page: the form's action, its
/// input fields, and the captcha image. A tolerant tag scanner covers that
/// without pulling in a third-party parser, so the project builds with no
/// package resolution.
enum HtmlFormParser {

    static func firstForm(in html: String, baseURL: URL) -> ParsedForm? {
        let cleaned = stripNoise(html)
        let base = baseHref(in: cleaned, baseURL: baseURL) ?? baseURL

        let formTags = scanTags(in: cleaned, named: "form")
        guard let open = formTags.first(where: { !$0.isClosing }) else { return nil }

        // Body of the form runs to its closing tag, or to the end of the
        // document when the markup is malformed.
        let bodyEnd = formTags
            .first { $0.isClosing && $0.range.lowerBound > open.range.upperBound }?
            .range.lowerBound ?? cleaned.endIndex
        let body = String(cleaned[open.range.upperBound..<bodyEnd])

        var fields: [FormField] = []
        for input in scanTags(in: body, named: "input") where !input.isClosing {
            let name = input.attributes["name"] ?? ""
            let type = (input.attributes["type"] ?? "text").lowercased()
            guard !name.isEmpty, type != "submit", type != "button", type != "image" else { continue }
            fields.append(FormField(name: name, value: input.attributes["value"] ?? ""))
        }

        var action: URL?
        if let raw = open.attributes["action"], !raw.isEmpty,
           let resolved = resolve(raw, against: base) {
            action = resolved
        }

        return ParsedForm(action: action, fields: fields)
    }

    /// URL of the captcha `<img>`, resolved against the document base.
    static func captchaImageURL(in html: String, baseURL: URL) -> URL? {
        let cleaned = stripNoise(html)
        let base = baseHref(in: cleaned, baseURL: baseURL) ?? baseURL

        for image in scanTags(in: cleaned, named: "img") where !image.isClosing {
            guard let src = image.attributes["src"], !src.isEmpty else { continue }
            // The Kotlin selector is `img[src*=captcha]`.
            guard src.lowercased().contains("captcha") else { continue }
            if let resolved = resolve(src, against: base) { return resolved }
        }
        return nil
    }

    /// Resolves a possibly relative URL against the document base.
    static func resolve(_ raw: String, against base: URL) -> URL? {
        let trimmed = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    // MARK: - Tag scanning

    struct Tag {
        var name: String
        var attributes: [String: String]
        var isClosing: Bool
        var range: Range<String.Index>
    }

    static func scanTags(in html: String, named wanted: String) -> [Tag] {
        var result: [Tag] = []
        var cursor = html.startIndex

        while let open = html[cursor...].firstIndex(of: "<") {
            var index = html.index(after: open)
            guard index < html.endIndex else { break }

            // Comments and declarations are not elements, but both must be
            // stepped over rather than treated as the end of the document.
            if html[index] == "!" {
                if html[index...].hasPrefix("!--") {
                    if let end = html[index...].range(of: "-->")?.upperBound {
                        cursor = end
                    } else {
                        cursor = html.endIndex
                    }
                } else if let end = html[index...].firstIndex(of: ">") {
                    // `<!DOCTYPE html>` and friends run to the next `>`.
                    cursor = html.index(after: end)
                } else {
                    cursor = html.endIndex
                }
                continue
            }

            var isClosing = false
            if html[index] == "/" {
                isClosing = true
                index = html.index(after: index)
            }

            var name = ""
            while index < html.endIndex, isNameCharacter(html[index]) {
                name.append(html[index])
                index = html.index(after: index)
            }

            var attributes: [String: String] = [:]

            while index < html.endIndex {
                let iterationStart = index

                // Skip whitespace between attributes.
                while index < html.endIndex, html[index].isWhitespace {
                    index = html.index(after: index)
                }
                guard index < html.endIndex else { break }

                if html[index] == ">" {
                    index = html.index(after: index)
                    break
                }
                if html[index] == "/" {
                    index = html.index(after: index)
                    continue
                }

                // Attribute name.
                var attributeName = ""
                while index < html.endIndex, isAttributeNameCharacter(html[index]) {
                    attributeName.append(html[index])
                    index = html.index(after: index)
                }

                while index < html.endIndex, html[index].isWhitespace {
                    index = html.index(after: index)
                }

                var attributeValue = ""
                if index < html.endIndex, html[index] == "=" {
                    index = html.index(after: index)
                    while index < html.endIndex, html[index].isWhitespace {
                        index = html.index(after: index)
                    }
                    if index < html.endIndex, html[index] == "\"" || html[index] == "'" {
                        let quote = html[index]
                        index = html.index(after: index)
                        while index < html.endIndex, html[index] != quote {
                            attributeValue.append(html[index])
                            index = html.index(after: index)
                        }
                        if index < html.endIndex { index = html.index(after: index) }
                    } else {
                        // Unquoted values run until whitespace or `>`. HTML5
                        // appends `/`, `=`, `<` etc. to the value rather than
                        // terminating, which matters for `action=/cas/login`.
                        while index < html.endIndex,
                              !html[index].isWhitespace,
                              html[index] != ">" {
                            attributeValue.append(html[index])
                            index = html.index(after: index)
                        }
                    }
                }

                if !attributeName.isEmpty, attributes[attributeName.lowercased()] == nil {
                    attributes[attributeName.lowercased()] = decodeEntities(attributeValue)
                }

                // Malformed markup such as `<a<` consumes nothing above; step
                // past the offending character rather than spinning forever.
                if index == iterationStart {
                    index = html.index(after: index)
                }
            }

            let tag = Tag(
                name: name.lowercased(),
                attributes: attributes,
                isClosing: isClosing,
                range: open..<index
            )
            if tag.name == wanted { result.append(tag) }

            cursor = index > open ? index : html.index(after: open)
        }

        return result
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        guard !character.isWhitespace else { return false }
        return character != "=" && character != ">" && character != "/" && character != "<"
    }

    /// First `<base href>` wins, matching how a document base is established.
    private static func baseHref(in html: String, baseURL: URL) -> URL? {
        for tag in scanTags(in: html, named: "base") {
            guard let href = tag.attributes["href"], !href.isEmpty else { continue }
            if let resolved = URL(string: decodeEntities(href), relativeTo: baseURL)?.absoluteURL {
                return resolved
            }
        }
        return nil
    }

    /// Removes comments and the contents of `<script>` / `<style>` so their
    /// bodies cannot be mistaken for markup.
    private static func stripNoise(_ html: String) -> String {
        var output = html
        for (open, close) in [("<!--", "-->"), ("<script", "</script>"), ("<style", "</style>")] {
            output = removeBlocks(output, open: open, close: close)
        }
        return output
    }

    private static func removeBlocks(_ text: String, open: String, close: String) -> String {
        var result = text
        while let start = result.range(of: open, options: .caseInsensitive),
              let end = result.range(of: close, options: .caseInsensitive, range: start.upperBound..<result.endIndex) {
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: "")
        }
        return result
    }

    // MARK: - Entities

    /// Decodes the entity set that appears in attribute values. Numeric forms
    /// are handled too, so `&#38;` and `&amp;` behave alike.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&nbsp;": "\u{00A0}", "&#39;": "'",
        ]

        var output = ""
        output.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let semicolon = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semicolon) <= 10 else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            let entity = String(text[index...semicolon])
            let lowercased = entity.lowercased()

            if let replacement = named[lowercased] {
                output.append(replacement)
            } else if lowercased.hasPrefix("&#") {
                let digits = lowercased.dropFirst(2).dropLast()
                let scalarValue: UInt32?
                if digits.hasPrefix("x") {
                    scalarValue = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(digits)
                }
                if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                    output.append(Character(scalar))
                } else {
                    output.append(entity)
                }
            } else {
                output.append(entity)
            }

            index = text.index(after: semicolon)
        }
        return output
    }
}
