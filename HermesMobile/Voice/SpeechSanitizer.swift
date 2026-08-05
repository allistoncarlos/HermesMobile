import Foundation

// ============================================================================
//  SpeechSanitizer — espelha `apps/desktop/src/lib/speech-text.ts` do Hermes
//  (texto limpo antes do POST /api/audio/speak).
// ============================================================================

enum SpeechSanitizer {

    static func sanitize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Blocos de código
        s = s.replacingOccurrences(of: #"```[\s\S]*?(?:```|$)"#, with: " code block omitted ", options: .regularExpression)
        // Prefixo "Thinking..."
        s = s.replacingOccurrences(
            of: #"^\s*(?:\([^)\n]{1,48}\)\s*)?(?:processing|thinking|reasoning|analyzing|pondering|contemplating|musing|cogitating|ruminating|deliberating|mulling|reflecting|computing|synthesizing|formulating|brainstorming)\.\.\.\s*"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        // Links markdown
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1", options: .regularExpression)
        // Inline code
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // URLs
        s = s.replacingOccurrences(of: #"\bhttps?://\S+"#, with: " link ", options: .regularExpression)
        // Headers / listas (linha a linha)
        s = s
            .components(separatedBy: .newlines)
            .map { line -> String in
                var l = line
                if let r = try? NSRegularExpression(pattern: #"^#{1,6}\s+"#) {
                    l = r.stringByReplacingMatches(in: l, range: NSRange(l.startIndex..., in: l), withTemplate: "")
                }
                if let r = try? NSRegularExpression(pattern: #"^\s*[-+*]\s+"#) {
                    l = r.stringByReplacingMatches(in: l, range: NSRange(l.startIndex..., in: l), withTemplate: "")
                }
                return l
            }
            .joined(separator: "\n")

        // Quebras de parágrafo → ponto; soft break → espaço
        s = s.replacingOccurrences(of: #"[ \t]*\n{2,}[ \t]*"#, with: ". ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: " ", options: .regularExpression)
        // Marcadores markdown restantes
        s = s.replacingOccurrences(of: #"[*_~>#]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "⚠️", with: "")
        s = s.replacingOccurrences(of: "❓", with: "")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
