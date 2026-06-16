# docs_src/

Add your domain documents here (`.txt` or `.md` files).

The `ingest_documents` pipeline step reads all files in this directory recursively,
chunks them, embeds them with `BAAI/bge-small-en-v1.5`, and upserts them to Qdrant.

`scripts/deploy_pipeline.py` copies this directory to the shared PVC before submitting a run,
so the pipeline can access it inside the cluster.

**Tips:**
- One document per file, named descriptively (e.g. `treatment-guidelines-2024.txt`)
- `.md` files work well — headings help the chunker find natural split points
- Remove this README before running (it will be ingested as a document)
