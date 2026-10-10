# catalog.Dockerfile: OLM v1 file-based catalog image (design brief D6).
# catalogd reads only the directory named by the configs label; no opm binary or cache is needed.
# Build context is the repository root after `make fbc` wrote dist/catalog/.
# For an OpenShift binary build (test/cluster/full-run.sh) the same file is staged as `Dockerfile`
# next to a `dist/catalog/` copy, so the COPY path is identical.
FROM scratch
LABEL operators.operatorframework.io.index.configs.v1=/configs
COPY dist/catalog /configs
