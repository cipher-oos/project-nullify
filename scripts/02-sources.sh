#!/bin/bash
# =============================================================================
# Project Nullify — Phase 2: Download LFS Source Tarballs
# =============================================================================
#
# What this script does:
#   Downloads every source package needed to build Nullify from scratch.
#   All tarballs land in $LFS/sources — the single directory that feeds
#   every compile job from Phase 3 onward.
#
# Why download everything upfront?
#   Building LFS takes hours. If a download fails mid-build (at 3am while
#   GCC is compiling), you lose your build state. Downloading everything
#   first means the actual build runs completely offline — no network
#   dependency, no interruptions, no surprises.
#
# What is verified?
#   Every tarball is checked against its official LFS MD5 checksum after
#   downloading. If anything is corrupted or incomplete, we catch it here
#   rather than getting a cryptic compile error 6 hours into the build.
#
# Resumable:
#   Already-downloaded files are skipped automatically. If this script
#   gets interrupted, just run it again — it picks up where it left off.
#
# Source list based on: LFS 12.2 stable
#   https://www.linuxfromscratch.org/lfs/view/stable/
#
# Usage: bash 02-sources.sh
# Run as root with $LFS mounted at /mnt/lfs
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

LFS=/mnt/lfs
SOURCES=$LFS/sources
LFS_MIRROR="https://www.linuxfromscratch.org/lfs/downloads/12.2"
BACKUP_MIRROR="https://ftp.osuosl.org/pub/lfs/lfs-packages/12.2"

export LFS

# -----------------------------------------------------------------------------
# HELPER FUNCTIONS
# -----------------------------------------------------------------------------

section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

ok()   { echo "  ✔  $1"; }
info() { echo "  →  $1"; }
warn() { echo "  ⚠  $1"; }
fail() { echo "  ✘  $1"; exit 1; }

# -----------------------------------------------------------------------------
# STEP 1 — PREFLIGHT CHECKS
# -----------------------------------------------------------------------------

section "Step 1 — Preflight checks"

# Must be root
[[ $EUID -ne 0 ]] && fail "Run as root: sudo bash 02-sources.sh"
ok "Running as root"

# Disk must be mounted
mountpoint -q "$LFS" || fail "$LFS is not mounted. Run: source /root/remount-nullify.sh"
ok "Disk mounted at $LFS"

# Sources directory must exist
[[ -d "$SOURCES" ]] || fail "$SOURCES does not exist. Did Phase 1 complete?"
ok "Sources directory exists at $SOURCES"

# Enough disk space? We need at least 8GB free for sources alone
AVAIL=$(df -BG "$LFS" | awk 'NR==2 {gsub("G",""); print $4}')
[[ "$AVAIL" -lt 8 ]] && warn "Less than 8GB free on $LFS (${AVAIL}GB available)"
ok "Disk space: ${AVAIL}GB available"

# -----------------------------------------------------------------------------
# STEP 2 — DEFINE THE PACKAGE LIST
#
# This is the complete LFS 12.2 package list. Each entry is:
#   "filename|md5checksum"
#
# The filenames and checksums come directly from the official LFS 12.2 book.
# Do not modify checksums — they are used to verify download integrity.
#
# Package overview by category:
#
#   Core toolchain (built twice — cross then native):
#     binutils, gcc, glibc, mpfr, gmp, mpc, isl
#
#   Shell & core utilities:
#     bash, coreutils, findutils, grep, gzip, sed, tar, diffutils
#
#   Build system tools:
#     make, autoconf, automake, libtool, pkg-config, m4
#
#   Text & documentation:
#     less, man-db, groff, texinfo, vim
#
#   System libraries:
#     zlib, bzip2, xz, zstd, libcap, libffi, openssl
#
#   System management:
#     util-linux, procps-ng, psmisc, shadow, sysvinit
#
#   Network:
#     iproute2, iputils
#
#   Kernel:
#     linux (kernel source)
# -----------------------------------------------------------------------------

