import AppKit

/// Plain-text formats converted by parsing and re-writing: subtitles, delimited tables,
/// Markdown in and out. No external parsers, nothing executed.
enum TextFormats {
    static func readText(_ url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= DocumentEngine.maxBytes else { throw ConversionError.tooLarge("Files over 100 MB are not converted") }
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw ConversionError.unreadable
    }

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }

    // MARK: Subtitles

    private struct Cue {
        var start: String
        var end: String
        var lines: [String]
    }

    /// Parses SRT or WebVTT cues; timestamps are normalised to "HH:MM:SS.mmm".
    private static func cues(in text: String) -> [Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil } // header, NOTE, STYLE
            let parts = lines[timing].components(separatedBy: "-->")
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            let end = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let text = lines[(timing + 1)...].filter { !$0.isEmpty }
            return Cue(start: normalizedTime(start), end: normalizedTime(end), lines: text)
        }
    }

    private static func normalizedTime(_ time: String) -> String {
        let dotted = time.replacingOccurrences(of: ",", with: ".")
        return dotted.split(separator: ":").count == 2 ? "00:" + dotted : dotted
    }

    /// Keeps the tags both formats understand (<b>, <i>, <u>); drops voice/class spans.
    private static func simpleTags(_ line: String) -> String {
        line.replacingOccurrences(of: #"<(?!/?(?:b|i|u)>)[^>]*>"#, with: "", options: .regularExpression)
    }

    private static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    }

    static func convertSubtitles(_ url: URL, to format: OutputFormat, writingTo destination: URL) throws {
        let cues = cues(in: try readText(url))
        guard !cues.isEmpty else { throw ConversionError.failed("No subtitles found in this file") }
        let output: String = switch format {
        case .srt:
            cues.enumerated().map { index, cue in
                "\(index + 1)\n\(cue.start.replacingOccurrences(of: ".", with: ",")) --> \(cue.end.replacingOccurrences(of: ".", with: ","))\n"
                    + cue.lines.map(simpleTags).joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        case .vtt:
            "WEBVTT\n\n" + cues.map { cue in
                "\(cue.start) --> \(cue.end)\n" + cue.lines.map(simpleTags).joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        case .txt:
            cues.map { $0.lines.map(plain).joined(separator: " ") }.joined(separator: "\n") + "\n"
        default:
            throw ConversionError.unsupported
        }
        try write(output, to: destination)
    }

    // MARK: Tables

    /// RFC 4180 parsing: quoted fields may hold the delimiter, quotes ("") and line breaks.
    static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, iterator = Array(text).makeIterator()
        var pending: Character? = nil
        while let char = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if char == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    field.append(char)
                }
            } else if char == "\"" && field.isEmpty {
                quoted = true
            } else if char == delimiter {
                row.append(field)
                field = ""
            } else if char == "\n" || char == "\r\n" || char == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func convertTable(_ url: URL, to format: OutputFormat, writingTo destination: URL) throws {
        let source: Character = OutputFormat.tsv.matches(extension: url.pathExtension) ? "\t" : ","
        let rows = parseDelimited(try readText(url), delimiter: source)
        let output: String = switch format {
        case .csv:
            rows.map { row in
                row.map { field in
                    field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                        ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
                }.joined(separator: ",")
            }.joined(separator: "\r\n") + "\r\n"
        case .tsv:
            // TSV has no quoting: tabs and line breaks inside a field become spaces.
            rows.map { row in
                row.map { $0.replacingOccurrences(of: #"[\t\r\n]+"#, with: " ", options: .regularExpression) }.joined(separator: "\t")
            }.joined(separator: "\n") + "\n"
        default:
            throw ConversionError.unsupported
        }
        try write(output, to: destination)
    }

    // MARK: Markdown

    /// Reads Markdown with Foundation's parser (inline styles, line breaks preserved).
    static func readMarkdown(_ url: URL) throws -> NSAttributedString {
        let parsed = try AttributedString(markdown: readText(url), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let base = NSFont.systemFont(ofSize: 12)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) : base
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// Writes bold, italic and links as Markdown; everything else as plain text.
    static func markdown(from text: NSAttributedString) -> String {
        var output = ""
        let string = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var piece = escape(string.substring(with: range))
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.bold) { piece = wrap(piece, "**") }
            if traits.contains(.italic) { piece = wrap(piece, "*") }
            if let link = (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:)) {
                piece = "[\(piece)](\(link.absoluteString))"
            }
            output += piece
        }
        return output.hasSuffix("\n") ? output : output + "\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: #"([\\`*_\[\]])"#, with: #"\\$1"#, options: .regularExpression)
    }

    /// Markers go around each line's text, outside its surrounding whitespace.
    private static func wrap(_ text: String, _ marker: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return line }
            let lead = line.prefix { $0.isWhitespace }
            let trail = String(line.reversed().prefix { $0.isWhitespace }.reversed())
            return lead + marker + trimmed + marker + trail
        }.joined(separator: "\n")
    }
}
