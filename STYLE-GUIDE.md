# Documentation style guide

How the Voxgig Omni documentation is written. This guide is normative
for the root [`README.md`](./README.md) and [`DOCS.md`](./DOCS.md) and
for every port's `README.md` — 26 pages, the ones a reader lands on from
GitHub, from npm, and from a checkout wired in beside their own
repository. It exists so that a page written next year sounds like a page
written this year, and so that a reviewer can point at a rule instead of
arguing taste.

It is a port of [jostraca/jostraca](https://github.com/jostraca/jostraca)'s
guide, by way of [voxgig/struct](https://github.com/voxgig/struct)'s,
which share an author and a house voice with this project. The structure
and most of the rules are those projects'. Where this one differs — the
spaced em dash, the working-document set, the shape of the four parts —
the difference is recorded with the measurement behind it, because a
divergence nobody wrote down reads later as drift.

Three sources feed the guide, in a fixed priority order. The same order is
encoded in [`.vale.ini`](./.vale.ini), and every rule switched off there
names the reason and the count it produced:

    house voice  ->  Google  ->  Vale defaults

1. **This file.** Where it rules, it rules. The house voice is Richard
   Rodger's blog register, and the places it wins are listed with their
   reasons rather than left as silent exceptions: the spaced em dash,
   first-person plural in a tutorial section, British spellings, and
   quotation punctuation outside the quotes.
2. The [Google developer documentation style
   guide](https://developers.google.com/style) for everything this file
   does not cover: second person, present tense, active voice,
   sentence-style capitalisation in headings, serial commas, one idea per
   sentence.
3. [Vale](https://vale.sh) defaults, which mostly means spelling.

Two gates check it, and both run in CI:

| Gate | Runs | Checks |
|---|---|---|
| `vale --minAlertLevel=error $(python3 tools/check_prose.py --files)` | `make scan-prose`, `.github/workflows/docs.yml` | Google's rules plus the banned list, at the levels set in `.vale.ini` |
| `python3 tools/check_prose.py` | `make scan-prose`, `make test`, and the same workflow | the banned list, the em-dash spacing and ration, the first-person rules, no emoji, no citations of a working document, that every relative link resolves, and that the page set is complete |

The banned list is read from one file by both, so they cannot drift. The
page set comes from one function, `tools/check_prose.py --files`, for the
same reason: a gate reading a smaller set than the other is a gate that
reports green on a page nobody checked.

A Google rule sitting at `warning` rather than `error` was tried at error
level first and found wrong for these pages; `.vale.ini` records what it
produced and why it was demoted.

## The structure: four parts, as sections rather than files

A full guide has four parts: a tutorial, how-to recipes, a reference, and
an explanation, in that order. Upstream gives each part its own file.
This project has 24 ports and one guide, so the part is a **numbered
section** inside `DOCS.md`, and the rules attach to the section:

| Part | Where | May | May not |
|---|---|---|---|
| Tutorial | none yet; the opening of `README.md` does the job at doorway altitude | teach step by step, show output for every step, defer detail with a link | argue design, list every field, assume the reader's goal |
| How-to | `DOCS.md` §8, *Replacing struct's in-situ runners* | solve one named task, assume competence, link the reference | teach basics, explain design, drift into a second task |
| Reference | `DOCS.md` §1–§7: *Concepts*, *The spec format*, *Runner semantics*, *The provider*, *Flags*, *Failure messages*, *The API, per port* | state facts exhaustively and dryly, pin claims to corpus groups and tests | narrate, persuade, teach |
| Explanation | `DOCS.md` §9, *Per-port variance*, and its closing argument about what the corpus does and does not prove | argue, compare, admit trade-offs, tell the design's story | be the only place a fact lives |

When a tutorial is written it goes in as the `## 1.` section, which is
the one place the gate already allows "we", and the sections after it
renumber. Until then the word is allowed nowhere, and no page uses it.

`README.md` is the doorway and belongs to no part: it routes, gives the
quick start in three languages, and states no fact of its own that
`DOCS.md` does not also state.

One fact appears in all four parts at different altitudes — met in the
tutorial, used in a how-to, specified in the reference, argued in the
explanation — but the normative statement lives in the reference and
everything else links to it.

**Documentation never names the framework.** The four parts come from
`Diátaxis`, and that is a fact about how these pages were planned, not
one a reader needs in order to read them. Say **tutorial**, **how-to**,
**reference** and **explanation**, which are ordinary words that describe
themselves, and let the structure do the explaining. This guide and the
contributor guides are where the name belongs, because there it answers a
question somebody is actually asking.

### The canonical page owns the behaviour

This project has a second axis upstream does not: 24 ports of one runner.
The rule that falls out of it is the documentation half of the rule the
code already follows.

**Behaviour is documented once, on the language-neutral pages**, which are
the root `README.md` and `DOCS.md`. A port's `README.md` documents that
port: its spelling of the API (`makeRunner`, `make_runner`, `MakeRunner`,
`omni_make_runner`), its subject and failure types, how to install and
test it, its file layout, and any place it diverges. A port page that
re-explains what `match` does has taken on a copy of a fact that will go
stale the day the canonical changes, and there are 23 other copies of it
that will not be updated in the same commit.

**A divergence is stated where it happens, and pointed at the record.**
`DOCS.md` §9, *Per-port variance*, is where a divergence is pinned; a
port page names the divergence, says what this port does, and links
there. An API name a port cannot express is recorded a second time, with
its reason, in the `EXEMPT` table of `tools/check_parity.py`, and the
port page may cite that too.

## Documentation does not cite a working document

**A documentation page never sends a reader to a plan, a review, a
design note, or an agent instruction file.** Those are working documents:
written for the people changing this repository, argued rather than
stated, and stale the moment the code moves past them. A reader who
follows a link out of the documentation and lands in one has been handed
the project's notes in place of an answer.

The banned set, by name:

| Document | What it is |
|---|---|
| `AGENTS.md`, `CLAUDE.md` | instructions to contributors and agents working in the repository |
| `doc/plan/adoption.md`, `doc/plan/progress.md` | the cross-repository plan for omni replacing the in-situ runners of its consumers, and the register that tracks it item by item |
| `doc/plan/handover.md`, `doc/plan/status.md` | what survives an item landing, and the live snapshot of what is in flight — rewritten or deleted as it goes stale |
| `doc/design/absence-model.md`, `doc/design/git-refs.md` | design notes, argued while the design was open |
| `doc/design/review-2026-08.md`, `doc/design/model-review-2026-08.md` | reviews: analysis and recommendations, revised as the code moves |
| any `*_PLAN.md` or `*_REVIEW.md`, and `BUILD_LOG.md` | the shapes this project has not needed yet, guarded in advance |

The ban covers the name as much as the link. "The full checklist is in
`AGENTS.md`" fails for the same reason the URL does: the reader still
cannot act on the sentence without leaving the documentation.

State the fact instead. "TypeScript is canonical: a change in behaviour
starts in `typescript/src/Runner.ts`, is pinned in `spec/fib.aon`, and is
then carried to every port" is what a reader needs, and a link to the
file that also says so adds nothing to it. `DOCS.md` used to open by
sending the reader to the agent guide; it now states that rule. Its
account of the `__RAW__` escape used to cite an item in a review and a
row in the register; it now says the escape is planned, and stops. Where
the fact belongs in the documentation and is missing, write it into the
section that owns it rather than pointing outside.

The rule runs one way. Working documents cite each other and cite the
documentation freely, because a plan that does not show its working is
not a plan. Only the direction out of documentation is closed.

### What stays linkable, and why

| Linkable | Because |
|---|---|
| the corpus: `spec/fib.aon`, the `spec/fib.json` compiled from it, and `spec/def/omni-spec.aon` | it is the contract, and the spec-format shape is *defined* in the last of them and nowhere else |
| source and tests in every port, `typescript/src/` first | code is the thing a claim is pinned to |
| `tools/check_parity.py` | its `CANONICAL` list and `EXEMPT` table are reference data, cited by the API section and by a port that cannot express a name |
| this guide | normative rather than exploratory, and it names the working documents in order to ban them |
| the other READMEs | documentation themselves |

The rule behind the split: **a specification is citable, an argument is
not.** A reader sent to `omni-spec.aon` gets a shape they can unify a spec
against. A reader sent to a review gets somebody's reasoning, mid-flight.

`tools/check_prose.py` enforces this over the 26 reader-facing pages. Vale
does not, because Vale cannot tell a working document from a page.

## The voice

The house voice is Richard Rodger's blog register, adapted per section.
The portable part of that voice is its *rhythm*, not its stock phrases.
Ten habits, with the register they apply in:

1. **Open with a concrete fact or a plainly stated problem, then a short
   dry beat.** Tutorial and how-to sections. Reference sections open by
   stating what the thing is.
2. **Introduce code with a short colon-terminated sentence** — "So an
   expected map with a null field is written:", "Verify with:". Never
   "The following code snippet demonstrates". Everywhere.
3. **After a code block, point at the one interesting thing.** Do not
   recap the code. Everywhere.
4. **Parentheses carry definitions, caveats, and at most one dry aside per
   section.** Tutorial and how-to sections. In reference sections,
   parentheses carry facts only — a type, a default, a corpus group.
5. **A trade-off gets bolted on with a dash, and the dash earns its
   place.** One per paragraph at most, never two in a sentence. The gate
   enforces the one-aside-per-line half of that; the paragraph half is
   a review matter.
6. **Alternate one long explanatory sentence with one short verdict
   sentence.** The short sentence is the payoff. Everywhere.
7. **Talk to the reader as "you", and route them** ("If you only want the
   Go spelling, skip to…"). "We" appears only in a tutorial section,
   walking through code together. "I" appears nowhere.
8. **Show that the code is real.** Every behaviour the reference states is
   an entry in `spec/fib.aon`, and every port's suite runs every entry, so
   a claim names the group that pins it — `info` and `nulls` for the two
   null modes, `client` for subject substitution — or the negative test
   that proves the runner can fail. No gate executes an example from a
   page; when a listing is said to be what a port printed, name the
   `make test-<lang>` that printed it.
9. **Jokes are self-directed or about the industry's mundanity, and the
   register goes fully serious the moment correctness or a user's data is
   on the table.** Never joke about the reader, other languages, or
   another port.
10. **Close by handing the reader something**: a link, a next step, one
    sentence. No summary paragraphs that restate the page.

Exclamation marks: at most one per page, in a tutorial section only, on a
genuine payoff.

## Banned phrases and patterns

These read as generated filler. Do not use them, in any document,
including commit messages that quote the docs.

**The list itself lives in
[`.vale/styles/config/vocabularies/Omni/reject.txt`](./.vale/styles/config/vocabularies/Omni/reject.txt)**,
one regular expression per line. That file is the single source of truth:
Vale reads it in CI, and `tools/check_prose.py` reads the same file rather
than keeping a second copy, so the two gates cannot disagree about what is
banned. Add a phrase there and both pick it up. What follows is a reader's
summary of it, not a second list; every phrase is shown as code so that
quoting a banned phrase in this guide does not fail the gate.

The list is upstream's, unchanged, and it draws on two sources: that
project's original house list, and [claudisms.ai](https://claudisms.ai/),
a catalogue of the patterns that mark machine-written prose. **It was
measured against these pages before it was adopted.** Five entries fired,
nine times: `load-bearing` three times, `honest` twice, `not just` twice,
`comprehensive` once (in the title of `DOCS.md`), and `quietly` once. All
nine were rewritten, and nothing was dropped from the list to make it
pass.

**Filler and false emphasis**: `worth noting` · `important to note` ·
`it cannot be overstated` · `at its core` · `when it comes to` ·
`let's break it down` · `here's where it gets interesting` ·
`the point is` · `because it matters`.

**Inflated vocabulary**: `delve` · `dive into` · `robust` · `seamless` ·
`comprehensive` · `holistic` · `intricate` · `leverage` · `foster` ·
`shed light on` · `pave the way` · `pivotal` · `transformative` ·
`game-changing` · `cutting-edge` · `groundbreaking` · `testament to` ·
`paradigm shift` · `realm` · `landscape of` · `underscores the` ·
`lean into` · `throughline` · `double-click on` · `mature setup`.

**Consultant register**: `north star` · `key takeaways` ·
`best practices` (name the practice instead) · `at the end of the day` ·
`pressure-test` · `right-size` · `strategic imperative` ·
`three things to know` · `dispatches from` · `best operators` ·
`lessons learned`.

**Metaphor inflation**: `load-bearing` · `heavy lifting` ·
`is doing the work` · `different physics` · `hits hardest` ·
`quietly` (say `silently`, which is the term of art for a failure that
reports nothing).

**The contrast frame and its cousins**: `not just` · `not only X but Y` ·
`it's not about` · `the whole game` · `the entire point` ·
`the only thing that matters`. Say what the thing is.

**False singularity**: `the right way/answer/tool/question` ·
`the best thing you can do` · `if I had to pick` · `what struck me` ·
`stuck with me` · `struck a chord` · `hit a nerve` ·
`we've seen this movie before`.

**Reflective pose**: `sit with` · `worth exploring/considering/asking` ·
`keeps coming back to` · `that's the tell` · `where I landed`.

**Invented observation about people**: `most people` ·
`everyone I've worked with` · `a lot of folks` · `nobody I know`. If it
did not happen, do not claim to have noticed it.

**Signposting**: `let's explore` · `now let's turn to` · `moving on to` ·
`in today's rapidly evolving` · `reflecting a broader trend` ·
`great question`.

**`honest`, and every form of it**, is banned differently from the rest.
The word is fine English; it is on the list because it had become a tic
across the repositories that share this list, where it flattered a
sentence rather than said anything the sentence did not already say. Two
uses were here when the list arrived: the README's problem statement
("keeping the ports honest", which means keeping them in agreement, and
now says so) and the closing argument of `DOCS.md` §9 ("the honest limit
of what is checked", where the sentence was congratulating itself instead
of stating the limit). In both, the word came out and nothing was lost.

**The gate is absolute, and the lack of an inline exemption is the
point.** There is no `allow` comment and no suppression the second gate
would honour, because an escape hatch that exists is an escape hatch that
gets used. A use the author wants kept is approved by changing
`reject.txt`: one line, in one file, visible in review, which is where an
approval belongs.

### What is not banned, and why

Several entries on claudisms.ai are deliberately absent, because they name
things this project documents. A gate that fires on the subject matter is
a gate people learn to switch off. The same standard governs
`Omni.WordChoice`, which carries three of Google's substitutions and
leaves the rest at warning — and drops upstream's `regex` swap, because
six ports carry an in-tree regex engine and the word is what a reader
searches for.

| Not banned | Because |
|---|---|
| `regex` | An `err` or `match` leaf written as `/pattern/` is a regex, six ports ship their own engine for it, and §9 records which subset each supports. |
| `real` | `a real JSON null` is the definition of `__NULL__`, and `real nulls` is what the `null: false` flag hands a subject. |
| `shape` | `spec/def/omni-spec.aon` is the spec-format *shape*, and §2.1 is titled for it. |
| `surface` | `the whole utility surface` is what §9 says the corpus reaches only incidentally, and the API surface is what `tools/check_parity.py` compares. |
| `hold`, `carry`, `hands` | A group holds a `set`, an entry carries its expected result, a provider hands over the raised error. |
| `canonical` | It is this project's word for the TypeScript source every port is a port of. |

The rule behind the list: ban the phrase that adds nothing, never the word
that names a thing.

**Matching spans a line wrap.** These pages hard-wrap, and most of the
list is multi-word, so the gate joins each paragraph before matching:
`worth\nnoting` fails exactly as `worth noting` does. Upstream records
that the day its gate started reading paragraphs it found two phrases that
had been passing since the gate was written, each saved only by where its
line happened to break.

**Patterns** (not mechanically checkable, enforced at review):

- Announcing structure before delivering it ("There are three things to
  understand").
- Restating the question before answering it.
- A closing one-liner that restates the thesis.
- Stacked short declaratives (four or more in a row).
- Superlative self-ranking ("the most important thing", "the part that
  matters most").
- A list of `**Bold term**: explanation` pairs, which is the single most
  recognisable machine-written list. Write sentences, or a table.

## Punctuation rulings

**The em dash is spaced here**: `a dash — like this`. This is the one
place where the guide contradicts both Google and jostraca, and it is the
Voxgig convention rather than drift — 24 spaced dashes across the 26
pages when the gate was written, and not one unspaced. `Google.EmDash` is
therefore off, and `tools/check_prose.py` `em-dashes-are-spaced` enforces
the convention in the other direction: an unspaced dash fails.

Dashes stay **rationed to one aside per line**: either a single dash
before a trailing clause, or one matched pair around a parenthetical,
never both and never two asides. Three on a line is the stacking the
ration exists to stop. Prefer a comma or parentheses when the aside is
mild.

The rest:

- In a link list, separate the link from its gloss with a full stop, not a
  dash:

  ```markdown
  - [Go](go/README.md). The port; failures are returned, not thrown.
  ```

- **Every relative link must resolve, and stay inside the repository.**
  `tools/check_prose.py` checks the path, not the anchor, since a heading
  slug depends on the renderer; it reads both `[text](target)` and
  `[text][label]` with its definition. A target that resolves on a Linux
  runner but climbs out of the checkout resolves nowhere on GitHub or in a
  published package, so it fails too. Every link on the 26 pages resolved
  the day the check was written.
- No emoji in documentation.
- Sentence-style capitalisation in headings (Google style), except where
  the heading names a proper noun or a code identifier: `omni - OCaml`,
  `Lean 4`.
- British spellings (`-ise`, `-isation`) for new prose. Google style is US
  English and so is the dictionary; this is one of the places the house
  voice wins, and
  [`accept.txt`](./.vale/styles/config/vocabularies/Omni/accept.txt)
  carries the British forms — **listed one by one**, never matched by
  suffix, because `\w+ise` accepts any word ending in those three letters
  and punches a hole straight through the spelling gate. A US spelling
  already on a page is not a defect, and a filename keeps whatever
  spelling it was created with.
- Quotation punctuation goes **outside** the quotes, against US
  convention, because putting a period inside a quoted `code span` is
  actively wrong when the quote is a literal.

## Terminology

- The project is **omni**, lowercase, in prose and in every title, as its
  repository is named; the packages are `@voxgig/omni` and
  `@voxgig/omni-js` on npm, `github.com/voxgig/omni/go` as a Go module,
  and a `<port>/vX.Y.Z` tag for the other ports that release. `Omni` is
  the name of the Vale vocabulary directory, and nothing else.
- **canonical** — `typescript/src/Runner.ts` and `typescript/src/Util.ts`.
  Every other language is a **port** of them. Never "reference
  implementation"; the corpus is the reference.
- **the corpus** — `spec/fib.aon` and the `spec/fib.json` compiled from
  it. It is the **contract**: a port that disagrees with it is wrong. A
  **spec** is any JSON file in the format, yours included; the corpus is
  omni's own. Never "the test suite" for either, which is a port's own
  harness.
- **section**, **group**, **set**, **entry** — the format's nouns, in
  nesting order, as `DOCS.md` §1 defines them. Not "test case", not
  "fixture".
- **subject** — the function under test. **provider** — the optional set
  of hooks that resolves subjects, builds clients, and wraps context. A
  **client** is a `DEF.client` entry, never the consumer of the library.
- **absent** and **null** are different, and the difference is what
  `__UNDEF__` and `__NULL__` exist to spell. Say **absent** for no value
  and **null** for a JSON null. Never "undefined", which is one
  language's spelling of absent.
- **parity** — the property `tools/check_parity.py` checks: the same
  public names in every port, in local casing. Not "consistency", and not
  agreement with the corpus, which is a separate property the suites
  check.
- **variance** — a place where a language cannot express what the spec
  can, recorded in `DOCS.md` §9. Not "bug", and never fixed by diverging.
- **isolation** — omni is a test-time dependency only. A consumer wires it
  in as a `devDependency` or a local checkout, and its shipped library
  never depends on it; name the device that carries the isolation when
  you claim it.
- **struct** — `voxgig/struct`, the project whose in-situ runners omni
  replaces, written lowercase as its repository is named. Where a
  sentence could be read as Go's or Rust's keyword, write `voxgig/struct`.
- **boru** — the twenty-fourth port, held from the test sweep until its
  engine has a release, and a port all the same: its README is in the
  page set.

## Templates, part by part

**Tutorial section** (`DOCS.md` §1, when written): goal sentence →
snippet → output → the one observation → forward link. Every step's
output shown.

**How-to section** (`DOCS.md` §8): the task as a heading in imperative or
"-ing" form; one sentence of situation; the recipe; one paragraph of what
to watch for; links to the reference for the constructs.

**Reference sections** (`DOCS.md` §1–§7): definition, then behaviour,
then edge cases, then a pinned example. Every claim that has a corpus
group or a test names it.

**Explanation section** (`DOCS.md` §9): the question, the answer, the
argument, the trade-off admitted. May quote history when the history is
the argument. This is where a divergence is explained.

**Port README** (`<lang>/README.md`): the title `omni - <Language>`, the
test command, a *Use* block in that language, a *Layout* table, and
*Notes* — the port's spelling, its types, and its divergences, each
pointed at `DOCS.md` §9.

## Updating this guide

Change it the way behaviour changes: in the same commit as the first page
that follows the new rule, with the reasoning in the commit message.

To ban a phrase, add the regular expression to
[`reject.txt`](./.vale/styles/config/vocabularies/Omni/reject.txt)
and summarise it in the preceding list. Both gates pick it up from that
one file; there is no second list to update, and `tools/check_prose.py`
names this file, so a drift is a build failure with a pointer.

To change a Google rule's level, edit [`.vale.ini`](./.vale.ini) and write
down what the rule produced on a clean run. "It was noisy" is not a
reason; "it flags every heading that names a port language as not
sentence case — 34 hits, every one a proper noun" is. A rule demoted
without that note reads later as an oversight, and gets re-promoted by
someone repeating the work.

To widen what the gates read, change the configuration block at the top
of `tools/check_prose.py`. Both gates take their file set from it, so
widening it once widens both — and a page added to the repository without
being added there is a page neither gate has ever read.