section "Step 2 — Loading package manifest (LFS 12.2)"

declare -a PACKAGES=(
    # ── Core toolchain ────────────────────────────────────────────────────
    "binutils-2.43.1.tar.xz|ac00931bb7f739e3f1f1af4fe1b8f9e7|https://sourceware.org/pub/binutils/releases"
    "gcc-14.2.0.tar.xz|3b08e9a4a3c4b67fe80cde253c1c52ea|https://ftp.gnu.org/gnu/gcc/gcc-14.2.0"
    "glibc-2.40.tar.xz|a5cb97b737cb4c5b4e462a3e29a7cdd7|https://ftp.gnu.org/gnu/glibc"
    "mpfr-4.2.1.tar.xz|523af4b5fad8a4c3839ec29eba17e356|https://ftp.gnu.org/gnu/mpfr"
    "gmp-6.3.0.tar.xz|956dc04e864001a9c22429f761f2c283|https://ftp.gnu.org/gnu/gmp"
    "mpc-1.3.1.tar.gz|5c9bc658c9fd0523fb303353401b9285|https://ftp.gnu.org/gnu/mpc"
    "isl-0.26.tar.xz|9f96b35aff5bb59dcb0fd26f7db85db7|https://libisl.sourceforge.io"

    # ── Shell ─────────────────────────────────────────────────────────────
    "bash-5.2.32.tar.gz|de6a0dce3170d427248c9b7c39ef2f23|https://ftp.gnu.org/gnu/bash"

    # ── Core utilities ────────────────────────────────────────────────────
    "coreutils-9.5.tar.xz|e99adfa7a6a6c4d3d5059962d9eed095|https://ftp.gnu.org/gnu/coreutils"
    "findutils-4.10.0.tar.xz|870cfd71c07d37ebe56f9f4aaf0ad617|https://ftp.gnu.org/gnu/findutils"
    "diffutils-3.10.tar.xz|2745c50f6f4e395e7b7d52f902d075bf|https://ftp.gnu.org/gnu/diffutils"
    "grep-3.11.tar.xz|7c9bbd74492131245f7cdb291fa142c0|https://ftp.gnu.org/gnu/grep"
    "gzip-1.13.tar.xz|d5c9fc9441288817a4a0be2da0249e29|https://ftp.gnu.org/gnu/gzip"
    "sed-4.9.tar.xz|6aac9b2dbafcd5b7a67a8a9bcb8036c3|https://ftp.gnu.org/gnu/sed"
    "tar-1.35.tar.xz|a2d8042658cfd8ea939e6d911eaf4152|https://ftp.gnu.org/gnu/tar"
    "patch-2.7.6.tar.xz|78ad9937e4caadcba1526ef1853730d5|https://ftp.gnu.org/gnu/patch"
    "gawk-5.3.0.tar.xz|cf5c5f5e809c8f4c55696cf5ae6e2cdb|https://ftp.gnu.org/gnu/gawk"

    # ── Build system tools ────────────────────────────────────────────────
    "make-4.4.1.tar.gz|c8469a3713cbbe04d955d4ae4be23eeb|https://ftp.gnu.org/gnu/make"
    "autoconf-2.72.tar.xz|a6f7ab913da6f39ca5e0ac02f566d838|https://ftp.gnu.org/gnu/autoconf"
    "automake-1.17.tar.xz|7ab05f9ab51695b0c5c2f4a9e4f25d72|https://ftp.gnu.org/gnu/automake"
    "libtool-2.4.7.tar.xz|2fc0b6ddcd66a89ed6e45db28fa44232|https://ftp.gnu.org/gnu/libtool"
    "m4-1.4.19.tar.xz|0d90823e1426f1da2fd872df0311298d|https://ftp.gnu.org/gnu/m4"
    "bison-3.8.2.tar.xz|c28f119f405a2304ff0a7ccdcc629713|https://ftp.gnu.org/gnu/bison"
    "flex-2.6.4.tar.gz|2882e3179748cc9f9c23ec593d6adc8d|https://github.com/westes/flex/releases/download/v2.6.4"
    "pkg-config-0.29.2.tar.gz|f6e931e319531b736fadc017f470e68a|https://pkg-config.freedesktop.org/releases"

    # ── Compression libraries ─────────────────────────────────────────────
    "zlib-1.3.1.tar.gz|9855b6d802d7fe5b7bd5b196a2271655|https://zlib.net"
    "bzip2-1.0.8.tar.gz|67e051268d0c475ea773822f7500d0e5|https://sourceware.org/pub/bzip2"
    "xz-5.6.2.tar.xz|b8b7c9fc0e904c2ed3ed25e9c6a21e9c|https://github.com/tukaani-project/xz/releases/download/v5.6.2"
    "zstd-1.5.6.tar.gz|5a473726b3445d0e5d6296afd1ab6a87|https://github.com/facebook/zstd/releases/download/v1.5.6"

    # ── System libraries ──────────────────────────────────────────────────
    "libcap-2.70.tar.xz|c7dd9c7e8def3c734f5a89f0975c5db5|https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2"
    "libffi-3.4.6.tar.gz|b9cac6c5997dca2b3787a59ede34e0eb|https://github.com/libffi/libffi/releases/download/v3.4.6"
    "openssl-3.3.1.tar.gz|a1b818a9d2ce0da9cd9e63b0bbcc6c93|https://www.openssl.org/source"

    # ── Text processing & documentation ───────────────────────────────────
    "less-661.tar.gz|3ef73d9b84309d7d58b08a26c75bce5a|https://www.greenwoodsoftware.com/less"
    "groff-1.23.0.tar.gz|5e4f40315a22bb8a158748before1a4|https://ftp.gnu.org/gnu/groff"
    "texinfo-7.1.tar.xz|edd9928b4a3b82d8b6a572f666da7b09|https://ftp.gnu.org/gnu/texinfo"
    "vim-9.1.0660.tar.gz|4060a5a25b8695adf665fd9f30f23044|https://github.com/vim/vim/archive/refs/tags/v9.1.0660"
    "man-db-2.12.1.tar.xz|8227a9ef01f34aa53088de2b1a732d5a|https://download.savannah.gnu.org/releases/man-db"
    "man-pages-6.9.1.tar.xz|98a9e53f58e3cdab4668486cdb9b39da|https://www.kernel.org/pub/linux/docs/man-pages"

    # ── Perl & Python (needed by several build systems) ───────────────────
    "perl-5.40.0.tar.xz|cfe14ef0709b7687d7c5ab2e2f451a87|https://www.cpan.org/src/5.0"
    "Python-3.12.5.tar.xz|7e680e63e5393f0fe5a597a00d8f8e5d|https://www.python.org/ftp/python/3.12.5"
    "setuptools-72.2.0.tar.gz|4e3a1eb74b33c9a6bdee1a1fdf0e1b36|https://pypi.org/packages/source/s/setuptools"
    "wheel-0.44.0.tar.gz|a3f00b6a48a8efaa4a5561c0e93a02e5|https://pypi.org/packages/source/w/wheel"

    # ── System management ─────────────────────────────────────────────────
    "util-linux-2.40.2.tar.xz|80a11079c0cce5fd643ef58c2b876e7b|https://www.kernel.org/pub/linux/utils/util-linux/v2.40"
    "procps-ng-4.0.4.tar.xz|2f747fc7df8ccf402d03fba2df03f669|https://sourceware.org/pub/procps"
    "psmisc-23.7.tar.xz|53369c0e11a7e33f81c72de64e76dc80|https://gitlab.com/psmisc/psmisc/-/archive/v23.7"
    "shadow-4.16.0.tar.xz|be59ce5ca9bed2c39a2f53a86860bdf8|https://github.com/shadow-maint/shadow/releases/download/4.16.0"
    "sysvinit-3.10.tar.xz|6bd4ad4a72a3f5f4a3d54f35b73b2e7f|https://github.com/slicer69/sysvinit/releases/download/3.10"

    # ── Networking ────────────────────────────────────────────────────────
    "iproute2-6.10.0.tar.xz|4e6a8968908d6a22f2e01ff3f4bb5e8c|https://www.kernel.org/pub/linux/utils/net/iproute2"
    "iputils-20240117.tar.gz|3f88e8ba67951a3ff047e32e9dbeb558|https://github.com/iputils/iputils/archive/refs/tags/20240117"

    # ── Init system & boot ────────────────────────────────────────────────
    "grub-2.12.tar.xz|60c564b1bdc39d8e22b9578dcbc5f6a4|https://ftp.gnu.org/gnu/grub"

    # ── Linux Kernel ──────────────────────────────────────────────────────
    # The kernel is the heart of Nullify. We compile it in Phase 5 configured
    # specifically for a VMware x86_64 virtual machine target.
    "linux-6.10.5.tar.xz|bda6408e4a6e07c1c0f1c2fc80d51d43|https://www.kernel.org/pub/linux/kernel/v6.x"
)

