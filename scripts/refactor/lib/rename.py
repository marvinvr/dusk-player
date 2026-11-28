#!/usr/bin/env python3
"""Word-boundary identifier renames for the Phase 0 sweeps (docs/jellyfin/05-plan.md).

  rename.py TABLE [--text] [--check] FILE...

TABLE has one `Old New` pair per line (`#` comments allowed). Every whole-word
occurrence of Old becomes New in a single pass, so a pair never feeds another.

Swift files are lexed: code and comments are rewritten, string literal text is
not (logger categories, persisted keys, analytics values and wire strings stay
byte-identical). Code inside string interpolation is rewritten. `--text`
rewrites every occurrence (Markdown docs).

Prints `<count> <file>` for each changed file. `--check` writes nothing and
exits 1 when any Old name is still present (outside string literals).
"""
import re
import sys
from pathlib import Path


def load_table(path):
    pairs = {}
    for line in Path(path).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        old, new = line.split()
        if old in pairs:
            sys.exit(f"duplicate entry {old} in {path}")
        pairs[old] = new
    return pairs


class SwiftRewriter:
    def __init__(self, pairs):
        self.pairs = pairs
        words = sorted(pairs, key=len, reverse=True)
        self.pattern = re.compile(r"(?<![A-Za-z0-9_])(" + "|".join(map(re.escape, words)) + r")(?![A-Za-z0-9_])")
        self.count = 0

    def sub(self, text):
        def repl(match):
            self.count += 1
            return self.pairs[match.group(1)]
        return self.pattern.sub(repl, text)

    def rewrite(self, src):
        out, i = self.code(src, 0, nested=False)
        assert i == len(src)
        return "".join(out)

    def code(self, s, i, nested):
        """Lex code from i. When nested (inside `\\(`), stop after the closing paren."""
        out, start, depth, n = [], i, 0, len(s)

        def flush(upto):
            out.append(self.sub(s[start:upto]))

        while i < n:
            c = s[i]
            if c == "/" and s.startswith("//", i):
                flush(i)
                end = s.find("\n", i)
                end = n if end < 0 else end
                out.append(self.sub(s[i:end]))
                i = start = end
                continue
            if c == "/" and s.startswith("/*", i):
                flush(i)
                end, level = i + 2, 1
                while end < n and level:
                    if s.startswith("/*", end):
                        level, end = level + 1, end + 2
                    elif s.startswith("*/", end):
                        level, end = level - 1, end + 2
                    else:
                        end += 1
                out.append(self.sub(s[i:end]))
                i = start = end
                continue
            if c == "/" and self.regex_start(s, i):
                flush(i)
                end = i + 1
                while end < n and s[end] != "/":
                    if s[end] == "\n":
                        raise ValueError(f"unterminated regex literal at offset {i}")
                    end += 2 if s[end] == "\\" else 1
                out.append(s[i:end + 1])
                i = start = end + 1
                continue
            if c == '"' or (c == "#" and re.match(r"#+\"", s[i:])):
                flush(i)
                i = self.string(s, i, out)
                start = i
                continue
            if nested:
                if c == "(":
                    depth += 1
                elif c == ")":
                    if depth == 0:
                        flush(i + 1)
                        return out, i + 1
                    depth -= 1
            i += 1
        flush(n)
        if nested:
            raise ValueError("unterminated string interpolation")
        return out, n

    @staticmethod
    def regex_start(s, i):
        """A bare `/regex/` literal: `/` in expression-start position, not followed by space."""
        if i + 1 >= len(s) or s[i + 1] in " \t\n/*=":
            return False
        before = s[:i].rstrip(" \t")
        return bool(before) and (before[-1] in "(,:=[{" or re.search(r"\b(return|in)$", before) is not None)

    def string(self, s, i, out):
        """Copy a string literal starting at i verbatim, recursing into interpolations."""
        hashes = len(re.match(r"#*", s[i:]).group(0))
        j = i + hashes
        multiline = s.startswith('"""', j)
        quote = '"""' if multiline else '"'
        j += len(quote)
        close = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        lit_start = i
        n = len(s)
        while j < n:
            if s.startswith(escape, j):
                k = j + len(escape)
                if k < n and s[k] == "(":
                    out.append(s[lit_start:k + 1])
                    inner, j = self.code(s, k + 1, nested=True)
                    out.extend(inner)
                    lit_start = j
                    continue
                j = k + 1
                continue
            if s.startswith(close, j):
                j += len(close)
                out.append(s[lit_start:j])
                return j
            if not multiline and s[j] == "\n":
                raise ValueError(f"unterminated string literal at offset {i}")
            j += 1
        raise ValueError(f"unterminated string literal at offset {i}")


def main():
    args = sys.argv[1:]
    text_mode = "--text" in args
    check = "--check" in args
    args = [a for a in args if a not in ("--text", "--check")]
    found = 0
    if len(args) < 1:
        sys.exit(__doc__)
    pairs = load_table(args[0])
    for name in args[1:]:
        path = Path(name)
        src = path.read_text()
        rewriter = SwiftRewriter(pairs)
        try:
            result = rewriter.sub(src) if text_mode else rewriter.rewrite(src)
        except ValueError as error:
            sys.exit(f"{path}: {error}")
        if result != src:
            found += rewriter.count
            if not check:
                path.write_text(result)
            print(f"{rewriter.count} {path}")
    if check and found:
        sys.exit(f"{found} occurrence(s) of old names left")


if __name__ == "__main__":
    main()
