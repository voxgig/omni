#!/usr/bin/env python3
"""The second prose gate: the rules Vale cannot express.

Vale carries Google's rules and the banned list (see `.vale.ini`). This
carries the house rules that need to know something Vale does not: which
pages are which, where a tutorial ends, and where a paragraph ends.

    banned-phrases          reject.txt, matched across a line wrap
    em-dashes-are-spaced    the house convention Google rules the other way
    em-dashes-are-rationed  one aside per line
    we-appears-only-in-tutorials
    first-person-singular   stricter than Google's rule
    no-emoji
    internal-documents      documentation never cites a working document
    relative-links-resolve  a link's target exists, inside the repository
    page-set-is-complete    the required pages are all present
    vale-sections-spare-the-pages
                            no blanked .vale.ini section covers a page

Run it directly, or `make scan-prose`. `--files` prints the page set both
gates read, so the Vale invocation and this one cannot drift apart.

Every rule here exists because `.vale.ini` switches a Google rule off in
its favour, or because Google has no rule for it. A rule switched off in
favour of a house rule that is not real is worse than no rule at all --
upstream (jostraca/jostraca, whose gate this is a port of, by way of
voxgig/struct) records finding exactly that, twice.

Usage:
    python3 tools/check_prose.py            # gate the reader-facing pages
    python3 tools/check_prose.py --files    # print the page set, one per line
    python3 tools/check_prose.py a.md b.md  # gate named pages instead
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

STYLE_GUIDE = ROOT / "STYLE-GUIDE.md"


# ---------------------------------------------------------------------
# PER-REPOSITORY CONFIGURATION.
#
# This block is the only part of the file that differs between the
# Voxgig repositories carrying this gate. Everything below it is shared,
# so a fix to a check belongs in every copy; keep the block small and
# the rest identical.
# ---------------------------------------------------------------------

PROJECT = "Voxgig Omni"

# The vocabulary directory under .vale/styles/config/vocabularies/.
VOCAB = "Omni"

# The root pages, always required: the doorway and the single guide.
ROOT_PAGES = ("README.md", "DOCS.md")

# No documentation tree: the guide is one file, DOCS.md, and the rest of
# the pages are the per-port READMEs below.
DOC_GLOBS = ()
NOT_DOCS = ()

# Pages outside the tree. None.
EXTRA_PAGES = ()

# Multi-port layout: one directory per language, each carrying its own
# README.md. Every top-level directory not listed here that holds a
# README.md is a port -- boru included, held from the test sweep but a
# port all the same. The excluded ones hold the corpus, the build
# machinery, and the working documents.
PORT_DIRS = True
NOT_PORTS = ("doc", "docs", "spec", "test", "tools", "node_modules")
PORT_PAGES = ("README.md",)

# Where "we" is allowed (voice rule 7): no whole page. DOCS.md has no
# tutorial section -- its numbered parts are a glossary, the reference,
# one how-to and the variance record -- so the only allowance left is the
# checker's own, for a `## 1.` section, which lands on the Concepts
# glossary. No page used the word when the gate arrived.
TUTORIAL_PAGES = ()

# Working documents a page must not cite, by name. Regex, then the label
# a finding shows. See STYLE-GUIDE.md, "Documentation does not cite a
# working document".
WORKING_DOCS = (
    (r"\bAGENTS\.md\b", "AGENTS.md"),
    (r"\bCLAUDE\.md\b", "CLAUDE.md"),
    (r"\bdoc/plan/", "a plan under doc/plan/"),
    (r"\bdoc/design/", "a design note under doc/design/"),
    (r"\b(?:adoption|progress|handover|status)\.md\b",
     "a plan under doc/plan/"),
    (r"\b(?:absence-model|git-refs|model-review-2026-08|review-2026-08)\.md\b",
     "a design note under doc/design/"),
    (r"\b[A-Z][A-Z0-9_]*_(?:PLAN|REVIEW)\.md\b", "a plan or review file"),
    (r"\bBUILD_LOG\.md\b", "BUILD_LOG.md"),
)


REJECT_FILE = (ROOT / ".vale" / "styles" / "config" / "vocabularies"
               / VOCAB / "reject.txt")


# ---------------------------------------------------------------------
# The page set.
#
# Reader-facing means the pages a reader lands on from GitHub, npm,
# pkg.go.dev and the rest: the root pages, the documentation tree, and
# the per-implementation READMEs. Working documents -- plans, reviews,
# decision records, and the agent instruction files -- are not in it,
# and STYLE-GUIDE.md is exempt for the reason upstream gives: it quotes
# the banned phrases in order to ban them, and names the working
# documents in order to ban citations of them.
# ---------------------------------------------------------------------

def _excluded(rel: str) -> bool:
    return any(rel == p or rel.startswith(p.rstrip("/") + "/")
               for p in NOT_DOCS)


def port_dirs() -> list[Path]:
    """Directories that carry a required page (multi-port layout only)."""
    if not PORT_DIRS:
        return []
    out = []
    for child in sorted(ROOT.iterdir()):
        if not child.is_dir() or child.name.startswith("."):
            continue
        if child.name in NOT_PORTS:
            continue
        if any((child / name).is_file() for name in PORT_PAGES):
            out.append(child)
    return out


def pages() -> list[Path]:
    found = [ROOT / name for name in ROOT_PAGES]
    for pattern in DOC_GLOBS:
        for path in sorted(ROOT.glob(pattern)):
            rel = str(path.relative_to(ROOT))
            if path.is_file() and not _excluded(rel):
                found.append(path)
    for child in port_dirs():
        found += [child / name for name in PORT_PAGES]
    found += [ROOT / name for name in EXTRA_PAGES]
    seen: set[Path] = set()
    out = []
    for path in found:
        if path.is_file() and path not in seen:
            seen.add(path)
            out.append(path)
    return out


def check_page_set() -> list[str]:
    """EXISTENCE IS NOT MEMBERSHIP. `pages()` can only return files that
    are there, so deleting one would shrink the set silently -- both
    gates would report on one page fewer and pass, and nothing would say
    the missing one had stopped being read. The required pages are asked
    for by name and a gap fails, rather than being absorbed."""
    hits = []
    for name in ROOT_PAGES + EXTRA_PAGES:
        if not (ROOT / name).is_file():
            hits.append(f"missing required page: {name}")
    for child in port_dirs():
        for name in PORT_PAGES:
            if not (child / name).is_file():
                hits.append(
                    f"missing required page: {child.name}/{name} "
                    f"(the directory carries the other one)")
    return hits


def label(path: Path) -> str:
    """Repo-relative where possible; a path named on the command line may
    sit outside the tree (a scratch file being probed), and reporting it
    should not be a crash."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