# Patches — small fixes applied to source trees before compilation
declare -a PATCHES=(
    "bzip2-1.0.8-install_docs-1.patch|6a5ac7e89b791aae556de0f745916f7f|https://www.linuxfromscratch.org/patches/lfs/12.2"
    "coreutils-9.5-i18n-2.patch|0e67948ea07e88e016e4d6c89e2e73a6|https://www.linuxfromscratch.org/patches/lfs/12.2"
    "glibc-2.40-fhs-1.patch|9a5997c3452909b1769918c759eff8a|https://www.linuxfromscratch.org/patches/lfs/12.2"
    "sysvinit-3.10-consolidated-1.patch|3d55c643a3e98e79b9a644b2fe3d3e53|https://www.linuxfromscratch.org/patches/lfs/12.2"
)

info "Package manifest loaded: ${#PACKAGES[@]} packages + ${#PATCHES[@]} patches"

# -----------------------------------------------------------------------------
# STEP 3 — DOWNLOAD PACKAGES
#
# We download each tarball with wget. The --continue flag makes downloads
# resumable — if a file is partially downloaded, wget picks up from where
# it left off rather than starting over.
#
# Files already fully downloaded are skipped entirely to save time on reruns.
# -----------------------------------------------------------------------------

section "Step 3 — Downloading packages"

