#!/bin/bash

set -eu

readonly ERR_CODE=127

readonly CRI_TYPE=${criType?}
readonly KUBE_TYPE=${kubeType:-k8s}

readonly IMAGE_HUB_REGISTRY=${registry?}
readonly IMAGE_HUB_REPO=${repo?}
readonly IMAGE_HUB_USERNAME=${username?}
readonly IMAGE_HUB_PASSWORD=${password?}
readonly IMAGE_CACHE_NAME="ghcr.io/labring-fix/cache"

readonly IMAGE_TAG=${version?}
readonly KUBE_RAW="${IMAGE_TAG%%-*}"
readonly KUBE="${KUBE_RAW#v}"
readonly KUBE_XY="${KUBE%.*}"
if [[ "${sealoslatest:-}" == latest ]]; then
  export sealosPatch="ghcr.io/labring/sealos-patch:latest"
  sealoslatest=$(until curl -sL "https://api.github.com/repos/labring/sealos/releases/latest" | grep tarball_url; do sleep 3; done | awk -F\" '{print $(NF-1)}' | awk -F/ '{print $NF}' | cut -dv -f2)
fi
readonly sealoslatest="${sealoslatest:-${IMAGE_TAG#*-}}"
readonly SEALOS=${sealoslatest?}
readonly SEALOS_PATCH="${sealosPatch:-}"

# NOTE (fork fix): resolve the newest sealos tag with git ls-remote, not the
# GitHub REST API (see .github/scripts/versions/versions_sealos.sh).
# The REST call has no auth token, so a shared runner IP easily hits the
# 60 req/hour unauthenticated rate limit; curl still exits 0 on HTTP 403,
# so the until-loop exits at once, grep finds no tarball_url, the check
# yields an empty string and the bare tags are silently skipped — the K3S
# part 5 re-run missed 4 bare tags this way. git ls-remote has no such
# limit. Bounded: 10 tries, then empty (bare tags skipped, same as before;
# the -5.1.2 tags are unaffected).
latest_sealos_version() {
  local tags tries=0
  until tags=$(git ls-remote --refs --sort="-version:refname" --tags "https://github.com/labring/sealos.git" | cut -d/ -f3- | grep -E "^v[0-9.]+$"); do
    tries=$((tries + 1))
    if [[ $tries -ge 10 ]]; then
      echo "failed to list labring/sealos tags after 10 tries" >&2
      return 0
    fi
    sleep 3
  done
  echo "$tags" | head -n 1 | cut -dv -f2
}

readonly SEALOS_XYZ="${SEALOS%%-*}"
if [[ "${SEALOS_XYZ//./}" -le 433 ]] && [[ $KUBE_TYPE == k3s ]] && [[ -z "$SEALOS_PATCH" ]]; then
  echo "INFO::skip $KUBE(build for k3s) when $SEALOS(sealos<=4.3.3)"
  exit
fi
readonly kube_major="${KUBE%.*}"
readonly sealos_major="${SEALOS%%-*}"
if [[ "${kube_major//./}" -ge 126 ]]; then
  if ! [[ "${sealos_major//./}" -le 413 ]] || [[ -n "$SEALOS_PATCH" ]]; then
    echo "Verifying the availability of unstable"
  else
    echo "INFO::skip kube(>=1.26) building when sealos <= 4.1.3"
    exit
  fi
  FROM_CRI=$(sudo buildah from "$IMAGE_CACHE_NAME:cri-amd64")
  MOUNT_CRI=$(sudo buildah mount "$FROM_CRI")
  case $CRI_TYPE in
  containerd)
    # Fork fix: the upstream cache image no longer ships cri/.versions at this path.
    # A missing file used to make this script exit 0 silently, so the manifest was
    # never created/pushed while the job still reported success. Warn and continue
    # instead; the containerd version comes from the cache cri image build.
    if [ -f "$MOUNT_CRI/cri/.versions" ]; then
      # Accept v1.6+ and any v2+ (no pinned major line; see cache cri script).
      if ! [[ "$(sudo cat "$MOUNT_CRI"/cri/.versions | grep CONTAINERD | awk -F= '{print $NF}')" =~ (v1\.([6-9]|[0-9][0-9])\.[0-9]+|v[2-9][0-9]*\.[0-9]+\.[0-9]+) ]]; then
        echo https://kubernetes.io/blog/2022/11/18/upcoming-changes-in-kubernetes-1-26/#cri-api-removal
        exit $ERR_CODE
      fi
    else
      echo "WARNING::cri/.versions not found in cache image, skipping containerd version check"
    fi
    ;;
  docker)
    if [ -f "$MOUNT_CRI/cri/.versions" ]; then
      # Accept v0.3+ and any v1+ (no pinned major line).
      if ! [[ "$(sudo cat "$MOUNT_CRI"/cri/.versions | grep CRIDOCKER | awk -F= '{print $NF}')" =~ (v0\.[3-9]\.[0-9]+|v[1-9][0-9]*\.[0-9]+\.[0-9]+) ]]; then
        echo https://github.com/Mirantis/cri-dockerd/issues/125
        exit $ERR_CODE
      fi
    else
      echo "WARNING::cri/.versions not found in cache image, skipping cri-dockerd version check"
    fi
    ;;
  esac