# ---------------------------------------------------------------------
# Text handling.
# ---------------------------------------------------------------------

FENCE_OPEN = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")


def lf(text: str) -> str:
    """Line endings are the checkout's business, not this file's."""
    return text.replace("\r\n", "\n").replace("\r", "\n")


def fenceless(md: str) -> str:
    """Fenced blocks BLANKED rather than dropped, so a reported line
    number still matches the file. Inline code spans are kept: `AGENTS.md`
    in a sentence is the citation being banned, not an incidental token.
    """
    lines = lf(md).split("\n")
    out = list(lines)
    i = 0
    while i < len(lines):
        match = FENCE_OPEN.match(lines[i])
        if not match:
            i += 1
            continue
        marker = match.group(1)
        out[i] = ""
        j = i + 1
        while j < len(lines) and not lines[j].lstrip().startswith(marker):
            out[j] = ""
            j += 1
        if j < len(lines):
            out[j] = ""
        i = j + 1
    return "\n".join(out)


# A code span may be broken by a line wrap, and the first-person rule
# would then read a compiler's `-I` flag as the pronoun -- the shape of
# false positive that gets a gate switched off.
#
# BALANCED RUNS, not single backticks. Markdown closes a span with a run of
# exactly as many backticks as opened it, which is how code containing a
# backtick is written. A pattern matching one pair at a time strips the
# delimiters of such a span and leaves its CONTENTS in the prose stream,
# so ``my`` or ``quietly`` would fail a gate for a word only ever shown as
# code. The lookarounds pin the run length; the bound keeps an unmatched
# backtick to a sentence rather than the rest of the file.
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)(.{0,400}?)(?<!`)\1(?!`)", re.S)


