---
name: fia-conductor
description: Operates the Factory on the repository of the current directory (GitHub or GitLab, read from the `origin` remote) issue by issue. For each issue it adds the trigger label, waits for the plan, approves it, waits for the PR or MR, fixes its CI until it is green, merges it, runs the `class:follow-up` issues that the implementation filed through the same process, and moves on. When the cause of a failure is the Factory itself, it fixes the Factory first and retries when the repository is the Factory's own, and files a Bug on the Factory's repository otherwise. Takes a list of issues (`#22 #25 31`), a label (`label:<name>`, every open issue with it, oldest first) or a maximum size (`max:M`, the default). Keeps a TSV worklog in `.audit/`. Use when the operator invokes `/fia-conductor`, or asks to "run the factory on the backlog", "implement the open issues up to size S", "drain the issues", "shepherd issue #N through the factory", or "operate the factory".
argument-hint: "[#<issue> [#<issue> ...] | label:<name> | max:<XS|S|M|L|XL>]"
---

# fia-conductor: run issues through the Factory, one at a time

You are the operator of the Factory on the target repository. The Factory
does the work: it plans, builds and opens the PR (MR on GitLab). Your job is
to trigger it, watch it, fix what breaks, merge, and go on to the next issue.
Work on one issue at a time, from start to merge.

## Target and forge

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

github.com is GitHub, through `gh -R "$REPO"`. Any other host is GitLab,
through `glab api` with `GITLAB_HOST` set to the host and the project path
URL-encoded in `PROJECT_ENC`. If the check says `not authenticated`, stop
with that message and leave `gh auth login` or
`glab auth login --hostname <host>` to the operator.

### The Factory's repository

Then derive the repository the Factory itself lives in, and append it to
`forge.env`:

- **GitHub**: the `uses: <owner>/<repo>@<ref>` line of the step that handles
  the event in `.github/workflows/factory.yml`:

  ```sh
  sed -n -E 's#^[[:space:]-]*uses:[[:space:]]*([^/@[:space:]]+/[^/@[:space:]]+)@.*#\1#p' \
    .github/workflows/factory.yml | grep -v '^actions/'
  ```
- **GitLab**: the `org.opencontainers.image.source` label of the image the
  `factory` job runs. The job is in `.gitlab/factory-ci.yml`, or in
  `.gitlab-ci.yml` when the project has no such file. When its `image:`
  names the project's own derived image (`$CI_REGISTRY_IMAGE/...`), read the
  `FROM` image of `factory.Dockerfile` instead:

  ```sh
  f=.gitlab/factory-ci.yml; [ -f "$f" ] || f=.gitlab-ci.yml
  sed -n -E '/^factory:/,/^[^[:space:]#]/s/^[[:space:]]+(image|name):[[:space:]]*"?([^"[:space:]]+)"?.*/\2/p' "$f" | head -1
  sed -n -E 's/^FROM[[:space:]]+([^[:space:]]+).*/\1/p' factory.Dockerfile | head -1
  docker buildx imagetools inspect "<image>" \
    --format '{{index .Image.Config.Labels "org.opencontainers.image.source"}}'
  ```

  The label is a URL such as `https://github.com/<owner>/<repo>`.

Write `FACTORY_HOST` and `FACTORY_REPO` into `forge.env` and log them in the
`start` row. `SELF` is `yes` when `FACTORY_HOST` and `FACTORY_REPO` equal
`HOST` and `REPO`: the run operates the Factory on its own repository.
Otherwise the target is a tenant. If the Factory's repository cannot be
derived, stop with a message that names the file or the command that failed.

### Forge operations

The steps below name an operation from this table. Run the column of
`$FORGE`. In the table, `\|` is a plain shell `|`. `<n>` is an issue
number, `<mr>` a PR or MR number. On GitLab, send every JSON body as a file
with `--input <file> -H 'Content-Type: application/json'`, and test the
exit code of a `glab api` call, not whether its output is empty: a failed
call prints its error JSON on stdout.

