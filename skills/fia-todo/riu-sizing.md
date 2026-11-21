# Sizing an issue: Reach, Interface, Uncertainty

The fallback sizing method, for a repository with no `SIZING.md` at its
root. Every issue gets exactly one of `size:XS`, `size:S`, `size:M`,
`size:L` and `size:XL`. The size measures the **scope and risk of the
change**, not time, because an agent builds it. Size from the settled
decisions, the Tasks and the Definition of done the issue will carry.

## 1. Text only is `size:XS`

If the change is text only, the size is `size:XS` and you stop: user-facing
messages, log messages, comments, docs, or any other text whose change alters
no behaviour. Any number of files, with the tests and golden files that pin
the text updated to match.

A text-only change stays `size:XS` even when it spans several areas. Text
that something parses is not text only: a marker another program reads, a
JSON key, a heading or field read back by code, or a label name. Changing it
changes behaviour, so size it with the score below.

## 2. Score Reach, Interface and Uncertainty, 0–3 each

**Reach (R)** counts the areas of the repository the change touches. An area
is one top-level unit of code: a top-level code directory, a package or
module, or a service. These are never areas and never count:

- tests (test files, test directories, fixtures, golden files);
- docs (`*.md`, a docs directory, ADRs) and agent or workflow notes;
- dependency manifests and lock files, `.gitignore`, sample env files and
  helper scripts.

Build and deploy files that ship the product (a Dockerfile, CI workflows,
infrastructure code) count as one area each.

- A change touches an area when it adds, edits, deletes or renames a
  counted file in it whose change is not text only. A file touched only for
  its help text, a comment or a message does not count. A rename between
  two areas touches both.
- A new top-level code directory, package or service is a new area.
- Forecast R from the Tasks. When it is unclear where code will live,
  count the area that holds the code it extends.

| R | Areas touched |
|---|---|
| 0 | none |
| 1 | 1 |
| 2 | 2–3 |
| 3 | 4 or more |

**Interface (I)** counts the markers the change has. Each of these is one
marker:

- a public API added, removed or reshaped: an exported function, type or
  endpoint other code or other teams call;
- a CLI command, flag, output format or exit code added, removed or
  reshaped;
- a new config option, or a new secret;
- a schema change or a data migration;
- an ADR.

A marker changes the interface's shape. A new default value, new wording
or a new printed value in an existing output is not a marker. Two new
secrets are two markers.

| I | Markers |
|---|---|
| 0 | none |
| 1 | one |
| 2 | two |
| 3 | three or more, or a new kind of component the rest of the system plugs into |

**Uncertainty (U)** is what is still unknown once the interview has settled
the decisions:

| U | Still unknown |
|---|---|
| 0 | nothing: the code to change is known, and so is a bug's cause |
| 1 | the code is known, but an outside system's behaviour has to be probed: an external API, service, runner or tool |
| 2 | a bug's cause is unknown, or the code to change has to be found first |
| 3 | a design choice the interview could not settle, or not knowing yet whether it can be done |

## 3. Add the scores and map them

| R + I + U | Size |
|---|---|
| 0–2 | `size:S` |
| 3–4 | `size:M` |
| 5–6 | `size:L` |
| 7–9 | `size:XL` |

If I is 1 or more, or U is 3, the size is at least `size:L`.

Rules:

- Every size, XL included, is one issue built in one PR or MR. Never split
  an issue or propose an umbrella because of its size.
- A docs update that follows a behaviour change adds no points.
- The size is independent of the type: a Bug can be `size:XL` and a Task
  `size:M`.
- Propose the size with a one-line reason that shows the score and names
  the areas and markers ("`size:L`: R2 I1 U1 = 4, raised to L by I1; `api`,
  `worker`; new config option `retry_limit`"). The user confirms or changes
  it before the issue is filed.
