# Consuming omni by git ref

Whether omni's twenty-one non-Node ports should publish git refs a consumer
can pin, instead of requiring a local checkout.

Every ecosystem claim below was checked against that ecosystem's own tooling
or source and, where the repo could answer, against the live registry. Claims
marked *measured* were produced by running the command shown.

Status: **DECISION NEEDED**, and deliberately split in two — the first half is
owed regardless of the answer.


## The question

omni has twenty-three ports. Two of them, `typescript` and `javascript`, are
on npm: a consumer writes `"@voxgig/omni": "^0.1.1"` in `devDependencies` and
gets a versioned, pinnable artifact with provenance.

The other twenty-one have nothing of the sort. Their only supported route is a
local sibling checkout resolved from `$OMNI_HOME`, wired per language with
gitignored links — `go.work`, `vendor/omni`, `-p:OmniPath=`, `.omni-runner`,
`pubspec_overrides.yaml`. That is DOCS §8.3, and it is what all ten sekreto
ports and all twenty-two migrated struct ports use today.

A git ref would let those ports be pinned the way the npm pair can be:

    voxgig_omni = { git = "https://github.com/voxgig/omni", tag = "rust/v0.1.0" }

Two things stand in the way, and they are unrelated to each other.


## Blocker 1 — it collides with how register 4.13 is *proved*

4.13 is the rule "nothing a port's **library** build may name omni." Fourteen
ports each answered it differently, and the register's conclusion is that
"there is no portable mechanism, only a portable *rule* … and CI must prove it
with the checkout absent."

That sentence contains a seam:

| | is about | holds when |
|---|---|---|
| the **rule** | *declaration* — does the manifest name omni? | always |
| the **proof** | *resolution* — can the build find omni? | only while omni is unfindable |

Several mechanisms work purely by absence — swift's `.omni-runner` symlink
("no link, no dependency declared"), dart's generated `pubspec_overrides.yaml`,
go's `go.work`, rust's `../.omni` link. For those, a checkout-absent CI run
proves something only because there is nothing else to resolve. Publish a ref
and the run goes green while proving nothing.

**For Go that has already happened, and needs no decision from us.** *Measured*,
in a scratch module with no omni checkout anywhere on the machine:

    $ go mod tidy
    go: finding module for package github.com/voxgig/omni/go/compat/struct
    go: found … in github.com/voxgig/omni/go v0.0.0-20260825220049-74ae081d405a

    $ cat go.mod
    require github.com/voxgig/omni/go v0.0.0-20260825220049-74ae081d405a

No tags were involved. Go synthesised a pseudo-version from `main`'s tip
because omni is a public repo and `proxy.golang.org` serves it automatically.
This is the struct#89 bug — the one that opened 4.13 — still reproducible.

So refs do not *create* the Go hole. They would make an already-open one look
endorsed.


## Blocker 2 — no single tag namespace satisfies every ecosystem

Two constraints are irreconcilable inside one repository.

**Go demands a directory prefix.** A module at `go/` can only be released as
`go/v1.2.3`; the subdirectory is a mandatory tag prefix. *Measured* — asking
the proxy for the unprefixed version says so outright:

    $ curl https://proxy.golang.org/github.com/voxgig/omni/go/@v/v1.2.3.info
    not found: …: invalid version: unknown revision go/v1.2.3

**SwiftPM can accept no prefix, and cannot see the package at all.** It parses
tags by stripping exactly one leading `v` and then requiring semver, so
`swift/v1.2.3` is rejected; only `1.2.3` or `v1.2.3` resolve. Worse, a
source-control dependency always loads the manifest from the *repository root*
— `loadManifest` hard-codes `packagePath: .root`, and no `.package(...)`
overload takes a subdirectory in any tools version. Serving `omni/swift` by git
ref would require a `Package.swift` at `/`, making the whole polyglot monorepo
"a Swift package" for every consumer of every other language.

Only one ecosystem can own the unprefixed tag namespace. The rest are
permissive and will follow whatever is chosen:

| ecosystem | subdirectory package | tag naming | pin with no tag |
|---|---|---|---|
| Go | yes, first-class | **must** be `go/vX.Y.Z` | yes — pseudo-version |
| SwiftPM | **no**, root only | **must** be `1.2.3` / `v1.2.3` | yes — `.revision` / `.branch` |
| Clojure | yes, `:deps/root` | none — any real tag | yes — full 40-char `:git/sha` |
| Cargo | yes, traverses the tree by crate name | none | yes — `rev` |
| pub (Dart) | yes, `path:` under `git:` | none | yes — `ref:` |
| Lake (Lean) | yes, `subDir` | none | yes — `rev` |

Two corrections worth keeping, because both invert an assumption that looks
safe:

- **Cargo needs no repo-root cooperation.** It traverses the whole repository
  to find a crate by name, so `rust/` is reachable today with no root
  manifest. Adding a root `[workspace]` is the *riskier* move, not the
  enabling one — it relocates `Cargo.lock` and `target/`, and changes what
  `cd rust && cargo test` does.
- **Go tags are not reachability-checked.** `(*gitRepo).Tags` filters
  `git ls-remote` output by string prefix with no ancestry test, so a
  `go/v1.0.0` pushed from a branch that is later abandoned still publishes as
  the module's highest release. The proxy and checksum database then cache it
  immutably, and a retag surfaces to users as a security error. Withdrawal is
  only via `retract` in a new version, never by deleting a tag.


## The decision, split

**First, and owed regardless: make 4.13's proof declaration-based.** Replace
every absence-based guard with an assertion about the manifest and the
resolved dependency graph, in the shape of struct's
`typescript/tools/omni-isolation.js`. The Go demonstration above means this is
due now; it is not contingent on any publishing decision, and doing it first
means the ref question can be answered on its merits instead of on whether it
breaks CI.

**Then decide refs per ecosystem, not repo-wide.** Go, Clojure, Cargo, pub and
Lake can all be served with directory-prefixed tags, which is the shape the
repo already uses — `typescript/v0.1.1` and `javascript/v0.1.1` exist and are
Go-compatible by construction. SwiftPM is a genuine hard no without moving a
`Package.swift` to the repository root, and the honest answer there may simply
be that swift stays checkout-only.

What this document does **not** decide: whether any port should publish at all.
That is a separate call, and nothing here forces it.