# A link's DESTINATION is not prose: the reader never sees it. Left in, a
# perfectly ordinary URL with a path segment like /our/ or /mine trips the
# first-person rule, and one with /quietly trips the banned list -- a false
# positive on compliant copy, in the checks that .vale.ini switches
# Google.We and Google.FirstPerson off in favour of.
#
# The destination is blanked to spaces rather than removed, and the link
# TEXT is kept, so both the visible words and every character position
# survive. `check_links` reads fenceless() instead, which keeps the
# destinations it exists to resolve.
INLINE_LINK = re.compile(r"(\[[^\]]*\])(\([^)\n]*\)|\[[^\]]*\])")

LINK_DEF = re.compile(r"(?m)^(\s{0,3}\[[^\]]+\]:)(.*)$")

# An HTML comment is a directive to a tool or a note to an editor, never
# prose the reader sees. Blanked the same way, keeping newlines.
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)


def _blank(match: re.Match, keep: int, blank: int) -> str:
    return match.group(keep) + " " * len(match.group(blank))


def prose(md: str) -> str:
    """Strip frontmatter, fenced blocks, inline code spans, HTML comments
    and link destinations; what remains is prose.

    Spans are replaced by their own newlines rather than removed, so a
    reported line number still matches the file.
    """
    text = fenceless(md)
    text = re.sub(r"\A---\n.*?\n---\n", "", text, flags=re.S)
    text = CODE_SPAN.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    text = HTML_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    text = INLINE_LINK.sub(lambda m: _blank(m, 1, 2), text)
    return LINK_DEF.sub(lambda m: _blank(m, 1, 2), text)


class Para:
    """A paragraph joined for matching, with each piece's physical line
    kept so a hit can still name a line the reader can open."""

    __slots__ = ("text", "starts", "lines", "pieces")

    def __init__(self, pieces: list[tuple[int, str]]):
        self.pieces = [p for _, p in pieces]
        self.lines = [n for n, _ in pieces]
        self.starts = []
        at = 0
        for piece in self.pieces:
            self.starts.append(at)
            at += len(piece) + 1
        self.text = " ".join(self.pieces)

    def at(self, index: int) -> tuple[int, str]:
        k = 0
        for n, start in enumerate(self.starts):
            if start <= index:
                k = n
        return self.lines[k], self.pieces[k]


def paragraphs(text: str) -> list[Para]:
    """Markdown treats a newline inside a paragraph as whitespace, and
    these pages are hard-wrapped -- so "worth\\nnoting" is the ORDINARY
    shape of a multiword phrase here, not an exotic one. A gate matching
    physical lines would miss most of them, which makes wrapping a way
    through it.
    """
    out: list[Para] = []
    buf: list[tuple[int, str]] = []
    for i, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            if buf:
                out.append(Para(buf))
                buf = []
            continue
        buf.append((i, re.sub(r"\s+", " ", line.strip())))
    if buf:
        out.append(Para(buf))
    return out


# ---------------------------------------------------------------------
# The banned list, read from the file Vale reads.
#
# Vale matches reject.txt entries case-insensitively on word boundaries;
# mirror exactly that, so a phrase cannot pass one gate and fail the
# other.
# ---------------------------------------------------------------------

