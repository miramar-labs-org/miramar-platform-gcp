# Adding a New Project Template

A project type is a named template that **Create Project** can instantiate. Adding one
requires changes in five places. The existing `ft-eval` type is the best reference.

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
and then does `sed` substitutions for `{{PROJECT_NAME}}`, `{{PROJECT_HOST}}` and the
model placeholders below. Files in `.github/workflows/` inside the template are
included automatically.

### Model placeholders

Never hard-code a model name in a template's `config.yaml`. Use the two org
variables, so that changing the platform default for every future project is a
variable edit rather than a template commit:

| Placeholder | Org variable | What it is | Runs on |
| --- | --- | --- | --- |
| `{{DGX_DEFAULT_MODEL}}` | `DGX_DEFAULT_MODEL` | the project's primary LLM | DGX |
| `{{AGX_DEFAULT_MODEL}}` | `AGX_DEFAULT_MODEL` | the shared platform judge | AGX |

Quote them — `model: "{{DGX_DEFAULT_MODEL}}"`. An unquoted `{{...}}` is a YAML flow
mapping and makes the file unparseable before substitution, which breaks any check
that validates the template's raw bytes.

Both are **Ollama tags**, so they belong only in fields that name a *served* model.
Do not substitute `{{DGX_DEFAULT_MODEL}}` into a HuggingFace `model.id` — that is the
model a fine-tune template trains, and an Ollama tag cannot be LoRA-trained. Leave
those as `org/model-id` or a `{{HF_MODEL_ID}}` input.

`create-project.yaml` fails the scaffold if either variable is unset, rather than
substituting an empty string.

### If the template needs an LLM-as-judge

Use the **platform judge**. It is one shared model — `phi4`, hosted on the AGX Orin —
and every project that judges anything uses it, so that scores stay comparable across
runs, across projects, and over time. Do not pick a judge per template, and do not
name it directly: reference `{{AGX_DEFAULT_MODEL}}`.

```yaml
judge:
  model: "{{AGX_DEFAULT_MODEL}}"            # platform judge — substituted from the AGX_DEFAULT_MODEL org variable
  base_url: "http://192.168.1.202:11434/v1" # AGX Orin (AGX_HOST_IP) — the judge always runs here
```

Copy the `judge:` comment block from `templates/new-project-ft-eval/config.yaml` so the
rule, the cost (DGX 2.5 s/call vs AGX 14.0 s/call), and the DGX fallback travel with the
template. Always pass `timeout=` on the judge's `chat.completions.create` call — it is a
LAN call and an unreachable judge otherwise hangs the component forever. Full rationale
and measurements: [`docs/agx.md`](agx.md) → *The platform judge runs here*.

A candidate-under-test or serving endpoint is **not** the judge and stays on the DGX —
that is the hardware being benchmarked.

---

## 2. `create-project.yaml` — five touch points

**a. Input enum** (`inputs.project_type.options`, line ~27):

```yaml
options: [default, kfp, ft-eval, nemo-ft-eval, serving-vllm, serving-nim, serving-trt-fp8, serving-trt-engine, kfp-rag, kfp-eval, kfp-nemo-curator, <type>]
```

**b. CI badge injection** (line ~147) — add a branch for your type if it has
deploy/undeploy workflows. Follow the `kfp` or `nemo-ft-eval` branch as a model: set
`BADGE_2` and `BADGE_3` to GitHub Actions badge markdown pointing at
`deploy-<type>.yaml` and `undeploy-<type>.yaml` respectively.

**c. Extra pip packages** (line ~162):

```bash
[[ "${PROJECT_TYPE}" = "<type>" ]] && REQS="${REQS} <package1> <package2>"
```

**d. Blog post body** (`Draft blog post` step, line ~246) — add an `elif` branch
that sets `CATS` (Jekyll categories) and `BODY` (post content). Follow the
`ft-eval` branch as a model:

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
from the `ft-eval` branch in the same step.

**e. Summary / next steps** (`Summary` step, line ~382):

```bash
elif [ "${PROJECT_TYPE}" = "<type>" ]; then
  echo "### Next steps"
  echo "1. ..."
```

---

## 3. `generate-dashboard.sh` — three touch points

**a. Topic → type detection** (jq chain, line ~45) — add your topic **before**
the generic `miramar-kfp` check if the type is a sub-variant of an existing family:

```bash
type=$(echo "$repo_json" | jq -r '.topics |
  if   index("miramar-<type>")   then "<type>"
  elif index("miramar-ft-eval") then "ft-eval"
  elif index("miramar-kfp")     then "kfp"
  ...
  else "other" end')
```

`create-project.yaml` tags the repo `miramar-<type>` automatically (line ~22 of
the `Set repository topics` step), so the topic name is always `miramar-<type>`.

**b. Badge CSS** (line ~234) — add a colour pair:

```css
.badge-<type> { background: #rrggbb; color: #rrggbb; }
```

Pick a colour not already used. NeMo project types use green shades;
all other types use distinct non-green colours:

- Green (NeMo): `nemo-ft-eval` = emerald green, `kfp-nemo-curator` = forest green/lime
- Blue family: `kfp` = blue, `serving-vllm` = sky blue, `serving-nim` = dark cyan
- Pink: `kfp-rag` = rose/pink
- Magenta: `kfp-eval` = orchid/fuchsia
- Purple: `ft-eval` = indigo/purple
- Warm: `serving-trt-fp8` = gold/yellow, `serving-trt-engine` = orange, `default`/`other` = amber

**c. New Project modal dropdown** (`<select id="np-type">`) — add an option so
the dashboard's "+ New Project" button exposes the new type:

```html
<option value="<type>"><type> &mdash; one-line description</option>
```

---

## 4. `CLAUDE.md`

Add a row to the **Create Project** workflow table describing the new type:

```markdown
| Create Project | `create-project.yaml` | ... `<type>` (<one-line description>; badge colour; topic tag `miramar-<type>`) ... |
```

---

## 5. `docs/workflows.md`

Update the Create Project entry and the **Project types** table (add a row for the new type).
Add per-project workflow rows under the **Model serving** section if the new type has deploy/undeploy workflows.

---

## 6. `docs/architecture.md`

Add a row to both tables:
- **Platform implemented / planned** — mark the capability and its status
- **Project types** — type name, topic tag, host badges, status, one-line description

---

## 7. `docs/index.md`

If the new type introduces a new operator area (e.g. a new serving mechanism), add a row to the source-of-truth map pointing at the template directory.

---

## Checklist

- [ ] `templates/new-project-<type>/` directory with all required files
- [ ] If it judges: `judge:` points at the platform judge (`phi4` @ `192.168.1.202`), never a per-template model
- [ ] `create-project.yaml` — input enum, badge, packages, blog body, summary
- [ ] `generate-dashboard.sh` — topic detection, badge CSS, New Project modal option
- [ ] `CLAUDE.md` — Create Project table row
- [ ] `docs/workflows.md` — Create Project entry + Project types table row + serving workflow rows
- [ ] `docs/architecture.md` — capability row + project types row
- [ ] `docs/index.md` — source-of-truth map row (if new operator area)
- [ ] Deploy dashboard after merge to pick up the new badge colour