| Operation | GitHub | GitLab |
|---|---|---|
| list open issues, oldest first | `gh issue list -R "$REPO" --state open --limit 200 --json number,title,labels,createdAt --jq 'sort_by(.createdAt)[] \| "\(.number)\t\([.labels[].name]\|join(","))\t\(.title)"'` | `glab api --paginate "projects/$PROJECT_ENC/issues?state=opened&order_by=created_at&sort=asc&per_page=100" \| jq -r '.[] \| "\(.iid)\t\(.labels\|join(","))\t\(.title)"'` |
| list open issues with label `<name>` | the same, with `--label "<name>"` | the same, with `&labels=<name, URL-encoded>` |
| list label names | `gh label list -R "$REPO" --limit 200 --json name --jq '.[].name'` | `glab api "projects/$PROJECT_ENC/labels?per_page=100" \| jq -r '.[].name'` |
| read an issue | `gh issue view <n> -R "$REPO" --json number,state,title,body,comments,labels` (always pass `--json`: without it `gh issue view` can fail with a Projects classic error) | `glab api "projects/$PROJECT_ENC/issues/<n>"`, and its comments: `glab api "projects/$PROJECT_ENC/issues/<n>/notes?per_page=100&sort=asc" \| jq '[.[] \| select(.system \| not) \| {id, author: .author.username, body}]'` |
| add label `<l>` / remove label `<l>` | `gh issue edit <n> -R "$REPO" --add-label "<l>"` / `--remove-label "<l>"` | `glab api --method PUT "projects/$PROJECT_ENC/issues/<n>"` with `{"add_labels": "<l>"}` / `{"remove_labels": "<l>"}` |
| comment on an issue | `gh issue comment <n> -R "$REPO" --body "<text>"` | `glab api --method POST "projects/$PROJECT_ENC/issues/<n>/notes"` with `{"body": "<text>"}` |
| close an issue | `gh issue close <n> -R "$REPO" --comment "<text>"` | comment, then `glab api --method PUT "projects/$PROJECT_ENC/issues/<n>"` with `{"state_event": "close"}` |
| read a plan | the secret gist the plan comment links: `gh gist view <id> --raw` | the project snippet the plan comment links: `glab api "projects/$PROJECT_ENC/snippets/<id>/raw"` |
| find the Factory run of an issue | `gh run list -R "$REPO" --workflow factory.yml --limit 5 --json databaseId,status,conclusion,event,displayTitle`: the newest `in_progress` or `queued` run whose title is the issue's title | the newest `🏭 Factory pipeline started: <url>` comment on the issue posted after your action; the pipeline id ends the URL. Trigger pipelines: `glab api "projects/$PROJECT_ENC/pipelines?source=trigger&per_page=5"` |
| wait for a run (background) | `gh run watch <id> -R "$REPO" --interval 30` | a loop that re-reads `glab api "projects/$PROJECT_ENC/pipelines/<id>" \| jq -r .status` every 30 seconds until it is `success`, `failed`, `canceled` or `skipped` |
| a run's jobs | `gh run view <id> -R "$REPO" --json conclusion,jobs` | `glab api "projects/$PROJECT_ENC/pipelines/<id>/jobs" \| jq '[.[] \| {id, name, stage, status}]'` |
| a job's log | `gh api "repos/$REPO/actions/jobs/<job-id>/logs"` (`gh run view --log-failed` can fail with a permission error on its cache) | `glab api "projects/$PROJECT_ENC/jobs/<job-id>/trace"` |
| open PR or MR of a branch | `gh pr list -R "$REPO" --state open --head <branch> --json number,url,title` | `glab api "projects/$PROJECT_ENC/merge_requests?state=opened&source_branch=<branch, URL-encoded>" \| jq '[.[] \| {number: .iid, url: .web_url, title}]'` |
| the CI runs of a PR or MR | `gh run list -R "$REPO" --branch <branch> --limit 3 --json databaseId,workflowName,status,conclusion,headSha` | `glab api "projects/$PROJECT_ENC/merge_requests/<mr>/pipelines" \| jq '[.[] \| {id, status, sha}]'` |
| merge a PR or MR | `gh pr merge <mr> -R "$REPO" --merge` | `glab mr merge <mr> -R "$REPO" --yes --auto-merge=false` |
| read a PR or MR | `gh pr view <mr> -R "$REPO" --json state,mergedAt,body,mergeCommit` | `glab api "projects/$PROJECT_ENC/merge_requests/<mr>" \| jq '{state, merged_at, body: .description, merge_commit_sha}'` (`state` is `merged` once merged) |
| close a PR or MR | `gh pr close <mr> -R "$REPO" --comment "<text>"` | comment with `glab api --method POST "projects/$PROJECT_ENC/merge_requests/<mr>/notes"`, then `glab api --method PUT "projects/$PROJECT_ENC/merge_requests/<mr>"` with `{"state_event": "close"}` |
| default branch | `gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name` | `glab api "projects/$PROJECT_ENC" \| jq -r .default_branch` |