def load_banned() -> list[tuple[re.Pattern, str]]:
    if not REJECT_FILE.is_file():
        sys.exit(f"missing banned list: {REJECT_FILE}")
    out = []
    for line in REJECT_FILE.read_text(encoding="utf-8").split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        out.append((re.compile(r"\b(?:%s)\b" % line, re.I), line))
    return out


# ---------------------------------------------------------------------
# Internal working documents.
#
# The NAME is banned as well as the link: "the full checklist is in
# AGENTS.md" strands a reader exactly as the URL does. The per-repository
# set is WORKING_DOCS in the configuration block; these two shapes are
# shared, for a document named by description rather than by filename.
# The bare noun is not a citation: "notes for AI coding agents" describes
# the repository layout and sends nobody anywhere, while "see the agent
# notes" leans on it as a source.
# ---------------------------------------------------------------------

CITATION_SHAPES = [
    (re.compile(r"\b(?:see|per|as|in) the (?:agent|contributor) "
                r"(?:notes|instructions|guide)\b", re.I),
     "an internal document, cited"),
    (re.compile(r"\bthe (?:agent|contributor) (?:notes|instructions|guide) "
                r"(?:explains?|notes?|records?|says?|covers?|lists?)\b", re.I),
     "an internal document, cited"),
]


def working_docs() -> list[tuple[re.Pattern, str]]:
    out = [(re.compile(pattern), name) for pattern, name in WORKING_DOCS]
    return out + CITATION_SHAPES


# ---------------------------------------------------------------------
# The checks.
# ---------------------------------------------------------------------

EMOJI = re.compile(
    "[\U0001F300-\U0001FAFF☀-➿️⬀-⯿]")

# "I" is stricter than Google's rule and applies to every page. I/O is a
# word, not a pronoun; the negative lookahead keeps it.
FIRST_SINGULAR = re.compile(
    r"\bI(?!/O)\b|\bI'(?:m|ve|ll|d)\b|\b(?:my|mine|myself)\b")

FIRST_PLURAL = re.compile(
    r"\b(we|we'(?:ll|ve|re|d)|us|our|ours|let's)\b", re.I)

# A tutorial walks through code with the reader, and voice rule 7 allows
# "we" there and nowhere else. A tutorial is a page under TUTORIAL_PAGES,
# or -- in a single-file guide -- the section headed `## 1.`.
TUTORIAL_HEAD = re.compile(r"^##\s*1\.\s", re.M)
SECTION_HEAD = re.compile(r"^##\s", re.M)


def is_tutorial_page(path: Path) -> bool:
    rel = label(path)
    return any(rel == p or rel.startswith(p.rstrip("/") + "/")
               for p in TUTORIAL_PAGES)


def tutorial_lines(path: Path, md: str) -> set[int]:
    """Physical line numbers inside the tutorial, if the page has one:
    the whole page for a tutorial page, the `## 1.` section for a
    single-file guide, empty otherwise."""
    lines = lf(md).split("\n")
    if is_tutorial_page(path):
        return set(range(1, len(lines) + 1))
    start = None
    for i, line in enumerate(lines):
        if SECTION_HEAD.match(line):
            if start is None and TUTORIAL_HEAD.match(line):
                start = i
            elif start is not None:
                return set(range(start + 1, i + 1))
    if start is not None:
        return set(range(start + 1, len(lines) + 1))
    return set()


