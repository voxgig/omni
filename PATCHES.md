# One patch to apply locally

boru is the only port with **no CI job at all**. Adding it to `LANGS` makes
`make test` cover it; it does not make CI cover it, because every job in
`.github/workflows/ci.yml` invokes an individual `make test-<port>` and there
is no boru job to invoke one. A syntax or runtime regression in the port can
merge with every required check green — which is exactly how the same port in
voxgig/struct once spent two days broken on an engine rename without anyone
noticing.

The fix is in [`patches/`](./patches) rather than committed, because it edits
`.github/workflows/`, which the authoring session's credentials are refused
on:

    ! [remote rejected] refusing to allow an OAuth App to create or update
      workflow `.github/workflows/ci.yml` without `workflow` scope

That refusal was measured, not assumed: the change was committed and pushed,
and the remote rejected the whole push.

**Delete this file and `patches/` once it is applied.** Until then, CI does
not run the boru suite at all.

## `patches/boru-ci-REQUIRED.patch`

    git am patches/boru-ci-REQUIRED.patch

(or `git apply` it and commit yourself — the message is in the patch header.)

It adds one `boru` job: check out the repo, check out `boru-lang/boru` at a
pinned commit, build the CLI, run `make test-boru`.

### Why the engine is pinned to a commit

boru has no release channel of any kind: no tags, no published binaries, and
no `go install` — `cmd/go` is a module of its own whose `go.mod` carries
`replace` directives into sibling modules, which `go install` refuses
outright (*"the go.mod file for the module providing named packages contains
one or more replace directives"*). A commit is the only reproducible version
there is, and pinning it is the same argument `STRUCT_REF` already makes:
unpinned, a green run is not reproducible from this repo's commit alone.

`8181f78fae7cd335ae3a3513507c7474b5f03663` is the engine everything below was
measured on. Its full hash came from the Go module proxy's own record of the
commit (`.info`, `Origin.Hash`), not from expanding a short one.

### Verified locally, on that engine

`make test-boru BORU=$RUNNER_TEMP/boru` is the exact command the job runs.
Here, with the same target: **26 passed, 0 failed**.

The job's own steps are not verified — they cannot be, from here. What is
verified is the command they run.
