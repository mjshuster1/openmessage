#!/bin/sh
# Builds the files a VM installs from and publishes them as a GitHub release.
#
#   cloud/vm/release-vm.sh <tag> [owner/repo]     (default repo: mjshuster1/openmessage)
#
# Assets: openmessage-linux-amd64.tar.gz, openmessage-linux-arm64.tar.gz
# (the binary, same layout as .github/workflows/release.yml),
# openmessage-vm.tar.gz (this folder's units and scripts, under vm/), the
# client Reconnect app (om-reconnect-mac.zip, om-reconnect-windows.exe) and
# SHA256SUMS. startup.sh downloads these and checks them against SHA256SUMS.
#
# Why not just push a tag: the release workflow has never run on the fork
# (Actions shows zero runs), and it also builds and signs the macOS app, which
# a VM doesn't need. This builds the Linux binaries locally from the committed
# HEAD instead. Needs go, gh (signed in), and a clean tree.
set -eu

TAG=${1:?usage: release-vm.sh <tag> [owner/repo]}
REPO=${2:-mjshuster1/openmessage}
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$ROOT"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Commit or stash changes first: the release must match a pushed commit." >&2
  exit 1
fi
COMMIT=$(git rev-parse HEAD)
if ! git branch -r --contains "$COMMIT" | grep -q .; then
  echo "HEAD $COMMIT isn't on any remote branch; push it first." >&2
  exit 1
fi

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
for arch in amd64 arm64; do
  mkdir -p "$OUT/$arch"
  GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=$arch \
    go build -trimpath -ldflags "-s -w -X main.version=$TAG" -o "$OUT/$arch/openmessage" .
  tar -C "$OUT/$arch" -czf "$OUT/openmessage-linux-$arch.tar.gz" openmessage
done
# Tracked files only, so a stray binary or cookie file in cloud/vm never ships.
git archive --format=tar --prefix=vm/ HEAD:cloud/vm | gzip -n > "$OUT/openmessage-vm.tar.gz"
# The client's Reconnect app (the Reconnect page links to these by name).
"$ROOT/cloud/reconnect-app/build.sh" "$OUT" "$TAG"
(cd "$OUT" && shasum -a 256 openmessage-linux-amd64.tar.gz openmessage-linux-arm64.tar.gz openmessage-vm.tar.gz \
  om-reconnect-mac.zip om-reconnect-windows.exe > SHA256SUMS)
cat "$OUT/SHA256SUMS"

gh release create "$TAG" --repo "$REPO" --target "$COMMIT" \
  --title "OpenMessage $TAG (VM)" \
  --notes "Linux binaries and VM files built from $COMMIT for cloud/vm/create-vm.sh. Built locally with cloud/vm/release-vm.sh." \
  "$OUT/openmessage-linux-amd64.tar.gz" "$OUT/openmessage-linux-arm64.tar.gz" \
  "$OUT/openmessage-vm.tar.gz" "$OUT/om-reconnect-mac.zip" "$OUT/om-reconnect-windows.exe" "$OUT/SHA256SUMS"
echo "Released $TAG on $REPO. Create a VM with: cloud/vm/create-vm.sh --release $TAG"
