# Adding a New Project Template

A project type is a named template that **Create Project** can instantiate. Adding one
requires changes in five places. The existing `kfp-finetune` type is the best reference.

---

## 1. Create the template directory

```
templates/new-project-<type>/
  CLAUDE.md        ← project-level Claude instructions
  LICENSE
  README.md        ← developer guide; use {{PROJECT_NAME}}, {{PROJECT_HOST}} placeholders
  notebook.ipynb   ← starter notebook (optional but expected for ML types)
  requirements.txt ← base Python deps; create-project appends type-specific extras
  scripts/         ← any helper scripts the template needs
```

`create-project.yaml` runs `cp -r templates/new-project-<type>/. .` into the new repo
and then does `sed` substitutions for `{{PROJECT_NAME}}` and `{{PROJECT_HOST}}`.
Files in `.github/workflows/` inside the template are included automatically.

---

## 2. `create-project.yaml` — five touch points

**a. Input enum** (`inputs.project_type.options`, line ~27):

```yaml
options: [default, kfp, kfp-finetune, nemo, <type>]
```

**b. CI badge injection** (line ~147) — add a branch for your type if it has
deploy/undeploy workflows. Follow the `kfp` or `nemo` branch as a model: set
`BADGE_2` and `BADGE_3` to GitHub Actions badge markdown pointing at
`deploy-<type>.yaml` and `undeploy-<type>.yaml` respectively.

**c. Extra pip packages** (line ~162):

```bash
[[ "${PROJECT_TYPE}" = "<type>" ]] && REQS="${REQS} <package1> <package2>"
```

**d. Blog post body** (`Draft blog post` step, line ~246) — add an `elif` branch
that sets `CATS` (Jekyll categories) and `BODY` (post content). Follow the
`kfp-finetune` branch as a model:

```bash
elif [ "${PROJECT_TYPE}" = "<type>" ]; then
  CATS="miramar <tag1> <tag2>"
  BODY=$(printf '%s\n' \
    "${DESCRIPTION:-<!-- TODO: one-sentence description -->}" "" \
    "## Overview" "" "<!-- TODO -->" "" \
    "## Next steps" "" "<!-- TODO -->")
fi
```

Include the standard `**Platform:**` and `**Repo:**` header lines that reference
`${HW}`, `${DASHBOARD_URL}`, `${PROJECT_NAME}`, and `${REPO_URL}` — copy them
from the `kfp-finetune` branch in the same step.

**e. Summary / next steps** (`Summary` step, line ~382):

```bash
elif [ "${PROJECT_TYPE}" = "<type>" ]; then
  echo "### Next steps"
  echo "1. ..."
```

---

## 3. `generate-dashboard.sh` — two touch points

**a. Topic → type detection** (jq chain, line ~45) — add your topic **before**
the generic `miramar-kfp` check if the type is a sub-variant of an existing family:

```bash
type=$(echo "$repo_json" | jq -r '.topics |
  if   index("miramar-<type>")       then "<type>"
  elif index("miramar-kfp-finetune") then "kfp-finetune"
  elif index("miramar-kfp")          then "kfp"
  ...
  else "other" end')
```

`create-project.yaml` tags the repo `miramar-<type>` automatically (line ~22 of
the `Set repository topics` step), so the topic name is always `miramar-<type>`.

**b. Badge CSS** (line ~234) — add a colour pair:

```css
.badge-<type> { background: #rrggbb; color: #rrggbb; }
```

Pick a colour not already used: `kfp` = blue, `kfp-finetune` = teal,
`nemo` = green, `default`/`other` = amber.

---

## 4. `CLAUDE.md`

Add a row to the **Create Project** workflow table describing the new type:

```markdown
| Create Project | `create-project.yaml` | ... `<type>` (<one-line description>; badge colour; topic tag `miramar-<type>`) ... |
```

---

## 5. `docs/workflows.md`

Update the Create Project entry there too (same one-liner).

---

## Checklist

- [ ] `templates/new-project-<type>/` directory with all required files
- [ ] `create-project.yaml` — input enum, badge, packages, blog body, summary
- [ ] `generate-dashboard.sh` — topic detection, badge CSS
- [ ] `CLAUDE.md` — Create Project table row
- [ ] `docs/workflows.md` — Create Project entry
- [ ] Deploy dashboard after merge to pick up the new badge colour
