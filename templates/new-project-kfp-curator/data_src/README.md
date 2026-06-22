# data_src/

Place raw source documents here before triggering **Deploy to KFP**.

`scripts/deploy_pipeline.py` copies this directory to the PVC at:
`~/shared/huggingface-kfp/curator-input/{{PROJECT_NAME}}/raw/`

## Supported formats

| Format | Extension | Notes |
|--------|-----------|-------|
| Plain text | `.txt` | One document per file |
| Markdown | `.md` | Stripped to plain text before processing |
| HTML | `.html` | Extracted via trafilatura (boilerplate removed) |
| JSONL | `.jsonl` | One JSON object per line; set `input.text_field` in `config.yaml` |

## Tips

- Aim for ≥ 100 documents for meaningful deduplication stats
- Subdirectories are walked recursively
- Hidden files (`.filename`) are ignored
- For JSONL: each record must have the field named in `config.yaml → input.text_field`
  (default: `"text"`) and optionally `input.id_field` (default: `"id"`)
