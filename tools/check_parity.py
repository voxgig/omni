#!/usr/bin/env python3
"""Check that every omni port defines the canonical API.

The canonical API is the export list of the TypeScript port
(typescript/src/index.ts). Every other port must define every name, in
local casing - matching is case- and underscore-insensitive, exactly as in
voxgig/struct.

SCOPE: this is a NAME check, not a behaviour check. It confirms each
canonical identifier appears as a token in a port's source (it scans raw
text, so a name in a comment counts). It does NOT verify that a port's
`deepequal`, `matchval`, etc. behave like the canonical - a port whose
`deepequal` was `return true` would pass here. Behavioural parity is the
job of `spec/fib.json` (run per port) plus each port's negative meta-tests
("prove it can fail"); when those do not exercise an area (ctx, err.name,
number formatting, ...), ports can drift while this check stays green.

Usage: python3 tools/check_parity.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The canonical public surface. Every port must define all of these.
CANONICAL = [
    # runner
    'makeRunner',
    'runset',
    'runsetflags',
    'loadspec',
    'resolvespec',
    'fixjson',
    'errify',
    'match',
    'matchval',
    'nullmodifier',
    'OmniError',
    # sentinels
    'NULLMARK',
    'UNDEFMARK',
    'EXISTSMARK',
    # util
    'clone',
    'deepequal',
    'getpath',
    'walk',
    'jsonstr',
    'stringify',
    'pathify',
]

# Where each port's library source lives (test code is not scanned).
PORTS = {
    'typescript': ['typescript/src'],
    'javascript': ['javascript/src'],
    'python': ['python/voxgig_omni'],
    'ruby': ['ruby/lib'],
    'php': ['php/src'],
    'perl': ['perl/lib'],
    'go': ['go/util.go', 'go/omni.go'],
    'rust': ['rust/src'],
    'java': ['java/src'],
    'c': ['c/src'],
    'cpp': ['cpp/src'],
    'csharp': ['csharp/src'],
    'kotlin': ['kotlin/src'],
    'scala': ['scala/src'],
    'clojure': ['clojure/src'],
    'lua': ['lua/src'],
    'zig': ['zig/src'],
    'swift': ['swift/Sources/Omni'],
    'dart': ['dart/lib'],
    'elixir': ['elixir/lib'],
    'ocaml': ['ocaml/src'],
    'haskell': ['haskell/src'],
    'lean': ['lean/Omni.lean'],
}

SKIP_DIRS = {'node_modules', 'dist', 'build', 'target', '__pycache__', 'bin', 'obj', '.lake'}

# Documented per-port variance. A port may only appear here for a name it
# genuinely cannot express; the reason is printed on every run.
EXEMPT = {
    'c': {
        'OmniError': 'C has no exception type: failures are returned as messages',
    },
    'zig': {
        'OmniError': 'Zig error values carry no payload: failures are returned as messages',
    },
    'lean': {
        'OmniError': 'Lean checks are pure: failures are returned as Except String',
    },
}


def normal(name):
    """Case- and underscore-insensitive form of a name."""
    return re.sub(r'[_\-]', '', name).lower()


def variants(name):
    """A name, plus the form without a namespace prefix (C uses omni_*)."""
    key = normal(name)
    out = {key}
    if key.startswith('omni') and 4 < len(key):
        out.add(key[4:])
    return out


def sources(paths):
    """Every source file under the given paths."""
    out = []

    for path in paths:
        full = os.path.join(ROOT, path)

        if os.path.isfile(full):
            out.append(full)
            continue

        for dirpath, dirnames, filenames in os.walk(full):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for filename in filenames:
                if filename.startswith('.'):
                    continue
                out.append(os.path.join(dirpath, filename))

    return out


def defined(paths):
    """The set of identifiers a port's source defines, normalised."""
    found = set()

    for path in sources(paths):
        try:
            with open(path, encoding='utf-8') as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue

        for token in re.findall(r'[A-Za-z_][A-Za-z0-9_\-]*', text):
            found |= variants(token)

    return found


def main():
    want = [(name, normal(name)) for name in CANONICAL]
    problems = 0

    print('omni parity: %d canonical names\n' % len(CANONICAL))

    for port in sorted(PORTS):
        found = defined(PORTS[port])
        exempt = EXEMPT.get(port, {})
        missing = [name for name, key in want if key not in found and name not in exempt]

        for name, reason in sorted(exempt.items()):
            print('%-12s exempt: %s (%s)' % (port, name, reason))

        if missing:
            problems += 1
            print('%-12s MISSING: %s' % (port, ', '.join(missing)))
        else:
            print('%-12s ok' % port)

    print('')

    if problems:
        print('omni: %d port(s) incomplete' % problems)
        return 1

    print('omni: all ports complete')
    return 0


if __name__ == '__main__':
    sys.exit(main())
