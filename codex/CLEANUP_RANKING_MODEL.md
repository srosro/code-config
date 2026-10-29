# Cleanup ranking model

Rank is positional and changes only from evidence in the session being cleaned up. There are no counters or hidden scores.

## AGENTS.md directives

- A ranked unit is one top-level `- ` directive plus all of its indented or wrapped continuation lines.
- A unit may swap only with the immediately adjacent directive in the same `##` section.
- A unit must remain self-contained after either adjacent swap. Numbered sequences, prose, headings, and nested bullets are not ranking units.
- An up/down move affects reading priority only; every directive remains binding regardless of position.

## Core skill priorities

Every repository-owned core skill at `codex/skills/*/SKILL.md` has one `## Priority` section. It contains only top-level bullets of the form ``- `§ Exact section heading` `` plus an optional parenthetical note.

- Each pointer resolves to one `##` section in the same file; `§ Priority` cannot point to itself.
- A ranked unit is one pointer bullet. It may swap only with the immediately adjacent pointer.
- The list is an attention index, not execution order. Workflow steps stay in their semantically correct positions and ordered lists are never rearranged.
- The first pointer may be marked `*(pinned)*` for a safety or authorization boundary. A pinned pointer does not move, and another pointer cannot move across it.

## Voting operation

- `+1`: swap the evidenced item with the item immediately above it.
- `-1`: swap the evidenced item with the item immediately below it.
- At an edge, or against a pinned boundary, record no move.
- Cap changes at three items per file per cleanup, with at most one move per item.
- Evidence must show the item materially helped or hurt this session. Importance—consequence, recurrence, and cross-task breadth—selects among observed signals; it cannot create a signal.
- Contrary signals cancel unless one has clearly greater demonstrated impact; no evidence means no move.
