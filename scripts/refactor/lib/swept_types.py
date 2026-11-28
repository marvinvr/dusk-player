#!/usr/bin/env python3
"""List the types that declare a stored property named one of WORDS.

  swept_types.py WORD[,WORD...] FILE...

Prints `<file> <Type> <Codable?> <has CodingKeys?>` per type, sorted. The P0-02
sweep compares this against its expected list: a type that gains or loses such
a property on main must be looked at (synthesized Codable keys would follow the
Swift rename) before the sweep is trusted again.
"""
import re
import sys

DECL = re.compile(r"^(\s*)(?:public |private |fileprivate |internal )?(?:final )?(struct|class|enum|actor|extension) (\w+)([^{]*)\{")


def main():
    words = sys.argv[1].split(",")
    prop = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))? )*(?:private(?:\(set\))? |fileprivate |public )?(?:let|var) (" + "|".join(words) + r")\b\s*:")
    rows = set()
    for name in sys.argv[2:]:
        lines = open(name).read().split("\n")
        for n, line in enumerate(lines):
            if not prop.match(line):
                continue
            indent = len(line) - len(line.lstrip())
            for i in range(n - 1, -1, -1):
                m = DECL.match(lines[i])
                if m and len(m.group(1)) < indent:
                    body = "\n".join(lines[i:])
                    end = body.find("\n" + m.group(1) + "}")
                    block = body[: end if end >= 0 else len(body)]
                    codable = bool(re.search(r"\b(Codable|Decodable|Encodable|GroupActivity)\b", m.group(4)))
                    keys = "CodingKeys" in block
                    rows.add(f"{name} {m.group(3)} codable={codable} keys={keys}")
                    break
    print("\n".join(sorted(rows)))


if __name__ == "__main__":
    main()
