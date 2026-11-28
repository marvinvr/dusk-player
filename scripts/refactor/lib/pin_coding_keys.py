#!/usr/bin/env python3
"""Pin CodingKey raw values before a field rename (docs/jellyfin/05-plan.md P0-02).

  pin_coding_keys.py WORD[,WORD...] FILE...

In every enum whose inheritance clause names `CodingKey` or `String`, a case
named WORD without a raw value gets `= "WORD"`, so renaming the case later
keeps the key on the wire and on disk. Cases that already have a raw value are
left alone (the rename then only changes the Swift name).

Prints `<count> <file>` per changed file.
"""
import re
import sys
from pathlib import Path

ENUM = re.compile(r"\benum\s+\w+\s*:\s*([^{]*)\{")


def body_end(src, start):
    depth = 1
    i = start
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return i - 1


def pin(src, words):
    out, last, count = [], 0, 0
    case_word = re.compile(r"(?<![A-Za-z0-9_.\"])(" + "|".join(words) + r")(?![A-Za-z0-9_])(?!\s*=)(?!\s*\()")
    for match in ENUM.finditer(src):
        inherits = match.group(1)
        if "CodingKey" not in inherits and not re.search(r"\bString\b", inherits):
            continue
        start = match.end()
        end = body_end(src, start)
        body = src[start:end]
        lines = body.split("\n")
        changed = False
        for n, line in enumerate(lines):
            stripped = line.lstrip()
            if not stripped.startswith("case "):
                continue
            code, sep, comment = stripped.partition("//")
            new_code, k = case_word.subn(lambda m: f'{m.group(1)} = "{m.group(1)}"', code)
            if k:
                count += k
                changed = True
                lines[n] = line[: len(line) - len(stripped)] + new_code + sep + comment
        if changed:
            out.append(src[last:start])
            out.append("\n".join(lines))
            last = end
    out.append(src[last:])
    return "".join(out), count


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    words = sys.argv[1].split(",")
    for name in sys.argv[2:]:
        path = Path(name)
        src = path.read_text()
        result, count = pin(src, words)
        if count:
            path.write_text(result)
            print(f"{count} {path}")


if __name__ == "__main__":
    main()
