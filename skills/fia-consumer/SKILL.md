---
name: fia-consumer
description: Drains the `Ready` column of the GitHub Project named by the target repository's `github_project` setting, unattended. It takes the top issue of the column, runs it through `/fia-conductor`, then runs `/fia-outer-loop` on what that run went through, approving every finding and taking every recommendation of the `/fia-todo` interviews, and goes back for the next top issue until the column is empty. No arguments. Use when the operator invokes `/fia-consumer`, or asks to "consume the Ready column", "work the board" or "drain the Ready issues".
---

# fia-consumer: work the board's Ready column, one issue at a time

You are the operator of the Factory on the target repository, and the run is
unattended. The board decides the queue: the top issue of its `Ready` column
goes next. `fia-conductor` takes each issue to merge, and `fia-outer-loop`
files what that run taught. You answer every question they would put to the
operator yourself (see "Answering for the operator").

## Target and board

In the commands below, `$SCRATCH` is the session scratchpad directory named
in your system prompt. Shell state does not persist between Bash calls, so
set `SCRATCH=<that path>` and run `. "$SCRATCH/forge.env"` at the start of
every command that uses the forge.

Before the first action, derive the target from the `origin` remote of the
current directory. This never prints the remote URL, which can hold a
credential:

```sh
u=$(git remote get-url origin) || { echo "no origin remote: run from a clone of the target repository"; exit 1; }
case $u in
  *://*) u=${u#*://}; u=${u#*@}; HOST=${u%%/*}; HOST=${HOST%%:*}; REPO=${u#*/} ;;
  *)     u=${u#*@}; HOST=${u%%:*}; REPO=${u#*:} ;;
esac
REPO=${REPO%/}; REPO=${REPO%.git}
if [ "$HOST" = github.com ]; then FORGE=github; else FORGE=gitlab; fi
PROJECT_ENC=$(printf '%s' "$REPO" | sed 's#/#%2F#g')
printf 'FORGE=%s\nHOST=%s\nREPO=%s\nPROJECT_ENC=%s\nexport GITLAB_HOST=%s\n' \
  "$FORGE" "$HOST" "$REPO" "$PROJECT_ENC" "$HOST" > "$SCRATCH/forge.env"
cat "$SCRATCH/forge.env"
case $FORGE in
  github) gh auth status --hostname github.com >/dev/null 2>&1 ;;
  gitlab) glab auth status --hostname "$HOST" >/dev/null 2>&1 ;;
esac && echo authenticated || echo "not authenticated on $HOST"
```

If the check says `not authenticated`, stop with that message and leave
`gh auth login` to the operator. `github_project` names a GitHub Project,
and the Factory ignores it on GitLab: when `FORGE` is `gitlab`, stop with
`fia-consumer works from a GitHub Project; this target is on GitLab`.

Then read the setting the way the Factory does: `FIA_GITHUB_PROJECT` when it
is set, otherwise the `github_project` key of `.fia.yaml` at the repository
root:

```sh
P=${FIA_GITHUB_PROJECT:-$(sed -n -E 's/^github_project:[[:space:]]*["'\'']?([^"'\''#[:space:]]+).*/\1/p' .fia.yaml 2>/dev/null | head -1)}
P=${P%/}; P=${P%/views/*}
case $P in
  https://github.com/orgs/*/projects/*) OWNER=${P#https://github.com/orgs/}; OWNER=${OWNER%%/*}; NUMBER=${P##*/} ;;
  *) echo "github_project must be https://github.com/orgs/<org>/projects/<number>: ${P:-unset}"; exit 1 ;;
esac
case $NUMBER in ''|*[!0-9]*) echo "github_project must end in a project number: $P"; exit 1 ;; esac
printf 'BOARD_OWNER=%s\nBOARD_NUMBER=%s\n' "$OWNER" "$NUMBER" >> "$SCRATCH/forge.env"
gh project field-list "$NUMBER" --owner "$OWNER" --format json \
  | jq -r '.fields[] | select(.name=="Status") | .options[].name'
```

Stop with the script's message when the setting is unset or malformed. The
last command lists the `Status` options: if it fails, the token lacks the
`read:project` scope (`gh auth refresh -s read:project`, which the operator
runs); if `Ready` is not among the options, stop and name the options it
printed.