def check(paths: list[Path]) -> list[str]:
    banned = load_banned()
    internal = working_docs()
    hits: list[str] = []

    def add(hit: str) -> None:
        if hit not in hits:
            hits.append(hit)

    for path in paths:
        name = label(path)
        raw = path.read_text(encoding="utf-8")
        text = prose(raw)
        plain = fenceless(raw)
        tutorial = tutorial_lines(path, raw)

        # banned-phrases: paragraph-joined, so a line wrap is not a way
        # through the gate.
        for para in paragraphs(text):
            for pattern, source in banned:
                for match in pattern.finditer(para.text):
                    line, piece = para.at(match.start())
                    add(f'{name}:{line}  banned "{source}": {piece}')

        # internal-documents: paragraph-joined for the same reason.
        for para in paragraphs(plain):
            for pattern, source in internal:
                for match in pattern.finditer(para.text):
                    line, piece = para.at(match.start())
                    add(f'{name}:{line}  cites {source}: {piece}')

        for i, line in enumerate(text.split("\n"), 1):
            # em-dashes-are-spaced. Google rules the other way and
            # `.vale.ini` switches Google.EmDash off; this is the rule it
            # is switched off in favour of, so it has to be real.
            for match in re.finditer(r"(.?)—(.?)", line):
                before, after = match.group(1), match.group(2)
                if before not in ("", " ") or after not in ("", " "):
                    add(f"{name}:{i}  unspaced em dash: {line.strip()}")

            # em-dashes-are-rationed: one ASIDE per line, so a single
            # trailing dash or one matched pair. Three is the stacking the
            # ration exists to stop.
            if line.count("—") > 2:
                add(f"{name}:{i}  {line.count(chr(0x2014))} em dashes on "
                    f"one line: {line.strip()}")

            match = FIRST_SINGULAR.search(line)
            if match:
                add(f'{name}:{i}  first-person singular "{match.group(0)}": '
                    f"{line.strip()}")

            if i not in tutorial:
                match = FIRST_PLURAL.search(line)
                if match:
                    add(f'{name}:{i}  first-person plural outside a tutorial '
                        f'"{match.group(1)}": {line.strip()}')

        for i, line in enumerate(lf(raw).split("\n"), 1):
            if EMOJI.search(line):
                add(f"{name}:{i}  emoji: {line.strip()}")

    return hits


# ---------------------------------------------------------------------
# Relative links.
#
# Only the PATH is resolved, not the anchor: a heading slug depends on the
# renderer, and a gate that guesses one would fail on correct links.
#
# BOTH MARKDOWN LINK FORMS. The inline `[text](target)` is the common one,
# but `[text][label]` with a `[label]: target` definition is equally
# standard. A gate that reads only the first form would report success
# on a broken reference link while promising to check every link, which
# is worse than not having the check.
# ---------------------------------------------------------------------

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")

LINK_TARGET = re.compile(r"(?m)^\s{0,3}\[[^\]]+\]:\s*<?([^>\s]+)>?")

EXTERNAL = ("http://", "https://", "mailto:", "#", "//")


def broken(page: Path, target: str) -> bool:
    """A target is good only if it exists AND stays inside the repository.

    Existing is not enough: `../../etc/passwd` from a root page resolves on
    a Linux runner and would pass, while resolving nowhere on GitHub or
    inside a published package. Both halves have to hold.
    """
    relative = target.split("#", 1)[0]
    if not relative:
        return False
    resolved = (page.parent / relative).resolve()
    if not resolved.exists():
        return True
    return not resolved.is_relative_to(ROOT)


def linkable(md: str) -> str:
    """Fenced blocks and inline code spans blanked, newlines kept. A
    `[text](target)` shown as code is a description of a link, not a
    link -- Markdown renders it literally -- so resolving its target
    would fail a page for quoting the syntax. The guide does exactly
    that, one section down from where it explains this check."""
    text = fenceless(md)
    return CODE_SPAN.sub(lambda m: "\n" * m.group(0).count("\n"), text)


def check_links(paths: list[Path]) -> list[str]:
    hits = []
    for path in paths:
        name = label(path)
        text = linkable(path.read_text(encoding="utf-8"))
        for i, line in enumerate(text.split("\n"), 1):
            targets = [m.group(1) for m in LINK.finditer(line)]
            targets += [m.group(1) for m in LINK_TARGET.finditer(line)]
            for target in targets:
                if target.startswith(EXTERNAL):
                    continue
                if broken(path, target):
                    hits.append(f"{name}:{i}  broken link: {target}")
    return hits


