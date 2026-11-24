#!/usr/bin/env bash
# Finds and fetches the context lake of fia-todo's target project.
#
#   SCRATCH=<dir> bash context-lake.sh find
#     Prints every line of the committed configuration that sets a
#     context_lake_* option, at the default branch's head. Prints "no context
#     lake configuration" when there is none.
#   SCRATCH=<dir> bash context-lake.sh fetch <path> <repo> <ref>
#     Makes the lake readable and writes $SCRATCH/lake.env. An unset option is
#     ''.
#
# Both read $SCRATCH/forge.env. CHECKOUT is empty there when the target is not
# the repository of the current directory. Exit 1: the lake cannot be read.
# Exit 2: a bad option value. The Factory fails on the same values.
set -u
: "${SCRATCH:?set SCRATCH to the session scratchpad directory}"
. "$SCRATCH/forge.env"
export GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1

# A URL can hold a credential.
mask() { sed 's#//[^/@[:space:]]*@#//#g'; }
die() { local code=$1; shift; printf 'ERROR: %s\n' "$*" | mask >&2; exit "$code"; }

case $FORGE in
  github) helper='!gh auth git-credential' ;;
  *)      helper='!glab auth git-credential' ;;
esac

# clone <url> <ref> <dir>: one commit of ref, as the Factory clones it, read
# with the user's own login. A symlink in it is written as a plain file.
clone() {
  local err
  rm -rf "$3" && mkdir -p "$3" && git -C "$3" init -q || return 1
  err=$(git -C "$3" -c credential.helper= -c "credential.helper=$helper" \
    fetch -q --depth 1 -- "$1" "$2" 2>&1) || { CLONE_ERR=$(printf '%s\n' "$err" | head -n 1); return 1; }
  err=$(git -C "$3" -c core.symlinks=false checkout -q --detach FETCH_HEAD 2>&1) ||
    { CLONE_ERR=$(printf '%s\n' "$err" | head -n 1); return 1; }
}

# project: sets PROJECT (a git directory) and BASE (the default branch's head).
project() {
  if [ -n "${CHECKOUT:-}" ]; then
    PROJECT=$CHECKOUT
    git -C "$PROJECT" fetch -q origin HEAD || die 1 "cannot fetch the default branch of origin"
    BASE=$(git -C "$PROJECT" rev-parse FETCH_HEAD)
  else
    PROJECT=$SCRATCH/context-lake/project
    clone "https://$HOST/$REPO.git" HEAD "$PROJECT" || die 1 "cannot clone $HOST/$REPO: $CLONE_ERR"
    BASE=$(git -C "$PROJECT" rev-parse HEAD)
  fi
}

# visibility <repository path>: public, internal, private or unknown.
visibility() {
  local v
  if [ "$FORGE" = github ]; then
    v=$(gh api "repos/$1" --jq .visibility 2>/dev/null)
  else
    v=$(glab api "projects/$(printf '%s' "$1" | sed 's#/#%2F#g')" 2>/dev/null | jq -r '.visibility // empty' 2>/dev/null)
  fi
  case $v in public|internal|private) echo "$v" ;; *) echo unknown ;; esac
}

find_config() {
  project
  local files=(.fia.yaml)
  case $FORGE in
    github) files+=(.github/workflows) ;;
    *)      files+=(.gitlab-ci.yml .gitlab '*gitlab-ci*.yml') ;;
  esac
  git -C "$PROJECT" grep -niE 'context_lake_(path|repo|ref)["'\'']?[[:space:]]*:' "$BASE" -- "${files[@]}" |
    grep -vE '^[^:]+:[^:]+:[0-9]+:[[:space:]]*#' | sed "s/^$BASE://" | mask |
    { grep . || echo "no context lake configuration"; }
}

fetch_lake() {
  local path=$1 repo=$2 ref=$3 rest host
  [ -n "$ref" ] && [ -z "$repo" ] && die 2 "context_lake_ref \"$ref\" is set but context_lake_repo is empty"
  [ -z "$path$repo" ] && die 2 "context_lake_path and context_lake_repo are both empty: no context lake"
  if [ -z "$repo" ]; then
    project
    LAKE_DIR=$PROJECT LAKE_COMMIT=$BASE LAKE_REPO=$REPO
  else
    case $repo in https://*) ;; *) die 2 "context_lake_repo \"$repo\" must be an https:// URL on $HOST" ;; esac
    rest=${repo#https://}; host=${rest%%/*}; host=${host##*@}; host=${host%%:*}
    [ "${host,,}" = "${HOST,,}" ] || die 2 "context_lake_repo \"$repo\" is on $host, not on the project's forge host $HOST"
    LAKE_REPO=${rest#*/}; LAKE_REPO=${LAKE_REPO%/}; LAKE_REPO=${LAKE_REPO%.git}
    if [ -n "${CHECKOUT:-}" ]; then
      local home=$CHECKOUT/.fia/context-lake
      [ -L "$CHECKOUT/.fia" ] || [ -L "$home" ] && die 1 ".fia/context-lake is behind a symbolic link in $CHECKOUT"
      [ -z "$(git -C "$CHECKOUT" ls-files -- .fia/context-lake)" ] || die 1 ".fia/context-lake holds tracked files in $CHECKOUT"
      mkdir -p "$home" && printf '*\n' > "$home/.gitignore" || die 1 "cannot write $home"
      LAKE_DIR=$home/repo
    else
      LAKE_DIR=$SCRATCH/context-lake/repo
    fi
    clone "$repo" "${ref:-HEAD}" "$LAKE_DIR" || die 1 "context_lake_repo \"$repo\"${ref:+ (context_lake_ref \"$ref\")}: cannot clone it: ${CLONE_ERR:-cannot write $LAKE_DIR}"
    LAKE_COMMIT=$(git -C "$LAKE_DIR" rev-parse HEAD)
  fi
  LAKE_PATH=${path%/}
  [ "$(git -C "$LAKE_DIR" cat-file -t "$LAKE_COMMIT:$LAKE_PATH" 2>/dev/null)" = tree ] ||
    die 1 "context_lake_path \"$path\": no such folder in $LAKE_REPO at $LAKE_COMMIT"
  LAKE_VISIBILITY=$(visibility "$LAKE_REPO")
  TARGET_VISIBILITY=$LAKE_VISIBILITY
  [ "$LAKE_REPO" = "$REPO" ] || TARGET_VISIBILITY=$(visibility "$REPO")
  for v in LAKE_DIR LAKE_COMMIT LAKE_PATH LAKE_REPO LAKE_VISIBILITY TARGET_VISIBILITY; do
    printf '%s=%q\n' "$v" "${!v}"
  done | tee "$SCRATCH/lake.env"
}

case ${1:-} in
  find)  find_config ;;
  fetch) [ $# -eq 4 ] || die 2 "usage: context-lake.sh fetch <path> <repo> <ref>"; fetch_lake "$2" "$3" "$4" ;;
  *)     die 2 "usage: context-lake.sh find | fetch <path> <repo> <ref>" ;;
esac