On GitLab the run is a pipeline with the source `trigger` and the job
`factory`. Every issue event and every comment starts one, and most end in
`Nothing to do`, so identify yours by the `🏭 Factory pipeline started`
comment. Comments that command the Factory must come from the operator's
own account, not the Factory's bot token. GitLab files follow-ups as Tasks
(work items with `issue_type` `task`); the issue list operations include
them.

If labelling an issue starts no run, or a `/factory` comment starts none,
read the Factory's troubleshooting doc ("Labelling an issue on GitLab starts
no pipeline", "A `/factory` comment on GitLab starts no pipeline" and their
GitHub twins) before you invent a workaround.

## Input

The argument chooses the queue:

| Argument | Queue |
|---|---|
| a list of issues: `#N`, `N`, or several separated by spaces or commas (`#22 #25 31`, `22,25,31`) | only those issues, in the order given, whatever their size. Exit after the last one is merged or skipped. |
| `label:<name>` | every open issue that has the label `<name>`, oldest first, whatever their size. Quote a name with spaces: `label:"needs work"`. Exit when no open issue with the label is left to pick. |
| `max:<size>` | every open issue whose `size:*` label is at most `<size>`, oldest first. The order is XS < S < M < L < XL. |
| none | the same as `max:M`. |

With `max:<size>`, leave out open issues that have no `size:*` label and say
so in the final report. With `label:<name>`, check first that the label
exists ("list label names"); if it does not, log it and exit. Re-read the
labelled issues at every pick, so an issue that gets the label during the
run joins the queue, and one that loses it leaves. An issue skipped or
stopped in this run is not picked again. With a list, drop duplicates, and
log and skip any issue that is closed or does not exist. Never pick an issue
that already has `factory:running` or an open PR or MR from
`factory/issue-N`: someone else is working on it. Log it and skip it.

Every issue in the queue brings its follow-ups with it: after it is merged,
the `class:follow-up` issues the Factory filed for it run next, one by one,
before the next issue of the queue (step 7). They run whatever their size
and whatever their labels.

## Answering questions

The operator answers questions only in the invocation and in their messages
during the run (`#25 Q2: use JSON`, `for #31 keep the old flag`). Any
question the operator said nothing about takes its default, and the run goes
on without asking:

- A plan's open question takes the plan's `Recommendation:`.
- A plan reviewer's point takes the fix the reviewer suggests, or the
  plan's recommendation when the point is an open question.
- An issue that offers options takes the one it marks as recommended or
  default. A `fia` option takes the default the Factory documents (the
  generated option comments in the repository's Factory workflow or pipeline
  file name each one).
- A CLI design question takes the answer that best follows the target
  repository's documented CLI conventions, and otherwise the conventions of
  `glab`, `gh`, `git` and `docker`.

What the operator said always wins over a default, and what the issue
settles wins over a recommendation that contradicts it. Log every default
you take as a `default` row whose `decision` names the issue and the question
(`#25: Q2 took the recommendation`) and whose `evidence` quotes the answer
in one line, and list them in the final report so the operator can review
them after the run.

The run is unattended: never ask the operator anything and never wait for
an answer or an approval. When a question has no default (no
recommendation, no suggested fix and no default in the issue or the
documents), decide it yourself: take the answer you would recommend, the
one that best follows the issue's goals and the repository's `CLAUDE.md` or
`AGENTS.md`, and log it as a `default` row like any other.

## Worklog

Before the first action, create `.audit/factory-ops-<YYYY-MM-DD>.tsv` (the
UTC date) in the target repository. If the file already exists, append to
it. Its columns:

```
ts	phase	decision	why	evidence	result
```

- `ts`: UTC, `date -u +%FT%TZ`.
- `phase`: `start`, `pick`, `trigger`, `plan`, `default`, `approve`,
  `build`, `ci`, `diagnose`, `fix`, `merge`, `image`, `followup`,
  `factory-fix`, `skip`, `exit`.
- `decision`: what you did, prefixed with the issue or PR (`#25: added
  factory:start`, `PR #32: pushed fix 833cc20`, `!32` for an MR).
- `why`: the reason in one clause.
- `evidence`: run IDs, pipeline IDs, job IDs, URLs, the error line, the
  commands' results.
- `result`: what came of it (`run 42117460110 started`, `green`, `merged`).

Write one row for every action and every observation that changes what you
do next. Strip tabs and newlines from the values. Never write a secret into
a row. A helper that appends a row:

```sh
wl() { f=.audit/factory-ops-$(date -u +%F).tsv; [ -f "$f" ] || printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n' > "$f"
       printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$@" >> "$f"; }
```

Shell state does not persist between Bash calls, so define the helper again
in each call that uses it, or save it as a script in the scratchpad.

The worklog stays uncommitted on the default branch: the operator decides
where it goes. If the run opens a Factory-fix PR (below), commit the worklog
on that PR's branch too.

## The loop

Repeat these steps for each issue in the queue. Run every long wait as a
background command (`run_in_background: true`) and end the turn. The
notification wakes you. Never poll with `sleep` in the foreground.

### 1. Pick

List the queue with "list open issues, oldest first", or with `label:<name>`
"list open issues with label `<name>`". Take the next issue in the queue:
the next one in the list, or with `label:<name>` or `max:<size>` the oldest
one left. Read its body and comments ("read an issue").

### 2. Trigger and wait for the plan

1. Add the label `factory:start` ("add label").
2. Find the run ("find the Factory run of an issue"). Every label edit
   starts a run, and most of them are skipped or end in `Nothing to do`.
3. In the background, wait for it ("wait for a run"), then read the run's
   conclusion and the issue's labels and comments.

Read the outcome from the issue:
- `:clipboard: Plan (APPROVED, …)` and the label `factory:awaiting-input`:
  read the plan's `## Open Questions` ("read a plan"). When the operator
  answered none of them, or answered each the way its `Recommendation:`
  does, go to step 3: the coder follows the recommendations. When the
  operator gave a different answer to one, comment `/factory replan` with
  one line per answered question (`Q<n>: <answer>`), log it, watch the run
  as in this step, and read the outcome again. The questions the operator
  did not answer keep their recommendations (see "Answering questions").
- `Plan (NOT_APPROVED, …)`: read the plan's open questions and the
  reviewer's points. Answer each one from, in this order, the operator's
  words, the issue, and the default ("Answering questions"). When every
  answer matches what the plan already does, approve anyway (step 3).
  Otherwise comment `/factory replan` with the answers (`Q<n>: <answer>`
  for an open question, one line per reviewer point) and watch the run as
  in this step. A point with no default takes your own recommendation
  ("Answering questions").
- No awaiting-input label, and a build already started (the repository's
  `plan_approval_required` is not `always`): skip step 3.
- `factory:error`, or a failed run: go to "When the Factory fails".

### 3. Approve

Comment `/factory approve` on the issue. Find the new run as in step 2 and
watch it in the background.

### 4. Wait for the PR or MR

When the build run ends, look up "open PR or MR of a branch" for
`factory/issue-N`.

A green build run with no PR or MR, or `factory:error`, means the Factory
failed: go to "When the Factory fails".

### 5. Get the CI green

Find the PR's or MR's CI runs ("the CI runs of a PR or MR") and watch the
newest in the background. Read its jobs ("a run's jobs"). The repository's
CI decides which jobs run and in what order. A job that fails may skip the
ones after it.

When a job fails:

1. Read its log ("a job's log") and keep the failing lines, for example
   with `grep -E 'FAIL|error|panic' | head -60`.
2. Check out the branch: `git fetch -q origin && git switch -c factory/issue-N --track origin/factory/issue-N`,
   or `git switch factory/issue-N && git pull` if you already have it.
3. Reproduce the failure locally with the narrowest command the
   repository's test setup allows (in a Go repository, for example,
   `go test ./<pkg>/ -run TestName -count=1 -v`). Find the root cause. Do
   not weaken an assertion to get green. If the test is right and the code
   is wrong, fix the code. Make sure the fix matches the issue's decisions
   and acceptance tests.
4. Run the repository's own test commands, as its `CLAUDE.md` or
   `AGENTS.md` gives them, up to the level the failure is at, with any
   coverage or report files written to the scratchpad. A level that needs a
   secret runs locally only when the failure is in it, with the secret
   loaded the way the repository's docs say, into that one command.
   Otherwise CI runs it.
5. Check that `git branch --show-current` prints `factory/issue-N`. The
   operator switches branches during a session. Then make one conventional
   commit (`fix: …` or `fix(test): …`) whose body says what failed and why,
   ending with the attribution line from the system prompt. Push with an
   explicit refspec: `git push origin factory/issue-N:factory/issue-N`.
6. Watch the new CI run. Repeat until every job passes.