# ---------------------------------------------------------------------
# Vale sections must not cover a page.
#
# `.vale.ini` blanks the styles for the directories that hold working
# documents and source, so a bare `vale .` stays quiet about them. Vale
# matches those section globs against EVERY file it is given, named on
# the command line or not -- so a blanked section over a directory that
# also holds a reader-facing page switches every rule off for that page
# and reports nothing. That is the silent hole the explicit file list was
# meant to rule out, and voxgig/model's first draft had it: `[go/**]`
# blanked go/README.md, and Vale passed the page without reading it.
#
# Only sections with an EMPTY BasedOnStyles are checked; a section that
# narrows the styles is a choice, not a hole. Vale's globs let `*` and
# `**` cross directory separators, so both become `.*` here.
# ---------------------------------------------------------------------

VALE_INI = ROOT / ".vale.ini"

SECTION_HEAD_INI = re.compile(r"^\s*\[([^\]]+)\]\s*$")
BASED_ON = re.compile(r"^\s*BasedOnStyles\s*=\s*(.*?)\s*$")


def blanked_sections() -> list[str]:
    """The globs of every section whose BasedOnStyles is empty."""
    if not VALE_INI.is_file():
        return []
    out: list[str] = []
    current = None
    for line in VALE_INI.read_text(encoding="utf-8").split("\n"):
        head = SECTION_HEAD_INI.match(line)
        if head:
            current = head.group(1)
            continue
        based = BASED_ON.match(line)
        if based and current is not None and based.group(1) == "":
            out.append(current)
    return out


def vale_glob(pattern: str) -> re.Pattern:
    out = ""
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            out += ".*"
            while i + 1 < len(pattern) and pattern[i + 1] == "*":
                i += 1
        elif c == "?":
            out += "."
        elif c == "{":
            j = pattern.find("}", i)
            if j < 0:
                out += re.escape(c)
            else:
                alts = pattern[i + 1:j].split(",")
                out += "(?:%s)" % "|".join(re.escape(a) for a in alts)
                i = j
        else:
            out += re.escape(c)
        i += 1
    return re.compile(r"\A%s\Z" % out)


def check_vale_sections(paths: list[Path]) -> list[str]:
    hits = []
    for section in blanked_sections():
        matcher = vale_glob(section)
        for path in paths:
            rel = label(path)
            if matcher.match(rel) or matcher.match("/" + rel):
                hits.append(f".vale.ini  [{section}] blanks every style for "
                            f"{rel}, a page Vale would then pass unread")
    return hits


def check_guide_names_this_gate() -> list[str]:
    """The guide and this gate must agree; the guide names this file, so a
    reader of either finds the other."""
    if not STYLE_GUIDE.is_file():
        return [f"missing {label(STYLE_GUIDE)}"]
    text = STYLE_GUIDE.read_text(encoding="utf-8")
    out = []
    if "tools/check_prose.py" not in text:
        out.append("STYLE-GUIDE.md should point at tools/check_prose.py")
    if "reject.txt" not in text:
        out.append("STYLE-GUIDE.md should name the banned list file")
    return out


def main(argv: list[str]) -> int:
    if "--files" in argv:
        problems = check_page_set()
        if problems:
            for problem in problems:
                print(problem, file=sys.stderr)
            return 1
        try:
            for path in pages():
                print(label(path))
            sys.stdout.flush()
        except BrokenPipeError:
            # `--files | head` closes the pipe early. Not a failure.
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0

    named = [Path(a).resolve() for a in argv if not a.startswith("-")]
    paths = named or pages()

    hits = check(paths) + check_links(paths)
    if not named:
        hits += (check_page_set() + check_vale_sections(paths)
                 + check_guide_names_this_gate())

    print(f"prose gate: {len(paths)} pages")
    if hits:
        for hit in hits:
            print(f"  {hit}")
        print(f"\n{len(hits)} finding(s) — see STYLE-GUIDE.md")
        return 1
    print("  ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
