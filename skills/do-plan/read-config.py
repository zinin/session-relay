#!/usr/bin/env python3
"""Read session-relay's config: two flat keys, Python standard library only.

    read-config.py [--file PATH] get stop_tokens|dispatch_model
    read-config.py [--file PATH] path

The file is PATH, else ${XDG_CONFIG_HOME:-~/.config}/session-relay/config.yaml. A missing
file means the defaults: stop_tokens 400000, dispatch_model unset (printed as an empty line).

The format is a strict subset of YAML: one `key: value` per line, `#` comments, blank lines,
optional quotes around a value. A mistake — an unknown or repeated key, a value that is not
what the key takes — exits 1 with `<file>:<line>: <reason>` on stderr instead of falling back
to a default: a typo must not quietly move the STOP threshold. Usage errors exit 64.
"""
import os
import re
import sys

DEFAULTS = {"stop_tokens": "400000", "dispatch_model": ""}
MIN_STOP = 150000  # the context hook emits nothing below 150k, so a lower threshold never fires
# Same charset as mesh's runtime.dispatch_model: a leading letter/digit keeps flags out.
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@-]*$")
LINE_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*$")


def default_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "session-relay", "config.yaml")


def fail(where, reason):
    print(f"{where}: {reason}", file=sys.stderr)
    sys.exit(1)


def parse(path):
    values = dict(DEFAULTS)
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return values
    seen = set()
    for number, raw in enumerate(lines, 1):
        where = f"{path}:{number}"
        line = re.sub(r"(^|\s)#.*$", "", raw).strip()
        if not line:
            continue
        match = LINE_RE.match(line)
        if not match:
            fail(where, "expected `key: value`")
        key, value = match.group(1), match.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        if key not in DEFAULTS:
            fail(where, f"unknown key '{key}' (valid: {', '.join(DEFAULTS)})")
        if key in seen:
            fail(where, f"duplicate key '{key}'")
        seen.add(key)
        if key == "stop_tokens":
            if not re.fullmatch(r"[1-9][0-9]*", value):
                fail(where, f"stop_tokens must be a whole number of tokens, got '{value}'")
            if int(value) < MIN_STOP:
                fail(where, f"stop_tokens must be >= {MIN_STOP} (the context hook emits nothing below 150k), got {value}")
        elif value and not MODEL_RE.match(value):
            fail(where, f"dispatch_model must start with a letter or digit and use only [A-Za-z0-9._:@-], got '{value}'")
        values[key] = value
    return values


def main(argv):
    args = list(argv)
    path = None
    if args[:1] == ["--file"]:
        if len(args) < 2 or not args[1]:
            print("usage: read-config.py [--file PATH] get <key> | path", file=sys.stderr)
            return 64
        path, args = args[1], args[2:]
    path = path or default_path()
    if args == ["path"]:
        print(path)
        return 0
    if len(args) != 2 or args[0] != "get" or args[1] not in DEFAULTS:
        print("usage: read-config.py [--file PATH] get stop_tokens|dispatch_model | path", file=sys.stderr)
        return 64
    print(parse(path)[args[1]])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