### Read the Ready column

```sh
. "$SCRATCH/forge.env"
gh project item-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --limit 1000 --format json > "$SCRATCH/board.json"
jq -r --arg repo "$REPO" '.items[]
  | select(.status == "Ready" and .content.type == "Issue" and .content.repository == $repo)
  | "\(.content.number)\t\(.content.title)"' "$SCRATCH/board.json"
```

`item-list` returns the items in the board's own order, so the first line is
the top of the column. A Project can hold the cards of several repositories:
the column's cards of other repositories, its pull requests and its draft
issues are not this run's. Leave them where they are and count them for the
final report.

## Worklog and state

Write to the worklog `fia-conductor` keeps (`.audit/factory-ops-<date>.tsv`,
with its columns and its `wl` helper), with the phases `board`,
`outer-loop` and `exit` for your own rows: one `board` row per pick or empty
read, with the board URL as evidence, and one `outer-loop` row per finding
with its outcome.

Keep the issues this run has handled in `$SCRATCH/consumer-handled.txt`, one
number per line, and the outcome of each in `$SCRATCH/consumer-report.tsv`
(issue, conductor outcome, PR, findings filed). The conversation grows long
over many issues, so these files are the run's memory: read them back at
every pick.

## The loop

### 1. Pick

Read the Ready column. The pick is its first issue whose number is not in
`consumer-handled.txt`. When there is none, the column is empty for this run:
go to "Final report". Add the pick to `consumer-handled.txt` before anything
else, so an issue that `fia-conductor` skips and leaves in `Ready` is never
picked twice.

### 2. Run it through the Factory

Invoke `fia:fia-conductor` with the argument `#<n>`. Follow it through to its
final report: it takes the issue and its follow-ups to merge or to a logged
skip. The Factory moves the card as its labels change, so a handled issue
normally leaves `Ready` by itself.

Record the conductor's outcome for the issue in `consumer-report.tsv`.

### 3. Learn from it

Invoke `fia-outer-loop`, a project skill of the Factory's repository. Its
source is this conversation: scope it to what happened since the start of
step 2 for this issue, so a finding filed after an earlier issue is not
filed again. Follow it through to its report, answering for the operator as
the next section says.

When `fia-outer-loop` is not among your skills (the target is a tenant
whose checkout has no such skill), log one `outer-loop` row saying so on the
first issue, skip this step for the rest of the run, and say it in the final
report.

### 4. Next

Go to step 1.

## Answering for the operator

`fia-conductor` already runs unattended. `fia-outer-loop` and `fia-todo`
are written for an operator at the keyboard: wherever they would call
`AskUserQuestion` or stop to wait for an answer, you give the answer
yourself and carry on in the same turn.

- **`fia-outer-loop`, "Ask which to fix"**: approve every finding, each with
  the option it offers: file the fix; comment the evidence on the existing
  issue; file the follow-up investigation of an `unresolved` finding; file
  the `doc/TROUBLESHOOTING.md` entry of an environment finding. An
  environment finding's operator action is not yours to take: list it in the
  final report.
- **`fia-todo`, every interview round**: answer each question with its ➡️
  recommendation, the merge question included. A question with no
  recommendation takes the answer you would recommend from the findings.
  This replaces `fia-outer-loop`'s rule that its own research must not
  answer `fia-todo`: the recommendations come from `fia-todo`'s research.
- **`fia-todo`, closing the interview and the draft**: confirm the summary of
  decisions, and approve the draft as presented (step 7).

Log each answer you give as a `default` row in the worklog, as
`fia-conductor` does for its own defaults (`fia-todo <repo>: Q3 took the
recommendation`).

The rules of `fia-conductor` hold for the whole run, step 3 included:
never ask the operator anything, and an action they forbid is logged as
`skip` and the loop goes on.

## Final report

One table, from `consumer-report.tsv`: issue, title, the conductor's outcome
(merged with its PR, or skipped with the reason), and the issues filed or
commented on by `fia-outer-loop` for it. Then list the Ready cards left
alone (other repositories, pull requests, draft issues), the environment
actions handed to the operator, whether `fia-outer-loop` was unavailable,
and the worklog's path. Each `fia-conductor` run already reported its
defaults; point to the worklog for them rather than repeating them.
