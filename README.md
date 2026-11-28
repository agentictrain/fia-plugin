# fia-plugin

A Claude Code marketplace with one plugin, `fia`, for projects that have the
Factory installed. It holds three skills:

- `fia-todo` turns a short description into an issue the Factory planner can
  plan from, with its type and `size:*` label. When the project has a context
  lake, it reads it, follows its links, and asks, recommends and records
  decisions against it.
- `fia-conductor` runs issues through the Factory: trigger, plan, approve,
  build, get CI green, merge, then the follow-ups (those with a `human:*`
  label are left for a human). A `kind:check` follow-up, or a `kind:check`
  issue given to it, is validated on your host instead of by the Factory:
  it runs the check's command with the host's Docker, logins and secrets
  file, on the project and the test projects its docs list (for level 4,
  only the affected scenarios), closes the item when it passes, runs one
  fix through the Factory when it fails, and labels it `human:to-validate`
  only when it cannot run it or the fix did not help. Each issue runs with its follow-ups in its
  own fresh agent, one at a time, or up to `<n>` at once with
  `parallel:<n>`; on the Factory's own repository no issue is triggered
  while one of the run's merges waits for its `:qa` image. It does its git
  work in worktrees under its scratchpad, so it leaves your checkout on the
  branch and commit it found, and keeps its worklog untracked in `.audit/`.

The skills work from a clone of the project. They read the target from its
`origin` remote and use `gh` on github.com and `glab` on any other host,
which they take to be GitLab.

`fia install` in the Factory enables the plugin in the project's
`.claude/settings.json`. This repository is private, so Claude Code needs git
access to `github.com/agentictrain/fia-plugin` (an SSH key or a `gh` login
that can read it) to install the plugin.

To install it by hand:

```
/plugin install fia --marketplace agentictrain/fia-plugin
```
