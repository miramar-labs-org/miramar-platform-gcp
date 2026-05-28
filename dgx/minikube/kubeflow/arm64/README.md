# KFP MLMD Stack — arm64 Build Notes

Kubeflow Pipelines 2.x deploys an ML Metadata (MLMD) subsystem alongside the
pipeline execution stack. Three of its components have no upstream arm64 images;
this directory contains the Dockerfiles to build them natively on the DGX Spark.

## Why arm64 Images Are Missing Upstream

### ml_metadata_store_server (C++ gRPC server)

Source: [google/ml-metadata](https://github.com/google/ml-metadata)

The upstream Dockerfile (`ml_metadata/tools/docker_server/Dockerfile`) hardcodes the
Bazel installer URL to `bazel-${VERSION}-installer-linux-x86_64.sh`. Building for
arm64 requires switching to [Bazelisk](https://github.com/bazelbuild/bazelisk), which
auto-selects the correct Bazel binary for the host architecture.

A second issue: the `.bazelversion` file at `ml_metadata/.bazelversion` has a 13-line
Apache 2.0 license header. Bazelisk expects a bare version string (e.g. `5.3.0`) and
cannot parse a file with a header.

Upstream tracking: [google/ml-metadata PR#188](https://github.com/google/ml-metadata/pull/188)
(open since 2023, unmerged).

### kfp-metadata-writer (Python service)

Source: [kubeflow/pipelines](https://github.com/kubeflow/pipelines)

The KFP CI workflow explicitly excludes `kfp-metadata-writer` from arm64 builds
([PR#12804](https://github.com/kubeflow/pipelines/pull/12804)). The reason: its
dependency `ml-metadata==1.17.0` has no aarch64 wheel on PyPI and no source
distribution (`sdist`) — it requires Bazel to compile C++ extensions.

Upstream tracking: [kubeflow/pipelines issue #12705](https://github.com/kubeflow/pipelines/issues/12705)

### controller-manager (Application CRD controller)

Source: `gcr.io/ml-pipeline/application-crd-controller:20231101`

amd64-only binary. Manages the `Application` CRD used for display purposes in the
Kubernetes dashboard. **Not required for pipeline execution.** Removed post-deploy in
`deploy-kubeflow.sh`.

---

## Version Matrix

KFP 2.16.1 uses intentionally different versions for the server and Python client:

| Component | Version | Notes |
|---|---|---|
| `ml_metadata_store_server` (gRPC server) | `1.14.0` | C++ binary; pinned in KFP manifests |
| `ml-metadata` Python package | `1.17.0` | Python client; pinned in `kfp-metadata-writer/requirements.txt` |
| `kfp-metadata-writer` | `2.16.1` | KFP component version |

**Compatibility:** The server and Python client communicate over gRPC. The compatibility
boundary is the protobuf schema, not the version number. KFP 2.16.1 has validated this
combination (see the warning in `backend/metadata_writer/requirements.in`: "keep versions
in sync across manifests and requirements files"). Server 1.14.0 and Python client 1.17.0
use a compatible schema.

---

## arm64 Patches Applied

Both Dockerfiles apply the same two patches:

### 1. Bazelisk replaces hardcoded Bazel installer

```dockerfile
# Upstream (amd64-only):
RUN curl -fL https://github.com/bazelbuild/bazel/releases/download/${VERSION}/bazel-${VERSION}-installer-linux-x86_64.sh | bash

# Our fix (arch-aware):
RUN curl -fL "https://github.com/bazelbuild/bazelisk/releases/download/v1.19.0/bazelisk-linux-$(dpkg --print-architecture)" \
    -o /usr/local/bin/bazel && chmod +x /usr/local/bin/bazel
```

`dpkg --print-architecture` returns `arm64` on the DGX, selecting the correct binary.
Bazelisk reads `.bazelversion` and downloads the matching Bazel release automatically.

### 2. .bazelversion header fix

```dockerfile
# Upstream ml_metadata/.bazelversion has 13 lines of Apache license + version on last line.
# Bazelisk needs a bare version string. Extract it:
RUN tail -1 ml_metadata/.bazelversion > .bazelversion
```

This writes a root-level `.bazelversion` that Bazelisk can read (`5.3.0` for the server
build, `6.1.0` for the Python wheel build).

### No postgresql.BUILD changes needed

At both v1.14.0 and v1.17.0, the `ml_metadata/postgresql.BUILD` file already has the
x86-specific `pg_crc32c_sse42_choose.c` commented out:

```starlark
"src/port/pg_crc32c_sb8.c",
# Comment this line out to force usage of sb8 algorithm of crc32c
# "src/port/pg_crc32c_sse42_choose.c",
```

The `copts = []` field is empty — no x86-specific compiler flags. PR#188's postgresql.BUILD
changes are not needed for these versions.

---

## Dockerfile Details

### Dockerfile.mlmd-server

Two-stage build:
1. **builder** (`ubuntu:20.04`): Installs build tools, Bazelisk, clones ml-metadata at
   `v${MLMD_VERSION}`, fixes `.bazelversion`, runs `bazel build ... //ml_metadata/metadata_store:metadata_store_server`.
2. **runtime** (`ubuntu:20.04`): Copies binary + libmysqlclient + tzdata.

The libmysqlclient path is found dynamically using `find` since the Bazel execroot symlink
name (`bazel-ml_metadata`) is based on the workspace name, not the directory name.

### Dockerfile.metadata-writer

Three-stage build:
1. **kfp-source** (`alpine/git`): Sparse-clones `kubeflow/pipelines` at `${KFP_VERSION}`,
   fetching only `backend/metadata_writer/` to avoid downloading the full ~500 MB repo.
2. **wheel-builder** (`python:3.11`): Installs build tools (JDK, gcc, Bazelisk), clones
   ml-metadata at `v${MLMD_VERSION}`, fixes `.bazelversion`, runs `python setup.py bdist_wheel`.
   The `setup.py` invokes Bazel internally to compile pybind11 C++ extensions.
3. **final** (`python:3.11-slim`): Installs the arm64 wheel, then installs all remaining
   requirements from `requirements.txt` (pip skips ml-metadata — already satisfied).

---

## Build Workflow

Trigger **Build MLMD arm64 Images** from GitHub Actions. Both jobs run in parallel on
the DGX native arm64 runner.

| Input | Default | Notes |
|---|---|---|
| `pipeline_version` | `2.16.1` | Sets kfp-metadata-writer image tag |
| `mlmd_server_version` | `1.14.0` | ml_metadata_store_server version |
| `mlmd_wheel_version` | `1.17.0` | ml-metadata Python wheel version |

**Expected duration:** ~45-60 min for each job on first run. Docker layer cache
makes subsequent builds (same version) take seconds.

**When to re-run:** When bumping KFP version (change all three inputs to match the
new version's pinned dependencies — check `manifests/kustomize/base/metadata/base/metadata-grpc-deployment.yaml`
and `backend/metadata_writer/requirements.txt` in the kubeflow/pipelines repo).

---

## Deploy Order

```
1. Build MLMD arm64 Images    (one-time or on version bump)
2. Kubeflow Undeploy
3. Kubeflow Deploy            (deploy-kubeflow.sh patches both MLMD deployments)
```

---

## Verification

After deploy, all 13 pods should be Running:

```sh
kubectl get pods -n kubeflow
```

Check metadata-writer is connecting to the gRPC server:

```sh
kubectl logs -n kubeflow deployment/metadata-writer | head -20
```

Expect: `Listening to namespace: kubeflow` and gRPC connection success messages.

Check the server is accepting connections:

```sh
kubectl logs -n kubeflow deployment/metadata-grpc-deployment | head -20
```

Expect: `Server listening on 0.0.0.0:8080`.

Create a pipeline run via the UI at `http://localhost:8080` and verify the run's
**Input/Output Artifacts** tab shows artifact metadata — this confirms the full
MLMD write path is working.

---

## References

| Resource | Link |
|---|---|
| google/ml-metadata | [GitHub](https://github.com/google/ml-metadata) |
| ml-metadata PR#188 (arm64, unmerged) | [PR](https://github.com/google/ml-metadata/pull/188) |
| KFP arm64 tracking issue | [#12705](https://github.com/kubeflow/pipelines/issues/12705) |
| KFP arm64 CI PR | [#12804](https://github.com/kubeflow/pipelines/pull/12804) |
| deployKF community server image | `ghcr.io/deploykf/ml_metadata_store_server:1.14.0-deploykf.0` |
| Bazelisk | [GitHub](https://github.com/bazelbuild/bazelisk) |
