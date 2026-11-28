#!/usr/bin/env python3
"""P0-04: rewrite `imageURL(for: path, serverID: s, width: w, height: h)` calls.

  artwork_calls.py FILE...

Every call of PlexService's path-based `imageURL` becomes
`imageURL(for: ArtworkRef(serverID: s, path: path), size: ImageSize(width: w, height: h))`.
The server stays the one the call site passed (a model decoded from the
offline cache has no server stamp of its own), so every URL is unchanged.
Only receivers that are a PlexService are touched: `plexService.`, `service.`
and bare calls inside `PlexService/` files. A call whose arguments do not
parse is an error. Prints `<count> <file>`.
"""
import re
import sys
from pathlib import Path

RECEIVER = re.compile(r"(?:(?<![A-Za-z0-9_])(?:plexService|service)\.|(?<![A-Za-z0-9_.]))imageURL\(")


def split_args(text):
    args, depth, start, i, n = [], 0, 0, 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            args.append(text[start:i])
            start = i + 1
        i += 1
    args.append(text[start:])
    return args


def rewrite(src, bare_allowed):
    out, pos, count = [], 0, 0
    for m in RECEIVER.finditer(src):
        if m.start() < pos:
            continue
        bare = not src[m.start():m.end()].startswith(("plexService.", "service."))
        if bare and not bare_allowed:
            continue
        line_start = src.rfind("\n", 0, m.start()) + 1
        if re.match(r"\s*(?:///|//)", src[line_start:m.start()]) or "func imageURL" in src[line_start:m.end()]:
            continue
        i, depth = m.end(), 1
        while depth:
            if src[i] == '"':
                i += 1
                while src[i] != '"':
                    i += 2 if src[i] == "\\" else 1
            elif src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
            i += 1
        inner = src[m.end():i - 1]
        args = split_args(inner)
        labelled = {}
        for arg in args:
            label, sep, value = arg.partition(":")
            if not sep or label.strip() not in ("for", "serverID", "width", "height"):
                raise SystemExit(f"cannot rewrite call: imageURL({inner})")
            labelled[label.strip()] = value.strip()
        if "for" not in labelled:
            raise SystemExit(f"no path in: imageURL({inner})")
        multiline = "\n" in inner
        indent = ""
        if multiline:
            indent = re.match(r"\s*", args[0]).group(0).lstrip("\n").replace("\n", "")
            indent = args[0][: len(args[0]) - len(args[0].lstrip())].split("\n")[-1]
        ref = f"ArtworkRef(serverID: {labelled.get('serverID', 'nil')}, path: {labelled['for']})"
        size_parts = [f"{k}: {labelled[k]}" for k in ("width", "height") if k in labelled]
        size = f"ImageSize({', '.join(size_parts)})" if size_parts else "ImageSize.original"
        if multiline:
            closing = inner[len(inner.rstrip()):]
            body = f"\n{indent}for: {ref},\n{indent}size: {size}{closing}"
        else:
            body = f"for: {ref}, size: {size}"
        out.append(src[pos:m.end()])
        out.append(body)
        out.append(")")
        pos = i
        count += 1
    out.append(src[pos:])
    return "".join(out), count


def main():
    for name in sys.argv[1:]:
        path = Path(name)
        src = path.read_text()
        result, count = rewrite(src, bare_allowed="/PlexService/" in name)
        if count:
            path.write_text(result)
            print(f"{count} {path}")


if __name__ == "__main__":
    main()
