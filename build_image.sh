#!/bin/bash
set -e

export DOCKER_DEFAULT_PLATFORM=linux/amd64

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISTRO="ubuntu2604"
KERNEL_SRC=""
CLEAN=false
IMG_SIZE=12000
KERNEL_ONLY=false
PATCHES_REF="v1.0"

MULTI_DISTROS="ubuntu2604 arch alpine cachyos"

usage() {
    echo "Usage: $0 [--distro <distro>] [--kernel <path>] [--img-size <MB>] [--clean]"
    echo ""
    echo "Options:"
    echo "  --distro     Distribution to build: ubuntu2604, arch, cachyos, alpine, all (default: ubuntu2604)"
    echo "  --kernel     Path to kernel source directory (default: auto-clone to work/linux/)"
    echo "  --img-size   Disk image size in MB (default: 12000, 32000 for --distro all)"
    echo "  --clean      Remove all cached build artifacts and start from scratch"
    echo "  --kernel-only  Build and package the kernel only, then exit"
    echo "  --patches-ref  Branch, tag, or commit SHA for patches (default: v1.0)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --distro)    DISTRO="$2";          shift 2 ;;
        --kernel)    KERNEL_SRC="$2";      shift 2 ;;
        --img-size)  IMG_SIZE="$2";        shift 2 ;;
        --clean)     CLEAN=true;           shift ;;
        --kernel-only) KERNEL_ONLY=true;   shift ;;
        --patches-ref) [ -n "$2" ] && PATCHES_REF="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
LINUX_DEFAULT_DIR="$SCRIPT_DIR/work/linux"

PATCHES_REPO="https://github.com/ps5-linux/ps5-linux-patches.git"
PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches"

if [ -z "$KERNEL_SRC" ]; then
    KERNEL_SRC="$LINUX_DEFAULT_DIR"
fi

KERNEL_OUT="$SCRIPT_DIR/linux-bin"
OUTPUT_DIR="$SCRIPT_DIR/output"
CHROOT_DIR="$SCRIPT_DIR/work/chroot"
CACHE_DIR="$SCRIPT_DIR/work/cache"
CCACHE_DIR="${CCACHE_DIR:-$SCRIPT_DIR/ccache}"
LOG_FILE="$SCRIPT_DIR/build.log"
DOCKER_NAME="ps5-build-$$"



if [ "$DISTRO" = "all" ] && [ "$IMG_SIZE" = "12000" ]; then
    IMG_SIZE=32000
fi

if [ -z "$FORMAT" ]; then
    case "$DISTRO" in arch) FORMAT="arch" ;; all) FORMAT="all" ;; *) FORMAT="deb" ;; esac
fi

KERNEL_BUILDER_PLATFORM="linux/amd64"
case "$(uname -m)" in
    aarch64|arm64) KERNEL_BUILDER_PLATFORM="linux/arm64" ;;
esac

# --- Signal trap: clean up docker containers and background jobs on exit ---
BUILD_PID=""

cleanup() {
    echo ""
    echo "Interrupted. Cleaning up..."
    docker kill "$DOCKER_NAME" 2>/dev/null || true
    [ -n "$BUILD_PID" ] && kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
    exit 130
}
trap cleanup INT TERM

# --- Clean ---
if [ "$CLEAN" = true ]; then
    echo "Cleaning all build artifacts..."
    for dir in "$SCRIPT_DIR/work" "$KERNEL_OUT" "$SCRIPT_DIR/cache" "$OUTPUT_DIR"; do
        [ -d "$dir" ] && docker run --rm \
            -v "$(dirname "$dir")":/parent \
            alpine rm -rf "/parent/$(basename "$dir")"
    done
    echo "Done."
    echo ""
fi

# --- Auto-detect what can be skipped ---
SKIP_KERNEL=false
SKIP_CHROOT=false

case "$FORMAT" in
    arch) ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    all)  ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && \
          ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    *)    ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
esac

if [ "$DISTRO" = "all" ]; then
    SKIP_CHROOT=true
    for d in $MULTI_DISTROS; do
        [ -d "$SCRIPT_DIR/work/chroot-$d/bin" ] || SKIP_CHROOT=false
    done
else
    [ -d "$CHROOT_DIR/bin" ] && SKIP_CHROOT=true
fi

# --- Build plan summary ---
echo ""
echo "PS5 Linux Image Builder"
echo "======================="
if [ "$KERNEL_ONLY" = true ]; then
    echo "  Mode:         kernel only"
    echo "  Format:       $FORMAT"
else
    echo "  Distro:       $DISTRO"
    [ "$DISTRO" = "all" ] && echo "                ($MULTI_DISTROS)"
    echo "  Image size:   ${IMG_SIZE}MB"
