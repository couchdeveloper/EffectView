# Git Workflow — Feature Branch with Squash Merge

This guide describes the full lifecycle of a feature branch: from creation to a merged PR and optional version tag. All steps are performed in the terminal.

---

## 1. Start from a clean main

```bash
git checkout main
git pull
```

---

## 2. Create a feature branch

Name branches with a short, descriptive slug.

```bash
git checkout -b feature/my-feature
```

---

## 3. Do the work — commit freely

Commit as often as you like. At this stage, commit messages can be rough.

```bash
git add -p                          # or: git add <file>
git commit -m "wip: rough first pass"

git add -p
git commit -m "fix: edge case in update"

git add -p
git commit -m "test: add test for edge case"
```

---

## 4. Keep the branch up to date with main

Do this regularly while working, and always before opening a PR. Rebase (not merge) keeps the history linear.

```bash
git fetch origin
git rebase origin/main
```

If there are conflicts, resolve each file, then continue:

```bash
# resolve conflicts in editor, then:
git add <resolved-file>
git rebase --continue
```

---

## 5. Clean up commit history before the PR

Since you use **squash merge**, GitHub will collapse everything into one commit anyway. Still, cleaning up your branch makes review easier and produces a better squash commit message on `main`.

Use interactive rebase to squash, reword, or drop commits:

```bash
git rebase -i origin/main
```

In the editor, mark commits as `pick`, `squash` (`s`), `fixup` (`f`), or `reword` (`r`). A typical result is one or two clean, descriptive commits:

```
pick abc1234 Add SPI badges and fix docs URL
pick def5678 Harden test helper with timeout
```

After saving, Git opens another editor for the combined commit message if you squashed. Write a clear, imperative-mood summary:

```
Add SPI badges, fix docs URL, and harden test helper with timeout

- README: add Swift Package Index badges for versions and platforms
- SwiftUIFirst.md: fix package URL (your-org → couchdeveloper)
- Tests: convert embedInWindowAndMakeKey to a throwing function with
  a configurable timeout; remove redundant readyExpectation pattern
```

---

## 6. Push the branch

If you have previously pushed and then rebased (which rewrites history), use `--force-with-lease`. This is safer than `--force` — it will refuse to push if someone else has pushed to the branch since your last fetch.

```bash
git push origin feature/my-feature                   # first push
git push --force-with-lease origin feature/my-feature # after a rebase
```

---

## 7. Open a Pull Request

```bash
open https://github.com/couchdeveloper/EffectView/compare/main...feature/my-feature?expand=1
```

Fill in title and body, then click **Create pull request**.

> Make sure the merge strategy on GitHub is set to **Squash and merge**.

---

## 8. After the PR is merged

Switch to `main` and pull. After the pull, `HEAD` is exactly the squash commit that was just merged — this is the right moment to inspect and tag.

```bash
git checkout main
git pull
```

---

## 9. Tag the version (if applicable)

Tag **immediately after `git pull`** while `HEAD` is still the squash commit. This guarantees the tag points to the correct commit.

First, confirm only your squash commit sits above the previous tag — this also tells you what the previous version was:

```bash
git describe --tags --abbrev=0
# → e.g. 0.1.0  (the last released version)

git log --oneline $(git describe --tags --abbrev=0)..HEAD
# Expected output — exactly one commit, yours:
# 55cb803 (HEAD -> main, origin/main) Add SPI badges, fix docs URL, and harden test helper with timeout
```

If more than one commit appears, a previous merge has not been tagged yet. **Stop — determine and apply that tag first** before deciding your own version number. The version sequence must be settled in order.

Then create an annotated tag and push it. Annotated tags (not lightweight) record the tagger, date, and message — they are what `git describe` and GitHub Releases use.

```bash
git tag -a 0.2.0 -m "Release 0.2.0"
git push origin 0.2.0
```

Verify the tag landed on the right commit:

```bash
git show 0.2.0 --stat
# Should show the squash commit hash and the changed files
```

---

## 10. Clean up branches

Now that `main` is tagged, delete the feature branch. Because squash merge creates a new commit with no parent pointer back to the feature branch, Git requires a force-delete — this is expected, not a warning to worry about.

```bash
git branch -D feature/my-feature             # local
git push origin --delete feature/my-feature  # remote
```