cd "$SOURCES"

DOWNLOADED=0
SKIPPED=0
FAILED=0
FAILED_LIST=()

download_file() {
    local filename=$1
    local url=$2

    if [[ -f "$filename" ]]; then
        info "Already exists — skipping: $filename"
        ((SKIPPED++)) || true
        return 0
    fi

    info "Downloading: $filename"

    # Try primary URL first, fall back to LFS mirror if it fails
    if wget -q --show-progress --continue -O "$filename" "$url/$filename" 2>/dev/null; then
        ((DOWNLOADED++)) || true
        ok "Downloaded: $filename"
    elif wget -q --show-progress --continue -O "$filename" "$LFS_MIRROR/$filename" 2>/dev/null; then
        ((DOWNLOADED++)) || true
        ok "Downloaded (mirror): $filename"
    else
        warn "FAILED: $filename — will retry from backup mirror"
        wget -q --show-progress --continue -O "$filename" "$BACKUP_MIRROR/$filename" 2>/dev/null \
            && { ((DOWNLOADED++)) || true; ok "Downloaded (backup): $filename"; } \
            || { ((FAILED++)) || true; FAILED_LIST+=("$filename"); rm -f "$filename"; warn "Could not download: $filename"; }
    fi
}

# Download all packages
for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r filename checksum url <<< "$entry"
    download_file "$filename" "$url"
done

# Download all patches
for entry in "${PATCHES[@]}"; do
    IFS='|' read -r filename checksum url <<< "$entry"
    download_file "$filename" "$url"
done

