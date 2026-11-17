# Branch Workflow and Push Safety

This document describes the safe Git workflow for Rigoblock feature branches. It exists because a plain `git checkout -b feat/x origin/development` silently sets the upstream to `origin/development`, and a later plain `git push` can then push commits straight onto the default branch, bypassing CI.

## Creating a new branch

```bash
# 1. Create WITHOUT tracking the source branch
git fetch origin
git checkout -b feat/my-branch origin/development --no-track
```

## Pushing safely

```bash
# 2. Do the work, commit...

# 3. Push ONLY with an explicit refspec naming the same branch
git push -u origin feat/my-branch:feat/my-branch

# 4. VERIFY the upstream before every push — upstream must be origin/<same-name>, never development
git rev-parse --abbrev-ref --symbolic-full-name @{u}
git branch -vv | grep '^\*'
```

## Recovering from a wrong upstream

If `git branch -vv` ever shows `[origin/development]` (or any upstream that is not `origin/<same-name>`) on a feature branch:

```bash
git branch --unset-upstream
# re-push with the explicit refspec
git push -u origin feat/my-branch:feat/my-branch
```

Never use `git push` without a refspec on a branch you did not just verify.

## Rule of thumb

Commits reach `development` **only** via a pull request so that CI (tests, security checks, coverage) always runs. Never push directly to `development` or any default branch.
