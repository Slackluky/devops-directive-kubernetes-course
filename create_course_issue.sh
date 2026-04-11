#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-Slackluky/devops-directive-kubernetes-course}"
CREATE_MODULE_ISSUES="${CREATE_MODULE_ISSUES:-1}"

DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef -q '.defaultBranchRef.name')"

ensure_label() {
  local name="$1"
  local color="$2"
  local desc="$3"

  if gh label list -R "$REPO" --search "$name" --json name -q ".[] | select(.name==\"$name\") | .name" | grep -qx "$name"; then
    echo "Label exists: $name"
  else
    echo "Creating label: $name"
    gh label create "$name" -R "$REPO" --color "$color" --description "$desc"
  fi
}

find_issue_url_by_title() {
  local title="$1"

  gh issue list -R "$REPO" \
    --state all \
    --limit 500 \
    --json title,url \
    -q ".[] | select(.title==\"$title\") | .url" \
  | head -n1
}

issue_number_from_url() {
  local url="$1"
  echo "${url##*/}"
}

issue_web_url() {
  local number="$1"
  echo "https://github.com/$REPO/issues/$number"
}

readme_doc_title() {
  local readme_path="$1"
  awk 'match($0, /^# /) { sub(/^# /, "", $0); print; exit }' "$readme_path"
}

readme_leaf_modules() {
  local readme_path="$1"

  awk '
    function clean_heading(line) {
      sub(/^### /, "", line)
      sub(/^## /, "", line)
      return line
    }

    /^## / {
      if (current_h2 != "" && saw_h3 == 0) {
        print current_h2
      }
      current_h2 = clean_heading($0)
      saw_h3 = 0
      next
    }

    /^### / {
      if (current_h2 == "") {
        next
      }
      saw_h3 = 1
      print current_h2 " / " clean_heading($0)
      next
    }

    END {
      if (current_h2 != "" && saw_h3 == 0) {
        print current_h2
      }
    }
  ' "$readme_path"
}

phase_body() {
  local phase_num="$1"
  local phase_dir="$2"
  local phase_title="$3"
  local module_links="$4"
  local readme_path="$phase_dir/README.md"
  local readme_url="https://github.com/$REPO/blob/$DEFAULT_BRANCH/$readme_path"

  cat <<EOF
## Phase $phase_num — $phase_title

### Source
- README: [$readme_path]($readme_url)
- Directory: \`$phase_dir/\`

### Goal
Work through the phase README, complete the module topics below, and land the related changes.

### Checklist
- [ ] Review the phase README end-to-end
- [ ] Complete the module issues for this phase
- [ ] Open PR(s) linked to this phase
- [ ] Merge PR(s)
- [ ] Sync merged knowledge into Obsidian

### Module issues
$module_links
EOF
}

module_body() {
  local phase_num="$1"
  local phase_dir="$2"
  local module_name="$3"
  local phase_issue_url="$4"
  local readme_path="$phase_dir/README.md"
  local readme_url="https://github.com/$REPO/blob/$DEFAULT_BRANCH/$readme_path"

  cat <<EOF
## Module ($phase_num) — $module_name

### Parent phase
- $phase_issue_url

### Source
- README: [$readme_path]($readme_url)
- Module heading: \`$module_name\`

### Definition of done
- [ ] Work through the module material in the README
- [ ] Reproduce the relevant commands or manifests
- [ ] Capture any repo changes needed for this module
- [ ] Link the PR back to the parent phase issue
- [ ] Sync merged knowledge into Obsidian if applicable
EOF
}

upsert_issue() {
  local title="$1"
  local body="$2"
  shift 2

  local existing_url
  existing_url="$(find_issue_url_by_title "$title")"

  if [[ -n "$existing_url" ]]; then
    local issue_number
    issue_number="$(issue_number_from_url "$existing_url")"
    echo "Updating existing issue: $title (#$issue_number)" >&2
    gh issue edit -R "$REPO" "$issue_number" --body "$body" >/dev/null
    for label in "$@"; do
      gh issue edit -R "$REPO" "$issue_number" --add-label "$label" >/dev/null
    done
    printf '%s\n' "$existing_url"
    return
  fi

  echo "Creating issue: $title" >&2

  local cmd=(
    gh issue create
    -R "$REPO"
    --title "$title"
    --body "$body"
  )

  local label
  for label in "$@"; do
    cmd+=(--label "$label")
  done

  "${cmd[@]}"
}

ensure_label "phase" "1f6feb" "Course phase umbrella issue"
ensure_label "module" "2ea043" "Course module issue"
ensure_label "obsidian" "a371f7" "Requires Obsidian knowledge sync"

declare -a PHASE_DIRS=()
for phase_num in $(seq -w 3 14); do
  for phase_dir in "${phase_num}"-*; do
    if [[ -d "$phase_dir" ]]; then
      PHASE_DIRS+=("$phase_dir")
    fi
  done
done

if [[ ${#PHASE_DIRS[@]} -eq 0 ]]; then
  echo "ERROR: No phase directories 03-*..14-* found in the current directory." >&2
  exit 1
fi

declare -a PHASE_SUMMARY_LINES=()

echo "Repo: $REPO"
echo "Generating issues for phases 03..14 from each README.md..."

for phase_dir in "${PHASE_DIRS[@]}"; do
  readme_path="$phase_dir/README.md"

  if [[ ! -f "$readme_path" ]]; then
    echo "Skipping $phase_dir: missing README.md" >&2
    continue
  fi

  phase_num="${phase_dir%%-*}"
  phase_title_text="$(readme_doc_title "$readme_path")"
  phase_issue_title="Phase ${phase_num} — ${phase_title_text:-${phase_dir#*-}}"

  if [[ "$CREATE_MODULE_ISSUES" == "1" ]]; then
    MODULES=()
    while IFS= read -r module_name; do
      MODULES+=("$module_name")
    done < <(readme_leaf_modules "$readme_path")
  else
    MODULES=()
  fi

  phase_issue_url="$(upsert_issue "$phase_issue_title" "$(phase_body "$phase_num" "$phase_dir" "${phase_title_text:-${phase_dir#*-}}" "_Module links will be refreshed below._")" phase)"
  PHASE_SUMMARY_LINES+=(" - ${phase_dir}: ${phase_issue_url}")

  module_links="- [ ] No module issues generated"

  if [[ ${#MODULES[@]} -gt 0 ]]; then
    module_links=""
    for module_name in "${MODULES[@]}"; do
      module_issue_title="Module ${phase_num} — ${module_name}"
      module_issue_url="$(upsert_issue "$module_issue_title" "$(module_body "$phase_num" "$phase_dir" "$module_name" "$phase_issue_url")" module obsidian)"
      module_issue_number="$(issue_number_from_url "$module_issue_url")"
      module_links+="- [ ] #$module_issue_number"$'\n'
    done
    module_links="${module_links%$'\n'}"
  fi

  phase_issue_number="$(issue_number_from_url "$phase_issue_url")"
  gh issue edit -R "$REPO" "$phase_issue_number" --body "$(phase_body "$phase_num" "$phase_dir" "${phase_title_text:-${phase_dir#*-}}" "$module_links")" >/dev/null
done

echo
echo "Done. Phase issues:"
for summary_line in "${PHASE_SUMMARY_LINES[@]}"; do
  echo "$summary_line"
done
