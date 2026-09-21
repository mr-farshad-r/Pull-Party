# Git Pull All

A small Bash script that finds Git repositories under a directory, safely pulls each repository, and prints an emoji result table.

## Features

- 🔎 Finds repositories up to five directory levels deep
- ✅ Uses fast-forward-only pulls to avoid unexpected merge commits
- 🌿 Sets a missing upstream to `origin/<current-branch>` when possible
- ⏭️ Skips repositories in detached HEAD state
- ❌ Continues after failures and shows the useful Git error
- 📊 Reports changed file, commit, and new tag counts without verbose pull output
- 🔇 Condenses failed fetch output into ref, branch, and tag counts
- 📋 Prints a summary table after processing every repository
- 📁 Supports paths containing spaces
- 🧹 Safely removes stale repository lock files and retries once

## Requirements

- Bash 3.2 or newer
- Git
- `find`, `dirname`, and `tr`

## Usage

Make the script executable:

```bash
chmod +x git-pull-all.sh
```

Scan the current directory:

```bash
./git-pull-all.sh
```

Or pass the directory containing your repositories:

```bash
./git-pull-all.sh ~/Projects
```

The path is optional and defaults to the current working directory.

## Example output

```text
🏁 Done. Repositories: 3 | ✅ Succeeded: 1 | ⏭️ Skipped: 1 | ❌ Failed: 1

Repository  Branch   Result        Details
------------------------------------------------
api         main     ✅ OK         Files: 4 | Commits: 2 | Tags: 1
website     develop  ❌ FAILED     fatal: Not possible to fast-forward, aborting.
prototype   HEAD     ⏭️  SKIPPED  Detached HEAD
```

## Safety

The script runs `git pull --ff-only`. If local and remote history have diverged, it reports the repository as failed and leaves reconciliation to you. This avoids automatically creating a merge commit or rewriting local commits.

If a pull fails because a stale `.lock` file exists, the script removes it only when the file is inside that repository's Git directory and `lsof` confirms that no process is using it. It then retries the pull once. If `lsof` is unavailable or the lock is active, the script leaves the file untouched and reports the failure.

The script exits with status `1` if any repository fails, otherwise `0`.
