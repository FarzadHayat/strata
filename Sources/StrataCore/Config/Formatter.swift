/// Line structure of a `defsrc` form, used to lay out layers as an aligned grid.
public struct GridLayout: Sendable, Equatable {
    /// Positions (indices into `defsrc`) on each line, in order.
    public var rows: [[Int]]
    /// Whether the first row shares the line with `(defsrc` / `(deflayer name`.
    public var firstRowInline: Bool
    /// Whether the closing `)` sits on its own line.
    public var closeOnOwnLine: Bool
    /// Indentation of continuation rows.
    public var indent: String

    public init(rows: [[Int]], firstRowInline: Bool = false, closeOnOwnLine: Bool = true, indent: String = "  ") {
        self.rows = rows
        self.firstRowInline = firstRowInline
        self.closeOnOwnLine = closeOnOwnLine
        self.indent = indent
    }
}

/// Text generation: grid-aligned `deflayer` forms and the starter config.
public enum Formatter {
    /// Display width of a token (unicode scalars).
    public static func width(_ token: String) -> Int { token.unicodeScalars.count }

    static func pad(_ token: String, to width: Int) -> String {
        let w = Formatter.width(token)
        return w >= width ? token : token + String(repeating: " ", count: width - w)
    }

    static func containsComment(_ trivia: String) -> Bool {
        trivia.contains(";;") || trivia.contains("#|")
    }

    /// Renders `(deflayer name …)` with `tokens` laid out per `layout`, each column padded to `widths[p]`.
    /// Tokens whose position appears in `preservedTrivia` are preceded by that trivia verbatim (used to keep
    /// comments when realigning). Tokens beyond the layout's positions go on a final extra row.
    public static func layerForm(name: String, tokens: [String], layout: GridLayout, widths: [Int],
                                 preservedTrivia: [Int: String] = [:], closeTrivia: String? = nil) -> String {
        var rows = layout.rows.map { $0.filter { $0 < tokens.count } }
        let covered = Set(rows.joined())
        let extra = tokens.indices.filter { !covered.contains($0) }
        if !extra.isEmpty { rows.append(extra) }
        rows.removeAll { $0.isEmpty }

        var out = "(deflayer \(name)"
        for (i, row) in rows.enumerated() {
            let inline = i == 0 && layout.firstRowInline
            for (j, p) in row.enumerated() {
                let isLast = j == row.count - 1
                let token = isLast ? tokens[p] : pad(tokens[p], to: p < widths.count ? widths[p] : 0)
                if let trivia = preservedTrivia[p] {
                    // Keep the comment; re-indent the token if the comment ended its line.
                    if j == 0, let nl = trivia.lastIndex(of: "\n") {
                        out += trivia[...nl] + layout.indent + token
                    } else {
                        out += trivia + token
                    }
                } else if j == 0 {
                    out += (inline ? " " : "\n" + layout.indent) + token
                } else {
                    out += " " + token
                }
            }
        }
        if let closeTrivia {
            out += closeTrivia
        } else if layout.closeOnOwnLine {
            out += "\n"
        }
        return out + ")"
    }

    /// Column widths for a grid: the widest token at each position across all rows given.
    public static func columnWidths(_ rows: [[String]]) -> [Int] {
        var widths: [Int] = []
        for row in rows {
            for (p, token) in row.enumerated() {
                if p >= widths.count { widths.append(0) }
                widths[p] = max(widths[p], width(token))
            }
        }
        return widths
    }

    /// Breaks a flat key list into keyboard rows at the usual row-leading keys.
    public static func defaultLayout(for keys: [String]) -> GridLayout {
        let rowStarters: Set<String> = ["esc", "grv", "`", "tab", "caps", "lsft", "fn", "lctl"]
        var rows: [[Int]] = []
        for (i, key) in keys.enumerated() {
            let name = key.lowercased()
            // `lctl` starts the bottom row unless `fn` already did.
            let starts = rowStarters.contains(name) && !(name == "lctl" && i > 0 && keys[i - 1].lowercased() == "fn")
            if rows.isEmpty || (starts && i > 0) { rows.append([]) }
            rows[rows.count - 1].append(i)
        }
        return GridLayout(rows: rows)
    }

    /// The commented starter file: QWERTY base (caps → tap esc / hold `extend`) plus an `extend`
    /// navigation layer. `sourceKeys` are the physical keys to list in `defsrc`.
    public static func defaultConfig(sourceKeys: [String]) -> String {
        let extendMap: [String: String] = [
            "i": "up", "j": "left", "k": "down", "l": "right", "u": "home", "o": "end",
            "y": "pgup", "n": "pgdn", "h": "bspc", "m": "del", "p": "ins",
            "a": "lalt", "s": "lmet", "d": "lsft", "f": "lctl", "g": "rctl",
            "z": "@udo", "x": "@cut", "c": "@cpy", "v": "@pst", "q": "esc",
            "spc": "ret", ";": "menu", "caps": "caps",
        ]
        let base = sourceKeys.map { $0.lowercased() == "caps" ? "@ext" : $0 }
        let extend = sourceKeys.map { extendMap[$0.lowercased()] ?? "_" }
        let layout = defaultLayout(for: sourceKeys)
        let widths = columnWidths([sourceKeys, base, extend])

        var out = """
        ;; Strata keymap — https://github.com/FarzadHayat/strata
        ;;
        ;; Forms: (defcfg …) settings, (defsrc …) physical keys, (defalias …) named actions,
        ;; (deflayer name …) one action per defsrc key. The first deflayer is the base layer.
        ;; Actions: key names (a, spc, brup, …), _ transparent (hardware default), XX block,
        ;; @alias, chords M-c C-S-tab (M command, C control, A option, S shift),
        ;; (layer-while-held L), (layer-switch L), (tap-hold [tap-ms hold-ms] tap hold), (macro a b …).

        (defcfg
          tap-hold-resolution permissive   ;; permissive | hold-on-press | timeout
          tap-timeout 200
          hold-timeout 200
          prior-idle 120
          fn-row system                    ;; system | media | function
        )


        """
        out += layerForm(name: "src", tokens: sourceKeys, layout: layout, widths: widths)
            .replacingOccurrences(of: "(deflayer src", with: "(defsrc")
        out += """


        (defalias
          ext (tap-hold esc (layer-while-held extend))   ;; tap: esc, hold: extend layer
          cpy M-c
          pst M-v
          cut M-x
          udo M-z
        )


        """
        out += layerForm(name: "base", tokens: base, layout: layout, widths: widths)
        out += "\n\n"
        out += layerForm(name: "extend", tokens: extend, layout: layout, widths: widths)
        out += "\n"
        return out
    }
}
