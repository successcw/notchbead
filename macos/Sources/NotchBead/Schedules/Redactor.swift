// Adapted from onit (MIT, Copyright (c) 2026 Neethan Wu).
import Foundation

/// Masks keys, tokens and passwords in text that's about to leave NotchBead, such as a log handed to
/// a coding agent. It errs on the side of masking: a hidden harmless string costs nothing.
enum Redactor {
    static let mask = "[redacted]"

    private static let rules: [(NSRegularExpression, String)] = {
        func rule(_ pattern: String, _ template: String = mask, options: NSRegularExpression.Options = []) -> (NSRegularExpression, String) {
            (try! NSRegularExpression(pattern: pattern, options: options), template)
        }
        return [
            // PEM blocks, including a truncated one at the end of a log tail.
            rule(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#),
            // Well-known token shapes.
            rule(#"\bsk-[A-Za-z0-9_\-]{16,}"#),
            rule(#"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#),
            rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
            rule(#"\bglpat-[A-Za-z0-9_\-]{16,}"#),
            rule(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
            rule(#"\bxox[abprsoe]-[A-Za-z0-9\-]{10,}"#),
            rule(#"\bAIza[0-9A-Za-z_\-]{30,}"#),
            rule(#"\b(npm|hf|pypi|dop_v1|shpat|sq0atp|rk_live|sk_live|pk_live)_[A-Za-z0-9_\-]{16,}"#),
            rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
            // "Authorization: Bearer abc", "Basic abc".
            rule(#"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=\-]{8,}"#, "$1 \(mask)"),
            // Passwords in URLs: scheme://user:secret@host
            rule(#"([A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]+:)[^\s@/]+@"#, "$1\(mask)@"),
            // key=value, key: value, "key": "value", --key value, for names that sound secret.
            rule(#"(?i)(["']?[A-Za-z0-9_.\-]*(?:api[_\-]?key|apikey|secret|token|passw(?:or)?d|passwd|pwd|credential|private[_\-]?key|access[_\-]?key|auth|session|cookie|signature)[A-Za-z0-9_.\-]*["']?\s*(?:=|:|=>)\s*)(["']?)[^\s"',;}]+"#, "$1$2\(mask)"),
            rule(#"(?i)(--?[A-Za-z0-9\-]*(?:api-?key|secret|token|password|passwd|auth)[A-Za-z0-9\-]*[ =])(["']?)[^\s"']+"#, "$1$2\(mask)"),
        ]
    }()

    static func redact(_ text: String) -> String {
        var result = text
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