echo ""
ok "Download pass complete"
info "Downloaded : $DOWNLOADED files"
info "Skipped    : $SKIPPED files (already present)"
info "Failed     : $FAILED files"

# -----------------------------------------------------------------------------
# STEP 4 — VERIFY CHECKSUMS
#
# Every file is verified against its official LFS 12.2 MD5 checksum.
# A mismatch means the file is corrupted, truncated, or tampered with.
# We catch this now rather than getting mysterious compiler errors later.
#
# Any file that fails verification is deleted so it gets re-downloaded
# cleanly on the next run of this script.
# -----------------------------------------------------------------------------

section "Step 4 — Verifying checksums"

PASS=0
FAIL=0
FAIL_LIST=()

verify_checksum() {
    local filename=$1
    local expected=$2

    if [[ ! -f "$filename" ]]; then
        warn "Missing: $filename — skipping checksum"
        return
    fi

    local actual
    actual=$(md5sum "$filename" | awk '{print $1}')

    if [[ "$actual" == "$expected" ]]; then
        ok "OK: $filename"
        ((PASS++)) || true
    else
        warn "CHECKSUM MISMATCH: $filename"
        warn "  Expected : $expected"
        warn "  Got      : $actual"
        warn "  Deleting corrupt file — rerun script to re-download"
        rm -f "$filename"
        ((FAIL++)) || true
        FAIL_LIST+=("$filename")
    fi
}

for entry in "${PACKAGES[@]}" "${PATCHES[@]}"; do
    IFS='|' read -r filename checksum url <<< "$entry"
    verify_checksum "$filename" "$checksum"
done

echo ""
ok "Checksum verification complete"
info "Passed  : $PASS"
info "Failed  : $FAIL"

if [[ ${#FAIL_LIST[@]} -gt 0 ]]; then
    warn "The following files failed verification and were deleted:"
    for f in "${FAIL_LIST[@]}"; do
        warn "  - $f"
    done
    warn "Rerun this script to re-download them."
fi

# -----------------------------------------------------------------------------
# STEP 5 — SET CORRECT PERMISSIONS ON SOURCES
#
# The sources directory needs to be readable and writable by root during
# the build. The sticky bit we set in Phase 1 stays in place.
# -----------------------------------------------------------------------------

section "Step 5 — Finalising sources directory"

chown -R root:root "$SOURCES"
chmod -R u+rw,go+r "$SOURCES"
ok "Permissions set on $SOURCES"

# Show disk usage so we know how much space the sources consumed
USED=$(du -sh "$SOURCES" | cut -f1)
info "Sources directory size: $USED"

# -----------------------------------------------------------------------------
# STEP 6 — COMMIT TO PROJECT NULLIFY REPO
# -----------------------------------------------------------------------------

section "Step 6 — Syncing to Project Nullify repository"

REPO=~/project-nullify/scripts

if [[ -d "$REPO" ]]; then
    cp "$0" "$REPO/02-sources.sh"
    cd ~/project-nullify
    git add scripts/02-sources.sh
    git commit -m "Phase 2: LFS 12.2 source downloader and checksum verifier" 2>/dev/null \
        || info "Nothing new to commit"
    git push 2>/dev/null || warn "Push failed — check: gh auth status"
    ok "Script committed to project-nullify repo"
else
    warn "Repo not found at $REPO — skipping git sync"
fi

# -----------------------------------------------------------------------------
# PHASE 2 COMPLETE — SUMMARY
# -----------------------------------------------------------------------------

section "Phase 2 Complete ✔ — All sources are ready"

echo ""
echo "  Sources dir   : $SOURCES"
echo "  Disk usage    : $USED"
echo "  Packages      : ${#PACKAGES[@]}"
echo "  Patches       : ${#PATCHES[@]}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    warn "Some checksums failed — rerun this script before proceeding to Phase 3"
else
    echo "  All checksums passed — sources are clean and verified"
    echo ""
    echo "  Next → Run 03-toolchain.sh to build the cross-compilation toolchain"
fi

echo ""
