# KFP MLMD Stack — arm64 Build Notes

Kubeflow Pipelines 2.x includes an ML Metadata (MLMD) subsystem. Three of its
components have no upstream arm64 images; this directory contains the Dockerfiles
to build them natively on the DGX Spark (aarch64).

## Versions

Each KFP version has its own subdirectory containing the Dockerfiles for that release:

| Version | Dockerfiles |
| --- | --- |
| [2.16.1](2.16.1/) | `Dockerfile.mlmd-server`, `Dockerfile.metadata-writer` |

## Published Images

| Image | GHCR package |
| --- | --- |
| `ghcr.io/miramar-labs-org/ml_metadata_store_server:1.14.0-arm64` | [pkgs/container/ml_metadata_store_server](https://github.com/miramar-labs-org/miramar-platform-gcp/pkgs/container/ml_metadata_store_server) |
| `ghcr.io/miramar-labs-org/kfp-metadata-writer:2.16.1-arm64` | [pkgs/container/kfp-metadata-writer](https://github.com/miramar-labs-org/miramar-platform-gcp/pkgs/container/kfp-metadata-writer) |

## Why arm64 Images Are Missing Upstream

### ml_metadata_store_server (C++ gRPC server)

Source: [google/ml-metadata](https://github.com/google/ml-metadata)

The upstream Dockerfile hardcodes the Bazel installer URL to
`bazel-${VERSION}-installer-linux-x86_64.sh`. Building for arm64 requires
switching to [Bazelisk](https://github.com/bazelbuild/bazelisk), which auto-selects
the correct binary for the host architecture.

A second issue: `ml_metadata/.bazelversion` has a 13-line Apache 2.0 license header.
Bazelisk expects a bare version string and cannot parse a file with a header.

Upstream tracking: [google/ml-metadata PR#188](https://github.com/google/ml-metadata/pull/188)
(open since 2023, unmerged).

### kfp-metadata-writer (Python service)

Source: [kubeflow/pipelines](https://github.com/kubeflow/pipelines)

The KFP CI workflow explicitly excludes `kfp-metadata-writer` from arm64 builds
([PR#12804](https://github.com/kubeflow/pipelines/pull/12804)). The reason: its
dependency `ml-metadata==1.17.0` has no aarch64 wheel on PyPI and no source
distribution — it requires a Bazel build to compile C++ extensions.

Upstream tracking: [kubeflow/pipelines issue #12705](https://github.com/kubeflow/pipelines/issues/12705)

### controller-manager (Application CRD controller)

amd64-only binary. Manages the `Application` CRD for display purposes only — not
required for pipeline execution. Removed post-deploy in `deploy-kubeflow.sh`.

---

## Version Matrix

KFP 2.16.1 uses intentionally different versions for the server and Python client:

| Component | Version | Notes |
|---|---|---|
| `ml_metadata_store_server` (gRPC server) | `1.14.0` | C++ binary; pinned in KFP manifests |
| `ml-metadata` Python package | `1.17.0` | Python client; pinned in `kfp-metadata-writer/requirements.txt` |
| `kfp-metadata-writer` | `2.16.1` | KFP component version |

**Compatibility:** The server and Python client communicate over gRPC. The compatibility
boundary is the protobuf schema. KFP 2.16.1 has validated this combination. Do NOT
"align" the version numbers — they are intentionally different.

---

## arm64 Patches Applied

### Both Dockerfiles

**1. Bazelisk replaces hardcoded Bazel installer**

```dockerfile
RUN curl -fL \
    "https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-linux-$(dpkg --print-architecture)" \
    -o /usr/local/bin/bazel && chmod +x /usr/local/bin/bazel
```

`dpkg --print-architecture` returns `arm64` on the DGX, selecting the correct binary.

**2. .bazelversion header strip**

```dockerfile
RUN tail -1 ml_metadata/.bazelversion > .bazelversion
```

Writes a root-level `.bazelversion` containing only the bare version string that
Bazelisk can parse (`6.1.0` for both builds; `5.3.0` was an older value).

**3. ZetaSQL archive fixes**

The `zetasql` GitHub repo was renamed to `googlesql`. This changed both the download
URL's sha256 checksum and the `strip_prefix` inside the zip:

```dockerfile
RUN sed -i \
    -e 's/<old-sha256>/<new-sha256>/g' \
    -e 's|strip_prefix = "zetasql-|strip_prefix = "googlesql-|g' \
    WORKSPACE
```

### Dockerfile.mlmd-server only

**4. x86-specific PostgreSQL defines**

`ml_metadata/postgresql.BUILD` hardcodes x86-only processor feature flags. On arm64,
these cause `pg_bitutils.c` to include `<cpuid.h>` which doesn't exist on arm64:

```dockerfile
RUN sed -i \
    -e 's|"#define HAVE_X86_64_POPCNTQ 1",|"/* #undef HAVE_X86_64_POPCNTQ */",|g' \
    -e 's|"#define HAVE__GET_CPUID 1",|"/* #undef HAVE__GET_CPUID */",|g' \
    ml_metadata/postgresql.BUILD
```

With both cleared, `pg_bitutils.c` falls back to `__builtin_popcount` (available on
all GCC/Clang targets including arm64).

### Dockerfile.metadata-writer only

**5. Same x86 + Linux-only postgresql.BUILD fixes**

Same as the server (above), plus clearing `HAVE_GETPEEREID`:

```dockerfile
RUN sed -i \
    -e 's|"#define HAVE_X86_64_POPCNTQ 1",|"/* #undef HAVE_X86_64_POPCNTQ */",|g' \
    -e 's|"#define HAVE__GET_CPUID 1",|"/* #undef HAVE__GET_CPUID */",|g' \
    -e 's|"#define HAVE_GETPEEREID 1",|"/* #undef HAVE_GETPEEREID */",|g' \
    ml_metadata/postgresql.BUILD
```

`getpeereid()` is a BSD/macOS function not available on Linux. GCC silently warns;
leaving it defined would cause a linker failure in the built library.

**6. C++17 required in .bazelrc**

```dockerfile
RUN echo 'build --cxxopt=-std=c++17 --host_cxxopt=-std=c++17' >> .bazelrc
```

The absl and ZetaSQL versions pinned in the WORKSPACE use enum-class scoping that
requires C++17. Without this, Bazel defaults to C++14 and compilation fails.

**7. Debian Bullseye base required for wheel-builder stage**

```dockerfile
FROM python:3.11-bullseye AS wheel-builder
```

The wheel-builder must use Debian 11 (Bullseye / glibc 2.31), **not** the default
`python:3.11` (Debian 12 Bookworm / glibc 2.36). Two glibc-version issues block Bookworm:

- **`uint8_t` unavailability**: absl commit `940c06c` (pinned by ml-metadata 1.17.0)
  uses `uint8_t` in `extension.h` without `#include <cstdint>`. On glibc 2.36,
  `<limits.h>` no longer provides `uint8_t` transitively. On glibc 2.31 it does —
  same behavior as `ubuntu:20.04` used by the server Dockerfile.
- **`SIGSTKSZ` no longer compile-time constant**: glibc 2.34 made `SIGSTKSZ` dynamic
  (`sysconf(_SC_SIGSTKSZ)`). ZetaSQL's m4 build (`c-stack.c:55`) checks
  `#if SIGSTKSZ > ...` which requires a compile-time constant. On glibc 2.31,
  `SIGSTKSZ` is still a plain integer constant.

The final runtime stage (Stage 3) continues to use `python:3.11-slim` (Bookworm) —
only the build stage is constrained to Bullseye.

---

## Dockerfile Details

Dockerfiles live under the versioned subdirectory, e.g. `2.16.1/Dockerfile.mlmd-server`.

### Dockerfile.mlmd-server

Two-stage build:
1. **builder** (`ubuntu:20.04`): Installs build tools, Bazelisk, clones ml-metadata at
   `v${MLMD_VERSION}`, applies patches, runs `bazel build`.
2. **runtime** (`ubuntu:20.04`): Copies binary + tzdata. `libmysqlclient` is found via
   `find -L` (following the `bazel-ml_metadata` execroot symlink) and copied only if
   present (the binary may be statically linked).

### Dockerfile.metadata-writer

Three-stage build:
1. **kfp-source** (`alpine/git`): Sparse-clones `kubeflow/pipelines` at `${KFP_VERSION}`,
   fetching only `backend/metadata_writer/` to avoid the full ~500 MB repo.
2. **wheel-builder** (`python:3.11-bullseye`): Installs build tools (JDK, gcc, cmake,
   libtool, Bazelisk), clones ml-metadata at `v${MLMD_VERSION}`, applies patches,
   runs `python setup.py bdist_wheel`. The `setup.py` invokes Bazel internally to
   compile pybind11 C++ extensions.
3. **final** (`python:3.11-slim`): Installs the arm64 wheel from Stage 2, then installs
   remaining requirements from `requirements.txt` (pip skips ml-metadata — already
   satisfied by the wheel).

---

## Build Workflow

Trigger **Build MLMD arm64 Images** from GitHub Actions. Both jobs run in parallel
on the DGX native arm64 runner (`dgx` label).

| Input | Default | Notes |
|---|---|---|
| `pipeline_version` | `2.16.1` | Sets kfp-metadata-writer image tag |
| `mlmd_server_version` | `1.14.0` | ml_metadata_store_server version |
| `mlmd_wheel_version` | `1.17.0` | ml-metadata Python wheel version |

**Expected duration:** ~45–60 min per job on first run (fresh Bazel build). Docker
layer cache makes subsequent runs fast (seconds) unless the Dockerfile or source
version changes.

**When to re-run:** When bumping KFP version. Check the new version's
`manifests/kustomize/base/metadata/base/metadata-grpc-deployment.yaml` and
`backend/metadata_writer/requirements.txt` to find the new pinned versions, then
update all three workflow inputs.

---

## Deploy Order

```
1. Build MLMD arm64 Images    (once per version; cached on repeat)
2. Kubeflow Undeploy          (clean slate)
3. Kubeflow Deploy            (applies kustomize + patches MLMD + creates pull secret)
```

`deploy-kubeflow.sh`:
- Verifies both arm64 images exist on GHCR (pre-flight)
- Applies the KFP kustomize manifests
- Removes the amd64-only `controller-manager`
- Patches both MLMD deployments with the arm64 images
- Creates a `ghcr-pull-secret` docker-registry secret in the `kubeflow` namespace
  (from the short-lived `GITHUB_TOKEN` with `packages:read`) so pods can pull from
  the private GHCR registry
- Adds `imagePullSecrets` to both MLMD deployments

**Note on the pull secret:** `GITHUB_TOKEN` expires after the workflow run. Re-running
**Kubeflow Deploy** refreshes the secret. If MLMD pods enter `ImagePullBackOff` after
extended time without a redeploy, run the deploy workflow again.

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

Restart the port-forward service and open the UI:

```sh
# On DGX:
systemctl --user restart kubeflow-portfwd

# SSH tunnel from laptop:
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# open http://localhost:8080
```

Create a pipeline run via the UI and verify the run's **Input/Output Artifacts** tab
shows artifact metadata — this confirms the full MLMD write path is working.

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
