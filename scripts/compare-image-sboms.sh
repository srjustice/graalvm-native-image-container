#!/usr/bin/env bash
#
# Compare what is installed in two OCI images by reading the Software Bill of
# Materials that Cloud Native Buildpacks embed in each image, plus the base
# image's dpkg database. This is a fallback for when `syft` or `pack` are not
# installed; it reads the very same embedded SBOMs those tools would.
#
# Per image it reports three buckets and the differences between them:
#   * OS / system packages          (/var/lib/dpkg/status.d/*)
#   * Java libraries baked in        (CycloneDX  /layers/sbom/**/*.cdx.json)
#   * Buildpack-contributed runtime  (Syft       /layers/sbom/**/*.syft.json)
#
# Requirements: podman and jq. Rootless Podman is handled automatically by
# re-executing under `podman unshare` so the image filesystem can be mounted.
#
# Usage:
#   scripts/compare-image-sboms.sh [IMAGE_A] [IMAGE_B]
#
# Defaults compare the two images this project builds:
#   IMAGE_A = hello-world:0.0.1-SNAPSHOT-jvm
#   IMAGE_B = hello-world:0.0.1-SNAPSHOT-native
set -uo pipefail

image_a="${1:-hello-world:0.0.1-SNAPSHOT-jvm}"
image_b="${2:-hello-world:0.0.1-SNAPSHOT-native}"

command -v podman >/dev/null 2>&1 || { echo "error: podman is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

# Mounting an image filesystem rootless must happen inside a Podman user
# namespace. Re-exec once under `podman unshare` (root already has access).
if [ "$(id -u)" -ne 0 ] && [ -z "${SBOM_COMPARE_REEXEC:-}" ]; then
    exec podman unshare -- env SBOM_COMPARE_REEXEC=1 bash "$0" "$image_a" "$image_b"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

collect() {
    local image="$1" prefix="$2" mnt f
    mnt="$(podman image mount "$image")" || {
        echo "error: could not mount '$image' (is it built and present locally?)" >&2
        exit 1
    }

    # OS / system packages: one dpkg control file per package under status.d
    {
        for f in "$mnt"/var/lib/dpkg/status.d/*; do
            [[ "$f" == *.md5sums ]] && continue
            [[ -f "$f" ]] || continue
            awk -F': ' '/^Package:/{p=$2} /^Version:/{v=$2} END{if(p)print p" "v}' "$f"
        done
    } 2>/dev/null | sort -u > "$prefix.os"

    # Java libraries: CycloneDX components that carry a version
    {
        while IFS= read -r -d '' f; do
            jq -r '.components[]? | select(.version) | "\(.name) \(.version)"' "$f" 2>/dev/null
        done < <(find "$mnt/layers/sbom" -name '*.cdx.json' -print0 2>/dev/null)
    } | sort -u > "$prefix.jars"

    # Buildpack-contributed runtime/toolchain: Syft artifacts (capitalized keys)
    {
        while IFS= read -r -d '' f; do
            jq -r '.Artifacts[]? | "\(.Name) \(.Version)"' "$f" 2>/dev/null
        done < <(find "$mnt/layers/sbom" -name '*.syft.json' -print0 2>/dev/null)
    } | sort -u > "$prefix.rt"

    podman image unmount "$image" >/dev/null
}

collect "$image_a" "$workdir/a"
collect "$image_b" "$workdir/b"

section() { printf '\n########## %s ##########\n' "$1"; }

echo "A = $image_a"
echo "B = $image_b"

section "OS / system packages"
echo "counts -> A: $(wc -l < "$workdir/a.os")   B: $(wc -l < "$workdir/b.os")"
echo "--- in BOTH ---"; comm -12 "$workdir/a.os" "$workdir/b.os"
echo "--- A only ---";  comm -23 "$workdir/a.os" "$workdir/b.os"
echo "--- B only ---";  comm -13 "$workdir/a.os" "$workdir/b.os"

section "Buildpack-contributed runtime / toolchain (Syft)"
echo "--- in BOTH ---"; comm -12 "$workdir/a.rt" "$workdir/b.rt"
echo "--- A only ---";  comm -23 "$workdir/a.rt" "$workdir/b.rt"
echo "--- B only ---";  comm -13 "$workdir/a.rt" "$workdir/b.rt"

section "Java libraries baked in (CycloneDX)"
echo "counts -> A: $(wc -l < "$workdir/a.jars")   B: $(wc -l < "$workdir/b.jars")"
echo "--- A only ---";  comm -23 "$workdir/a.jars" "$workdir/b.jars"
echo "--- B only ---";  comm -13 "$workdir/a.jars" "$workdir/b.jars"
echo "(no entries under A only / B only above = identical dependency set)"