fi

case $CRI_TYPE in
containerd | cri-o)
  if [[ "${SEALOS_XYZ%%.*}" -ge 5 ]] && ! [[ "${KUBE_XY//./}" -ge 124 ]]; then
    echo "INFO::skip $KUBE(kube<1.24) when $SEALOS(sealos>=5)"
    exit
  fi
  ;;
docker)
  if [[ "${SEALOS_XYZ%%.*}" -ge 5 ]] && ! [[ "${KUBE_XY//./}" -ge 126 ]]; then
    echo "INFO::skip $KUBE(kube<1.26) when $SEALOS(sealos>=5)"
    exit
  fi
  ;;
esac
case $CRI_TYPE in
containerd)
  IMAGE_KUBE=kubernetes
  ;;
cri-o)
  IMAGE_KUBE=kubernetes-crio
  ;;
docker)
  IMAGE_KUBE=kubernetes-docker
  ;;
esac
if grep k3s <<<"$KUBE"; then
  IMAGE_KUBE=k3s
fi

if ! [[ "$SEALOS" =~ ^[0-9\.]+[0-9]$ ]] || [[ -n "$SEALOS_PATCH" ]]; then
  IMAGE_TAGS="v${KUBE%.*}-amd64,v${KUBE%.*}-arm64"
  IMAGE_PUSH_NAME=(
    "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE%.*}-latest"
  )
else
  IMAGE_TAGS="v${KUBE%+*}-$SEALOS-amd64,v${KUBE%+*}-$SEALOS-arm64"
  if [[ "$SEALOS" == "$(latest_sealos_version)" ]]; then
    IMAGE_PUSH_NAME=(
      "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE%+*}"
      "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE%+*}-$SEALOS"
    )
  else
    IMAGE_PUSH_NAME=(
      "$IMAGE_HUB_REGISTRY/$IMAGE_HUB_REPO/$IMAGE_KUBE:v${KUBE%+*}-$SEALOS"
    )
  fi
fi

sudo buildah login -u "$IMAGE_HUB_USERNAME" -p "$IMAGE_HUB_PASSWORD" "$IMAGE_HUB_REGISTRY"
for IMAGE_NAME in "${IMAGE_PUSH_NAME[@]}"; do
  echo "$IMAGE_TAGS" | sed "s~,~\n~g" | while read -r tag; do
    echo "${IMAGE_NAME%:*}:$tag"
  done | xargs sudo buildah manifest create --all "mf:${KUBE%+*}-$SEALOS" || exit $ERR_CODE
  if [[ $(sudo buildah inspect "mf:${KUBE%+*}-$SEALOS" | yq .manifests[].platform.architecture | uniq | grep 64 -c) -eq 2 ]]; then
    # Fork fix: upstream pushes the combined manifest to docker.io/labring, which needs
    # D_REGISTRY_TOKEN and the labring namespace (this fork owns neither); without that
    # token it printed a warning and skipped the push entirely, so no combined tag
    # (e.g. v1.33.6-5.1.1) was ever published. Push it to GHCR instead, where this
    # job is already logged in above.
    sudo buildah manifest push --rm --all "mf:${KUBE%+*}-$SEALOS" "docker://$IMAGE_NAME" && echo "$IMAGE_NAME push success"
  else
    sudo buildah manifest inspect "mf:${KUBE%+*}-$SEALOS" | yq -CP
    echo "ERROR::TARGETARCH for sealos build"
    sudo buildah images
    exit $ERR_CODE
  fi
done

sudo buildah images
