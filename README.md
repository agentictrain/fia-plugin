# fia-plugin

A Claude Code marketplace with one plugin, `fia`, for projects that have the
Factory installed. It holds three skills:

- `fia-todo` turns a short description into an issue the Factory planner can
  plan from, with its type and `size:*` label. When the project has a context
  lake, it reads it, follows its links, and asks, recommends and records
  decisions against it.
- `fia-conductor` runs issues through the Factory one at a time: trigger,
  plan, approve, build, get CI green, merge, then the follow-ups (those
  with a `human:*` label are left for a human).

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
