# Specifications

This directory holds the behavioural specification of this package: what the code does today,
stated as requirements with scenarios, each pinned to the test, golden file or fixture that
measures it. It follows the [OpenSpec](https://github.com/Fission-AI/OpenSpec) layout, one
capability per `specs/<capability>/spec.md`, so the OpenSpec tooling validates it unchanged:

```sh
npx -y @fission-ai/openspec@1.13.2 validate --all --strict
python3 Scripts/spec-pins-gate.py
python3 Scripts/spec-deltas-gate.py
```

The second command checks that every path a spec pins to exists, and that every test, golden case
or job it names occurs in the file named. The third applies every proposed change to a scratch
copy of the specs and fails if one does not apply. CI runs all three in the `Specifications` job.

Three kinds of document already exist here and this one does not replace them. The DocC catalog
says how to use a feature. `Documentation/Notes/` says why a design is what it is.
`Proposals/` says what comes next. A spec says what the code does now. Where a spec and a Note
disagree, the spec is the checked claim and the Note is the historical record.

Two lines are added to the OpenSpec shape. Each spec's Purpose is followed by `Rationale:` and
`Documentation:` links to the Notes, Proposals and DocC articles that cover the capability. Each
requirement ends with `Pinned by:` naming the test that measures it; `Pinned by: nothing yet.` marks
a claim that is true of the source but not yet under test.

A contract another repository in the wire family builds on is specified here once, in the
repository that provides it. Consuming repositories link to it by URL rather than restating it.

Specs change through the proposals process, using OpenSpec's own change layout. A proposal that
changes behaviour lands `Proposals/<Name>.md`, which carries the argument, together with
`openspec/changes/<change-name>/`, which carries the spec deltas. [changes/README.md](changes/README.md)
describes the shape. The implementing pull request applies the deltas with `openspec archive`, which
updates `specs/` and moves the change into `changes/archive/`. The tracking issue owns the status
of a change, not any file in this directory.