If the same job fails three times for different reasons, or the fix would
change the issue's decisions, do not ask: leave the PR or MR open,
log a `skip` row with the reason and the run IDs, and go on to the next
issue. Name it in the final report.

### 6. Merge

When every job is `success`, merge ("merge a PR or MR"), then read the PR
or MR back ("read a PR or MR") and the issue ("read an issue") to see their
state.

The PR or MR says `Closes #N`, so the merge closes the issue. Check that it
did. If the issue is still open, log it and close it with a comment that
links the PR or MR ("close an issue"). Then go back to the default branch:
`git switch <default branch> && git pull`, and delete the local
`factory/issue-N` branch.

### 6b. Wait for the fresh `:qa` image (self only)

On a tenant, skip this step: its merge does not rebuild the Factory's image.
Log it as an `image` row (`tenant: :qa unchanged`) and go to step 7.

On self, the next issue in the queue must run on an image that holds this
merge. The Factory's workflow runs its `:qa` image, and the `ci` run that
the merge starts on the default branch pushes it in its last step. Do not
trigger the next issue until that push has finished.

1. Find the run for the merge commit:

   ```sh
   sha=$(gh pr view <pr> -R "$REPO" --json mergeCommit --jq .mergeCommit.oid)
   gh run list -R "$REPO" --workflow ci.yml --branch main --event push --limit 5 \
     --json databaseId,headSha,status,conclusion --jq ".[] | select(.headSha==\"$sha\")"
   ```

   The run can take a few seconds to appear. If it is not there yet, wait
   for it in a background command (a loop that re-runs the query until it
   prints a row, with a cap of about five minutes), not with `sleep` in the
   foreground. `ci.yml` filters on paths, so a merge that touches only docs
   or config starts no run: if none appears, check that the merge's files
   are all outside the `on.push.paths` list of `.github/workflows/ci.yml`,
   log that `:qa` is unchanged, and go to step 7.
2. In the background: `gh run watch <id> -R "$REPO" --interval 30`.
3. Read the conclusion of the push step, not only the run's:

   ```sh
   gh run view <id> -R "$REPO" --json conclusion,jobs \
     --jq '.conclusion, (.jobs[] | select(.name=="image") | .steps[] | select(.name|startswith("Push :qa")) | .conclusion)'
   ```

   Both must be `success`. Log the run ID and the result with the phase
   `image`.
4. If the run on `main` failed, `:qa` still holds the previous image and
   `main` is broken. Do not start the next issue. Read the failed job's log
   as in step 5 and treat it as a Factory failure: fix it through a PR as
   in "When the Factory fails" (never push to `main` directly), then wait
   for that merge's image the same way. Then go to step 7.

### 7. Follow-ups

After step 6b, check whether the implementation filed follow-ups. The
Factory files them when the build ships, as issues (Tasks on GitLab) with
the label `class:follow-up` whose body carries
`<!-- factory-followup:N:<key> -->`, and lists their URLs in the PR or MR
body between `<!-- factory-followup-items-begin -->` and
`<!-- factory-followup-items-end -->`. Look them up both ways:

- in the body from "read a PR or MR":

  ```sh
  sed -n '/factory-followup-items-begin/,/factory-followup-items-end/p' \
    | grep -oE '(issues|work_items)/[0-9]+' | cut -d/ -f2
  ```
- in "list open issues with label `class:follow-up`", keeping those whose
  body contains `factory-followup:N:` (on GitHub add `body` to `--json`; on
  GitLab the body is `description`).

Take the union, keep the open ones, and order them oldest first. Log one
`followup` row for issue N with the numbers found, or `none`. A follow-up
can live in another project (the `followup_projects` option); log it and
leave it out, since this run covers only the target repository.

Then run each follow-up, one at a time, through the whole loop from step 1
(read its body) to step 6b, with the same checks as any pick: skip it if it
is closed, has `factory:running`, has an open PR or MR from
`factory/issue-F`, or was already handled in this run. When a follow-up is
merged, check its own follow-ups the same way and run them before the
follow-up's next sibling: the order is depth first, so every issue's
follow-ups are done before the queue moves on.

### 8. Next

Go to step 1 for the next issue of the original queue only when the issue
and all its follow-ups (and theirs) are merged or skipped. Exit when the
queue is empty: with a list, after every issue in it is merged or skipped;
with `label:<name>`, when every open issue with the label is merged,
skipped or already handled in this run; with `max:<size>`, when every open
issue left is bigger than `<size>` or has no size label. A follow-up run in
step 7 counts as handled, so `max:<size>` does not pick it again.