fi
if [ -f "$PATCHES_DIR/.config" ]; then
    LINUX_BRANCH="v$(grep -m1 "^# Linux/" "$PATCHES_DIR/.config" | grep -oP '\d+\.\d+(\.\d+)?')"
    echo "  Kernel:       $LINUX_BRANCH"
else
    echo "  Kernel:       (will fetch)"
fi
echo "  Kernel src:   $KERNEL_SRC"
echo ""
echo "Stages:"
if [ "$SKIP_KERNEL" = true ]; then
    echo "  1. Kernel            cached"
elif [ -d "$KERNEL_SRC/.git" ]; then
    echo "  1. Kernel            build (source cached)"
else
    echo "  1. Kernel            clone + build"
fi
if [ "$KERNEL_ONLY" = false ]; then
    if [ "$SKIP_CHROOT" = true ]; then
        echo "  2. Root filesystem   cached"
    else
        echo "  2. Root filesystem   build"
    fi
    echo "  3. Disk image        build"
fi
echo ""
echo "Logs: $LOG_FILE"
echo ""

# --- Logging + stage runner ---
: > "$LOG_FILE"

SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

run_stage() {
    local name="$1"
    shift

    if [ "${CI:-}" = "true" ]; then
        echo "::group::$name"
        local rc=0
        "$@" || rc=$?
        echo "::endgroup::"
        if [ $rc -ne 0 ]; then
            echo "::error::Build failed at: $name"
            exit $rc
        fi
        return
    fi

    local status_msg="$name"
    local spin_i=0

    # Record log position so we only scan new lines for status updates
    local log_start
    log_start=$(wc -l < "$LOG_FILE")

    # Run command in background
    "$@" >> "$LOG_FILE" 2>&1 &
    BUILD_PID=$!

    # Spinner loop — pick up === status lines from the log
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        if (( spin_i % 10 == 0 )); then
            local new
            new=$(tail -n +$((log_start + 1)) "$LOG_FILE" 2>/dev/null \
                | grep -oP '(?<=^=== ).*(?= ===$)' | tail -1)
            [ -n "$new" ] && status_msg="$new"
        fi
        printf "\r  %s %-60s" "${SPIN_CHARS:spin_i%${#SPIN_CHARS}:1}" "$status_msg"
        spin_i=$((spin_i + 1))
        sleep 0.1
    done

    local rc=0
    wait "$BUILD_PID" || rc=$?
    BUILD_PID=""

    if [ $rc -eq 0 ]; then
        printf "\r  ✓ %-60s\n" "$name"
    else
        printf "\r  ✗ %-60s\n" "$status_msg"
        echo ""
        echo "Build failed at: $status_msg"
        echo "Logs: $LOG_FILE"
        echo "Try running with --clean to start fresh."
        exit 1
    fi
}

# --- Setup directories ---
mkdir -p "$KERNEL_OUT" "$OUTPUT_DIR" "$CHROOT_DIR" "$CACHE_DIR" "$CCACHE_DIR"
if [ "$DISTRO" = "all" ]; then
    for d in $MULTI_DISTROS; do
        mkdir -p "$SCRIPT_DIR/work/chroot-$d"
    done
fi

# --- Step 1: Kernel ---
if [ "$SKIP_KERNEL" = true ]; then
    printf "  ✓ %-60s\n" "Kernel packages (cached)"
