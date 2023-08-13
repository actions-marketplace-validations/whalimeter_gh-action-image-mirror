#!/bin/sh

# Failsafe mode: stop on errors and unset vars
set -eu

# Root directory where this script is located
MIRROR_ROOTDIR=${MIRROR_ROOTDIR:-"$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"}

# Target registry and path, default to the GHCR
MIRROR_REGISTRY=${MIRROR_REGISTRY:-"ghcr.io"}

# Regular expression matching the tags of the image(s) that we want to mirror
MIRROR_TAGS=${MIRROR_TAGS:-'[0-9]+(\.[0-9]+)+$'}

# Do not perform operation, just print what would be done on stderr
MIRROR_DRYRUN=${MIRROR_DRYRUN:-0}

# Minimum version that the image at the Hub must have to be downloaded and
# mirrored.
MIRROR_MINVER=${MIRROR_MINVER:-"0.0.0"}

# Verbosity level
MIRROR_VERBOSE=${MIRROR_VERBOSE:-0}

usage() {
  # This uses the comments behind the options to show the help. Not extremly
  # correct, but effective and simple.
  echo "$0 mirrors docker images from the Docker Hub to another registry" && \
    grep "[[:space:]].)\ #" "$0" |
    sed 's/#//' |
    sed -r 's/([a-z-])\)/-\1/'
  printf \\nEnvironment:\\n
  set | grep '^MIRROR_' | sed 's/^MIRROR_/    MIRROR_/g'
  exit "${1:-0}"
}

while getopts "m:nr:t:vh-" opt; do
  case "$opt" in
    r) # Root of the target registry
      MIRROR_REGISTRY="$OPTARG";;
    t) # Regular expression for tags to mirror
      MIRROR_TAGS="$OPTARG";;
    m) # Minimum version, older version will not be mirrored
      MIRROR_MINVER="$OPTARG";;
    n) # Do not perform operations
      MIRROR_DRYRUN=1;;
    -) # End of options, everything are the names of the images to mirror
      break;;
    v) # Turn on verbosity, will otherwise log on errors/warnings only
      MIRROR_VERBOSE=1;;
    h) # Print help and exit
      usage;;
    ?)
      usage 1;;
  esac
done
shift $((OPTIND-1))

# PML: Poor Man's Logging
_log() {
    printf '[%s] [%s] [%s] %s\n' \
      "$(basename "$0")" \
      "${2:-LOG}" \
      "$(date +'%Y%m%d-%H%M%S')" \
      "${1:-}" \
      >&2
}
# shellcheck disable=SC2015 # We are fine, this is just to never fail
trace() { [ "$MIRROR_VERBOSE" -ge "2" ] && _log "$1" DBG || true ; }
# shellcheck disable=SC2015 # We are fine, this is just to never fail
verbose() { [ "$MIRROR_VERBOSE" -ge "1" ] && _log "$1" NFO || true ; }
warn() { _log "$1" WRN; }
error() { _log "$1" ERR && exit 1; }

# Check the commands passed as parameters are available and exit on errors.
check_command() {
  for cmd; do
    if ! command -v "$cmd" >/dev/null; then
      error "$cmd not available. This is a stringent requirement. Cannot continue!"
    fi
  done
}

mirror() {
  resolved=$(img_canonicalize "$1")
  if [ "${resolved%%/*}" != "docker.io" ]; then
    error "$1 is not at the Docker Hub"
  fi

  for tag in $(img_tags --filter "$MIRROR_TAGS" -- "$1"); do
    semver=$(printf %s\\n "$tag" | grep -oE '[0-9]+(\.[0-9]+)+')
    if [ "$(img_version "$semver")" -ge "$(img_version "$MIRROR_MINVER")" ]; then
      # Detect if image present, download if not
      notag=${resolved%:*}
      img="${notag}:$tag"
      if docker image inspect >/dev/null 2>&1; then
        rm_img=0
      else
        if [ "$MIRROR_DRYRUN" = 1 ]; then
          verbose "Would pull image $img"
        else
          docker image pull "$img"
        fi
        rm_img=1
      fi

      # Decide upon name of destination image. When the destination registry has
      # a slash, just use the tail (name) of the image and prepend the registry
      # path.
      if printf %s\\n "$MIRROR_REGISTRY" | grep -q '/'; then
        name=${img##*/}
        destimg=${MIRROR_REGISTRY%/}/$name
      else
        rootless=${img#*/}
        destimg=${MIRROR_REGISTRY%/}/$rootless
      fi

      # Retag downloaded image to be as destination and push
      if [ "$MIRROR_DRYRUN" = 1 ]; then
        verbose "Would push image $destimg"
      else
        docker image tag "$img" "$destimg"
        docker image push "$destimg"
      fi

      # Cleanup
      if [ "$rm_img" = 1 ]; then
        if [ "$MIRROR_DRYRUN" = 1 ]; then
          verbose "Would remove image $img"
        else
          docker image rm "$img"
        fi
      fi
      if [ "$MIRROR_DRYRUN" = 1 ]; then
        verbose "Would remove image $destimg"
      else
        docker image rm "$destimg"
      fi
    else
      verbose "Discarding version $semver, older than $MIRROR_MINVER"
    fi
  done
}

# Source Docker Hub image API library
# shellcheck disable=SC1091 # Comes as a submodule
. "${MIRROR_ROOTDIR}/reg-tags/image_api.sh"

# Verify we have the docker client
check_command docker

while [ "$#" -gt 0 ]; do
  mirror "$1"
  shift
done