## When the Factory fails

First decide where the fault is:

- **In the issue's code** (a compile error, a wrong test, a missed case):
  it is step 5's work. Fix it on the PR or MR branch.
- **In the issue itself** (it is ambiguous, or contradicts itself, which
  happens with a follow-up whose body is too thin to plan from): take the
  default as in "Answering questions", or your own recommendation when
  there is none, comment it on the issue, and retry.
- **In the Factory** (`fia`, its prompts, its action, its image, or the
  repository's Factory workflow or pipeline file as the Factory generated
  it): the run crashes, the labels or comments are wrong, or it ships code
  it never compiled when it should have.

A fault in the Factory on a **tenant**: you do not fix the Factory from
here. File a Bug on the Factory's repository with `gh` (it lives on
`FACTORY_HOST`; use the GitLab column if that is not github.com). Write the
body to a file and send it:

```sh
jq -n --arg title "<area>: <what broke>" --rawfile body "$SCRATCH/factory-bug.md" \
  '{title: $title, type: "Bug", body: $body}' > "$SCRATCH/factory-bug-req.json"
gh api -X POST "repos/$FACTORY_REPO/issues" --input "$SCRATCH/factory-bug-req.json" \
  > "$SCRATCH/factory-bug-resp.json"
```

The body names the tenant (`$HOST/$REPO`), the issue, the run or pipeline
IDs and their URLs, the failing log lines, and what you expected. If the API
rejects `type`, repeat without it and say so in the report. First check that
no open issue on the Factory's repository already tracks the cause
(`gh issue list -R "$FACTORY_REPO" --state open --search "<terms>"`); if one
does, comment the new evidence on it instead. Log a `skip` row for the
tenant issue that names the Bug's URL, and go on with the queue.

A fault in the Factory on **self**: fix the Factory, then retry the issue.

1. Check whether an open issue already tracks the cause. If it does and
   that issue is size L or larger, do not fix it in this run. Log it,
   handle this issue's PR by hand (step 5), and name the tracking issue in
   the final report. For example, Go code that does not compile points at
   the coder lacking a toolchain.
2. Otherwise, branch from `main`. The Factory's workflow runs its `:qa`
   image and its own action at `@main`, and CI pushes `:qa` from `main`
   (`.github/workflows/ci.yml`). So every fix takes effect after its merge,
   and any branch name works (`fix/<slug>`).
3. Commit, push, and open a PR with a body that states the failure, the
   evidence (run IDs) and the fix. Get its CI green as in step 5, and merge
   it as in step 6.
4. Wait for the `:qa` image of that merge as in step 6b before retrying.
5. Retry the issue. Close the failed PR, if there is one, with a comment
   that names the Factory fix, and delete its branch only if this run
   created it. Then start the issue again: remove `factory:error` and add
   `factory:start`, or comment `/factory replan` when the plan is still
   good and only the build failed. Log the retry, and go on from step 2.

## Rules

- The run is unattended: never ask the operator a question or for an
  approval, never wait for an answer, and always follow your own
  recommendation. A run that cancels or stops without a cause you can see
  is retried once; a second one is logged as `skip`.
- These are not negotiable, and the repository's `CLAUDE.md` or `AGENTS.md`
  may add more: never force-push, deploy, delete data that this run did not
  create, create tokens, change roles, publish any image tag other than the
  `:qa` that CI publishes, or push to the default branch directly. Since there is nobody to ask, an issue that needs one of
  them is logged as `skip` with the reason, and the queue goes on. Merging a
  green PR or MR through "merge a PR or MR" is this skill's job.
- Never print, echo or log a secret. Load a secrets file only into the one
  command that needs it.
- The host may lack what a test needs (a Docker socket, a token). Then that
  test runs only in CI.
- Proof is the command output and the run IDs, not "the job looks green".
  Read the job conclusions.

## Final report

Write one table: issue, size, the parent issue for a follow-up (`—` for
an issue of the queue), PR or MR, the fix commits you added (with one
sentence each on what failed), and the merge time. Then list the issues left
open and why (bigger than the limit, no size label, already running, or
skipped by this run, with the reason; with `label:<name>`, name the label), any
follow-ups filed in another project, every default taken for a question
the operator did not answer (issue, question, answer), the Bugs filed on
the Factory's repository (tenant), any Factory root causes you saw but did
not fix, and the worklog's path.
