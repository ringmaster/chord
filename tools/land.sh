#!/bin/sh
# Lands the current feature branch on main. Run it with `make land` from the
# branch's worktree. The steps:
# 1. Rebase the branch onto main.
# 2. Run `make build` and `make test` on the rebased branch.
# 3. Fast-forward main in the main checkout to the branch.
# 4. Build the main checkout, so its Debug app has the change.
# When main moves between step 1 and step 3, the fast-forward is refused,
# and the steps start again, up to three times. A fast-forward never
# rewrites main, so a refused or failed run loses no work.
set -eu

fail() {
    echo "land: $1" >&2
    exit 1
}

branch=$(git symbolic-ref --quiet --short HEAD) || fail "HEAD is not on a branch."
[ "$branch" != "main" ] || fail "run this from a feature branch, not main."
git diff --quiet && git diff --cached --quiet || fail "commit the changes on $branch first."

# The main checkout is the worktree that has main checked out.
main_dir=$(git worktree list --porcelain | awk '
    /^worktree / { dir = substr($0, 10) }
    $0 == "branch refs/heads/main" { print dir }')
[ -n "$main_dir" ] || fail "no worktree has main checked out."

attempt=1
while :; do
    echo "land: rebasing $branch onto main (attempt $attempt)"
    if ! git rebase main; then
        fail "the rebase stopped on a conflict. Resolve it, run 'git rebase --continue', then run 'make land' again."
    fi
    make build || fail "make build failed on the rebased branch."
    make test || fail "make test failed on the rebased branch."

    if git -C "$main_dir" merge --ff-only "$branch"; then
        echo "land: main is now at $(git rev-parse --short HEAD)."
        if make -C "$main_dir" build >/dev/null; then
            echo "land: built the main checkout."
        else
            echo "land: main moved, but 'make build' in $main_dir failed. Run it there to see why." >&2
        fi
        exit 0
    fi

    # The branch still contains main, so main did not move: the main
    # checkout has uncommitted changes in the files the branch changes.
    if git merge-base --is-ancestor main HEAD; then
        fail "the main checkout has uncommitted changes in files that $branch changes."
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le 3 ] || fail "main kept moving. Run 'make land' again."
done
