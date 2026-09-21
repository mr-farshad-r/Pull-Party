#!/usr/bin/env bash

# Pull every Git repository found under a directory and print a result table.
# Usage: ./git-pull-all.sh [repositories-directory]
# The directory defaults to the current working directory.

set -euo pipefail

if (( $# > 1 )); then
    echo "Usage: $0 [repositories-directory]" >&2
    exit 2
fi

BASE_DIR="${1:-$PWD}"

# Validate input is an existing directory
if [[ ! -d "$BASE_DIR" ]]; then
    echo "❌ Error: '$BASE_DIR' is not a directory" >&2
    exit 1
fi

BASE_DIR="$(cd "$BASE_DIR" && pwd)"

echo "🔎 Scanning for Git repositories in: $BASE_DIR"
echo "========================================="

count=0
failed=0
skipped=0
repos=() branches=() results=() details=()

git_error_reason() {
    # Prefer Git's first explicit error; otherwise keep its last non-empty line.
    local line reason=""
    while IFS= read -r line; do
        if [[ "$line" == fatal:* || "$line" == error:* ]]; then
            reason="$line"
            break
        fi
        [[ -z "$line" ]] || reason="$line"
    done <<< "$1"
    if [[ "$reason" == error:\ cannot\ lock\ ref* && "$reason" == *"File exists." ]]; then
        reason="Git reference lock exists"
    fi
    printf '%s' "$reason"
}

git_transfer_summary() {
    # Count fetched refs without printing Git's potentially thousands of lines.
    awk '
        / -> / { refs++ }
        /\[new branch\]/ { branches++ }
        /\[new tag\]/ { tags++ }
        END { printf "Refs: %d | New branches: %d | New tags: %d", refs, branches, tags }
    ' <<< "$1"
}

recover_stale_git_lock() {
    # Retry only the specific lock-file failure Git emits. Never touch locks
    # outside this repository or locks currently held by another process.
    local git_output="$1" git_dir="$2" lock_file lock_dir
    lock_file="$(printf '%s\n' "$git_output" | sed -n "s/.*Unable to create '\([^']*\.lock\)': File exists\..*/\1/p" | head -n 1)"
    [[ -n "$lock_file" ]] || return 1

    # Resolve symlinked path prefixes such as macOS /var -> /private/var.
    lock_dir="$(cd "$(dirname -- "$lock_file")" 2>/dev/null && pwd -P)" || return 1
    lock_file="$lock_dir/$(basename -- "$lock_file")"
    git_dir="$(cd "$git_dir" 2>/dev/null && pwd -P)" || return 1

    case "$lock_file" in
        "$git_dir"/*.lock) ;;
        *) return 1 ;;
    esac

    # Another process may have completed between the failed pull and this check.
    [[ -e "$lock_file" ]] || return 0
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -- "$lock_file" >/dev/null 2>&1 && return 1

    rm -- "$lock_file"
    echo "  🧹 Removed stale Git lock: ${lock_file#"$git_dir"/}"
}

while IFS= read -r -d '' gitdir; do
    repo_dir="$(dirname -- "$gitdir")"
    repo_name="${repo_dir#"$BASE_DIR"/}"
    [[ "$repo_dir" == "$BASE_DIR" ]] && repo_name="$(basename -- "$BASE_DIR")"

    echo ""
    echo "📦 $repo_name"

    if ! cd -- "$repo_dir"; then
        echo "  ❌ Failed to enter directory"
        failed=$((failed + 1))
        count=$((count + 1))
        repos+=("$repo_name") branches+=("-") results+=("❌ FAILED") details+=("Cannot enter directory")
        continue
    fi

    # Get current branch
    if ! branch="$(git rev-parse --abbrev-ref HEAD 2>&1)"; then
        echo "  ❌ $branch"
        failed=$((failed + 1))
        count=$((count + 1))
        reason="$(git_error_reason "$branch")"
        repos+=("$repo_name") branches+=("-") results+=("❌ FAILED") details+=("${reason:-Cannot determine branch}")
        continue
    fi
    echo "  🌿 Branch: $branch"

    # Skip detached HEAD repos
    if [[ "$branch" == "HEAD" ]]; then
        echo "  ⏭️  Detached HEAD — skipping pull"
        repos+=("$repo_name") branches+=("HEAD") results+=("⏭️  SKIPPED") details+=("Detached HEAD")
        skipped=$((skipped + 1))
        count=$((count + 1))
        continue
    fi

    # Ensure tracking branch is set; if not, set it to origin/<branch>
    if ! git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        echo "  ⚠️  No upstream branch — setting it to origin/$branch"
        if ! output="$(git branch --set-upstream-to="origin/$branch" 2>&1)"; then
            failed=$((failed + 1))
            reason="$(git_error_reason "$output")"
            echo "  ❌ ${reason:-Could not set upstream to origin/$branch}"
            repos+=("$repo_name") branches+=("$branch") results+=("❌ FAILED") details+=("${reason:-Could not set upstream to origin/$branch}")
            count=$((count + 1))
            continue
        fi
    fi

    # Refuse merge commits and rebases; divergent repositories are reported.
    before_head="$(git rev-parse HEAD)"
    before_tag_count="$(git tag --list | wc -l | tr -d ' ')"
    pull_ok=false
    if output="$(git pull --ff-only 2>&1)"; then
        pull_ok=true
    else
        git_dir="$(git rev-parse --absolute-git-dir)"
        if recover_stale_git_lock "$output" "$git_dir"; then
            echo "  🔄 Retrying pull once"
            if output="$(git pull --ff-only 2>&1)"; then
                pull_ok=true
            fi
        fi
    fi

    if "$pull_ok"; then
        after_head="$(git rev-parse HEAD)"
        after_tag_count="$(git tag --list | wc -l | tr -d ' ')"
        file_count="$(git diff --name-only "$before_head" "$after_head" | wc -l | tr -d ' ')"
        commit_count="$(git rev-list --count "$before_head..$after_head")"
        tag_count=$((after_tag_count - before_tag_count))
        ((tag_count < 0)) && tag_count=0
        summary="Files: $file_count | Commits: $commit_count | Tags: $tag_count"
        echo "  ✅ $summary"
        repos+=("$repo_name") branches+=("$branch") results+=("✅ OK") details+=("$summary")
    else
        failed=$((failed + 1))
        reason="$(git_error_reason "$output")"
        transfer_summary="$(git_transfer_summary "$output")"
        reason="${reason:-git pull --ff-only failed without an error message}"
        echo "  ❌ Pull failed | $transfer_summary | $reason"
        repos+=("$repo_name") branches+=("$branch") results+=("❌ FAILED") details+=("$transfer_summary | $reason")
    fi

    count=$((count + 1))

done < <(find "$BASE_DIR" -maxdepth 5 -name ".git" \( -type d -o -type f \) ! -path "*/node_modules/*" ! -path "*/.git/*" -print0)

echo ""
echo "========================================="
echo "🏁 Done. Repositories: $count | ✅ Succeeded: $((count - failed - skipped)) | ⏭️ Skipped: $skipped | ❌ Failed: $failed"
if ((count > 0)); then
    repo_width=10
    branch_width=6
    for i in "${!repos[@]}"; do
        (( ${#repos[i]} > repo_width )) && repo_width=${#repos[i]}
        (( ${#branches[i]} > branch_width )) && branch_width=${#branches[i]}
    done
    printf "\n%-*s  %-*s  %-12s  %s\n" "$repo_width" "Repository" "$branch_width" "Branch" "Result" "Details"
    printf '%*s  %*s  %*s  %s\n' "$repo_width" '' "$branch_width" '' 12 '' '' | tr ' ' '-'
    for i in "${!repos[@]}"; do
        printf "%-*s  %-*s  %-12s  %s\n" "$repo_width" "${repos[i]}" "$branch_width" "${branches[i]}" "${results[i]}" "${details[i]}"
    done
fi
((failed == 0))