else
    if [ ! -d "$KERNEL_SRC/.git" ]; then
        REPO_URL="$PATCHES_REPO"
        [ -n "$PATCHES_TOKEN" ] && REPO_URL="${PATCHES_REPO/https:\/\//https:\/\/${PATCHES_TOKEN}@}"


        mkdir -p "$PATCHES_DIR"
        run_stage "Fetch ps5-linux-patches ($PATCHES_REF)" bash -c '
            cd "'"$PATCHES_DIR"'"
            [ ! -d .git ] && git init && git remote add origin "'"$REPO_URL"'"
            git fetch --depth 1 origin "'"$PATCHES_REF"'" || git fetch origin "'"$PATCHES_REF"'"
            git reset --hard FETCH_HEAD
        '
        LINUX_TMP_DIR="${LINUX_DEFAULT_DIR}.tmp"
        for dir in "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"; do
            [ -d "$dir" ] && docker run --rm \
                -v "$(dirname "$dir")":/parent \
                alpine rm -rf "/parent/$(basename "$dir")"
        done
        LINUX_BRANCH="v$(grep -m1 "^# Linux/" "$PATCHES_DIR/.config" | grep -oP '\d+\.\d+(\.\d+)?')"

        run_stage "Clone kernel $LINUX_BRANCH" \
            git clone --branch "$LINUX_BRANCH" --depth 1 "$LINUX_REPO" "$LINUX_TMP_DIR"

        run_stage "Apply patches" bash -c '
            set -e; shopt -s nullglob
            patches=("'"$PATCHES_DIR"'"/*.patch)
            [ ${#patches[@]} -eq 0 ] && { echo "No .patch files found in '"$PATCHES_DIR"'"; exit 1; }
            for p in "${patches[@]}"; do
                echo "Applying $p"
                git -C "'"$LINUX_TMP_DIR"'" apply --exclude=Makefile "$p"
            done'

        run_stage "Copy kernel config" \
            cp "$PATCHES_DIR/.config" "$LINUX_TMP_DIR/.config"

        mv "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"
        KERNEL_SRC="$LINUX_DEFAULT_DIR"
    else
        printf "  ✓ %-60s\n" "Kernel source (cached)"
    fi

    KERNEL_SRC="$(cd "$KERNEL_SRC" && pwd)"

    rm -f "$KERNEL_OUT"/*.deb "$KERNEL_OUT"/*.pkg.tar.zst

    run_stage "Build kernel builder image" \
        docker build --platform "$KERNEL_BUILDER_PLATFORM" -t ps5-kernel-builder \
            -f "$SCRIPT_DIR/docker/kernel-builder/Dockerfile" "$SCRIPT_DIR"

    run_stage "Compile kernel" \
        docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
            -v "$KERNEL_SRC":/src \
            -v "$KERNEL_OUT":/out \
            -v "$CCACHE_DIR":/ccache \
            ps5-kernel-builder

    ls "$KERNEL_OUT/staging/lib/modules/" | head -1 > "$KERNEL_OUT/VERSION"

    case "$FORMAT" in deb|all)
        run_stage "Package kernel (.deb)" \
            docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
                -v "$KERNEL_SRC":/src \
                -v "$KERNEL_OUT":/out \
                -v "$CCACHE_DIR":/ccache \
                ps5-kernel-builder \
                /package-deb.sh
    esac

    case "$FORMAT" in arch|all)
        run_stage "Build arch packager image" \
            docker build -t ps5-kernel-packager-arch \
                -f "$SCRIPT_DIR/docker/kernel-builder-arch/Dockerfile" "$SCRIPT_DIR"
        run_stage "Package kernel (.pkg.tar.zst)" \
            docker run --rm --name "$DOCKER_NAME" \
                -v "$KERNEL_OUT":/out \
                ps5-kernel-packager-arch
    esac
fi

if [ "$KERNEL_ONLY" = true ]; then
    KVER=$(cat "$KERNEL_OUT/VERSION" 2>/dev/null || echo "unknown")
    echo ""
    echo "Done! Kernel $KVER packages in $KERNEL_OUT/"
    exit 0
fi

# --- Step 2: Build distribution image ---
run_stage "Build image builder image" \
    docker build -t ps5-image-builder -f "$SCRIPT_DIR/docker/image-builder/Dockerfile" "$SCRIPT_DIR"

if [ "$DISTRO" = "all" ]; then
    DOCKER_ARGS=(
        docker run --rm --privileged --name "$DOCKER_NAME"
        --entrypoint /entrypoint-multi.sh
        -v "$SCRIPT_DIR":/repo:ro
        -v "$KERNEL_OUT":/kernel-debs:ro
        -v "$OUTPUT_DIR":/output
        -v "$CACHE_DIR":/build/cache
        -e IMG_SIZE="$IMG_SIZE"
        -e SKIP_CHROOT="$SKIP_CHROOT"
        -e "DISTROS=$MULTI_DISTROS"
    )
    for d in $MULTI_DISTROS; do
        DOCKER_ARGS+=(-v "$SCRIPT_DIR/work/chroot-$d:/build/chroot-$d")
    done
    DOCKER_ARGS+=(ps5-image-builder)

    run_stage "Build multi-distro image (${IMG_SIZE}MB)" "${DOCKER_ARGS[@]}"

    IMG_PATH="$OUTPUT_DIR/ps5-multi.img"
else
    run_stage "Build $DISTRO image (${IMG_SIZE}MB)" \
        docker run --rm --privileged --name "$DOCKER_NAME" \
            -v "$SCRIPT_DIR":/repo:ro \
            -v "$KERNEL_OUT":/kernel-debs:ro \
            -v "$OUTPUT_DIR":/output \
            -v "$CHROOT_DIR":/build/chroot \
            -v "$CACHE_DIR":/build/cache \
            -e DISTRO="$DISTRO" \
            -e IMG_SIZE="$IMG_SIZE" \
            -e SKIP_CHROOT="$SKIP_CHROOT" \
            ps5-image-builder

    IMG_PATH="$OUTPUT_DIR/ps5-${DISTRO}.img"
fi

echo ""
echo "Done! Image: $IMG_PATH"
echo "Flash: sudo dd if=$IMG_PATH of=/dev/sdX bs=4M status=progress"
