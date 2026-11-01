import Foundation

/// Pure text manipulation for the marked PATH block in shell rc files. Mirrors the awk logic in
/// Scripts/install-shell-integration.sh exactly, including dropping the one blank line the installer adds.
public enum RCFileEditor {
    public static let blockBegin = "# >>> aiswitch >>>"
    public static let blockEnd = "# <<< aiswitch <<<"

    public static func blockLines(pathExpr: String) -> [String] {
        [blockBegin,
         "# Added by AI Account Switcher: routes claude/codex through the account-aware wrappers.",
         "# Remove this block (or run Scripts/uninstall-shell-integration.sh) to restore the plain CLIs.",
         "case \":$PATH:\" in *\":\(pathExpr):\"*) ;; *) export PATH=\"\(pathExpr):$PATH\" ;; esac",
         "# Functions win over PATH, so lines added later by other installers (nvm, Claude Code) cannot bypass the wrappers.",
         "claude() { if [ -x \"\(pathExpr)/claude\" ]; then \"\(pathExpr)/claude\" \"$@\"; else command claude \"$@\"; fi; }",
         "codex() { if [ -x \"\(pathExpr)/codex\" ]; then \"\(pathExpr)/codex\" \"$@\"; else command codex \"$@\"; fi; }",
         blockEnd]
    }

    public static func containsBlock(_ content: String) -> Bool {
        content.components(separatedBy: "\n").contains(blockBegin)
    }

    /// Removes the block (and the blank line directly before it). Output always ends with a newline when non-empty.
    public static func removingBlock(_ content: String) -> String {
        guard !content.isEmpty else { return "" }
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // trailing newline artefact
        var out: [String] = []
        var skip = false
        var held = false
        for line in lines {
            if skip {
                if line == blockEnd { skip = false }
                continue
            }
            if line == blockBegin { skip = true; held = false; continue }
            if held { out.append(""); held = false }
            if line.isEmpty { held = true; continue }
            out.append(line)
        }
        if held { out.append("") }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    /// Removes any existing block, then appends a fresh one.
    public static func addingBlock(_ content: String, pathExpr: String) -> String {
        let base = removingBlock(content)
        return base + "\n" + blockLines(pathExpr: pathExpr).joined(separator: "\n") + "\n"
    }
}
