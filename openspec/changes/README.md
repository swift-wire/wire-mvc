# Proposed spec changes

A proposal that changes behaviour carries its spec deltas here, one directory per change, named in
kebab-case after the proposal:

```
openspec/changes/<change-name>/
├── proposal.md                    why, in a few lines, linking the proposal and its tracking issue
└── specs/<capability>/spec.md     the deltas against openspec/specs/<capability>/spec.md
```

`proposal.md` is short, because the argument lives in `Proposals/<Name>.md`:

```markdown
# <Change title>

## Why
<One paragraph.> Proposal: [<Name>](../../../Proposals/<Name>.md).
Tracked by <https://github.com/swift-wire/<repo>/issues/N>.

## What Changes
- <One line per behavioural change.>
```

Each delta file uses the OpenSpec headings `## ADDED Requirements`, `## MODIFIED Requirements`,
`## REMOVED Requirements` and `## RENAMED Requirements`. A MODIFIED requirement is restated in
full, under its exact existing heading. Requirements follow the same rules as the specs themselves,
including the `Pinned by:` line.

There is no `tasks.md`: the tracking issue owns the status of a change, not a file.

The implementing pull request applies the deltas and moves the change into `archive/`:

```sh
npx -y @fission-ai/openspec@1.13.2 archive <change-name> --yes
```

A change that introduces a new capability is written as ADDED requirements in
`specs/<new-capability>/spec.md`. Archiving creates the spec with a placeholder Purpose, and the
implementing pull request replaces it with a real one; strict validation fails until it does.

`archive/` is the record of what each proposal changed. CI validates every active change and checks
that it applies to the current specs (`Scripts/spec-deltas-gate.py`).
