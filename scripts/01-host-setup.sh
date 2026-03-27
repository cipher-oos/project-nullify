#!/bin/bash
# =============================================================================
# Project Nullify — Phase 1: Host Preparation & Disk Image Creation
# =============================================================================
#
# What this script does:
#   This is the very first step in building Nullify from scratch. Before we can
#   compile a single package, we need two things:
#
#     1. A capable build environment — our Fedora WSL2 host needs all the
#        compilers, linkers, and build tools that LFS packages depend on.
#        Without these, the cross-toolchain build in Phase 2 will fail.
#
#     2. A dedicated disk image — instead of partitioning a real drive, we
#        create a raw image file (nullify.img) that acts as our target
#        filesystem. This is where every compiled package will be installed,
#        and eventually what becomes the bootable ISO.
#
# Why a disk image instead of a real partition?
#   We're building inside WSL2 on Windows. We don't have access to raw block
#   devices the way a native Linux install would. A loop-mounted image file
#   gives us the exact same ext4 filesystem experience without needing to
#   touch any real hardware or partitions.
#
# Note: This script targets Fedora 43 which ships DNF5.
#       DNF5 dropped the 'groupinstall' subcommand — we install package groups
#       using '@group-name' syntax instead.
#
# Run this as root inside your Fedora WSL2 environment.
# Usage: bash 01-host-setup.sh
# =============================================================================

set -euo pipefail
# set -e  → exit immediately if any command fails
# set -u  → treat unset variables as errors
# set -o pipefail → catch failures inside pipes (e.g. curl | tar)

# -----------------------------------------------------------------------------
# CONFIGURATION
# Change these values if you want a different image size or mount location.
# -----------------------------------------------------------------------------

LFS=/mnt/lfs                  # Where the disk image will be mounted
LFS_IMG=/root/nullify.img     # Path to the raw disk image file
LFS_SIZE=20480                # Size in MB — 20GB is comfortable for a full build
LFS_VERSION="12.2"            # LFS book version we are following

# Export LFS so child processes and future scripts can see it
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

# -----------------------------------------------------------------------------
# STEP 1 — VERIFY WE ARE RUNNING AS ROOT
#
# LFS requires root for mounting filesystems, creating device nodes, and
# chrooting. Everything in this build runs as root inside WSL2.
# -----------------------------------------------------------------------------

section "Step 1 — Checking privileges"

if [[ $EUID -ne 0 ]]; then
    echo "  ✘  This script must be run as root."
    echo "     Run: sudo bash 01-host-setup.sh"
    exit 1
fi

ok "Running as root"

# -----------------------------------------------------------------------------
# STEP 2 — INSTALL HOST BUILD DEPENDENCIES
#
# These are the tools our Fedora host needs to build the LFS cross-toolchain.
# We are not installing these into Nullify — they stay on the host. Think of
# them as the factory machinery, not the product itself.
#
# Fedora 43 ships DNF5 which changed the group install syntax:
#   Old DNF4: dnf groupinstall "Development Tools"
#   New DNF5: dnf install @development-tools
#
# Key individual packages and why we need them:
#   bison, flex    → Parser generators required by GCC and the Linux kernel
#   gawk           → GNU awk specifically — some LFS scripts require gawk
#   texinfo        → Builds .info documentation pages for GNU packages
#   glibc-devel    → C library headers needed to compile against libc
#   xorriso        → Creates the bootable ISO image in the final phase
#   grub2-tools    → Provides grub-mkrescue for embedding GRUB into the ISO
#   e2fsprogs      → Provides mkfs.ext4 to format our disk image
#   bc             → Arbitrary precision calculator — required by the kernel
# -----------------------------------------------------------------------------

section "Step 2 — Installing host build dependencies"

info "Updating package database..."
dnf update -y -q

# DNF5 uses '@group-name' syntax instead of the old 'groupinstall' subcommand
info "Installing Development Tools group (DNF5 syntax)..."
dnf install -y -q @development-tools

info "Installing individual LFS build requirements..."
dnf install -y -q \
    gcc \
    gcc-c++ \
    make \
    bison \
    flex \
    gawk \
    texinfo \
    perl \
    python3 \
    wget \
    curl \
    xz \
    glibc-devel \
    kernel-headers \
    xorriso \
    grub2-tools-extra \
    e2fsprogs \
    util-linux \
    coreutils \
    findutils \
    patch \
    tar \
    bc \
    binutils

ok "All host dependencies installed"

# -----------------------------------------------------------------------------
# STEP 3 — VERIFY HOST TOOL VERSIONS
#
# The LFS book has minimum version requirements for host tools. Building with
# versions below these minimums causes subtle, hard-to-debug failures deep
# in the toolchain build. We check them here and fail early rather than
# discovering the problem hours into a compile.
#
# Required minimums (LFS 12.2):
#   Bash 3.2+   GCC 5.1+   Glibc 2.11+   Bison 2.7+   Make 4.0+
# -----------------------------------------------------------------------------

section "Step 3 — Verifying host tool versions"

check_version() {
    local tool=$1
    local flag=$2
    local version
    version=$($tool $flag 2>&1 | head -1)
    ok "$tool → $version"
}

check_version bash    "--version"
check_version gcc     "--version"
check_version make    "--version"
check_version bison   "--version"
check_version python3 "--version"
check_version ld      "--version"

# /bin/sh must point to bash, not dash. Some LFS configure scripts behave
# differently under dash and produce broken builds. LFS requires bash as sh.
info "Checking /bin/sh points to bash..."
if readlink -f /bin/sh | grep -q bash; then
    ok "/bin/sh points to bash"
else
    warn "/bin/sh does not point to bash — fixing..."
    ln -sf bash /bin/sh
    ok "/bin/sh now points to bash"
fi

# awk must be GNU awk (gawk) — mawk and nawk are not compatible with LFS scripts
info "Checking awk is gawk..."
if awk --version 2>&1 | grep -q GNU; then
    ok "awk is GNU awk (gawk)"
else
    warn "awk is not gawk — linking..."
    ln -sf gawk /usr/bin/awk
fi

# -----------------------------------------------------------------------------
# STEP 4 — CREATE THE DISK IMAGE
#
# We create a raw binary file and format it as ext4. This becomes the root
# filesystem of Project Nullify. Every compiled package in Phases 2-7 gets
# installed here, and this image eventually becomes the core of our ISO.
#
# Why ext4?
#   Stable, well-understood, and natively supported by GRUB. A solid default
#   for a first LFS build. You can experiment with btrfs or xfs in a future
#   build once you know the whole process end-to-end.
#
# Why 20GB?
#   A minimal LFS build uses around 8GB. The extra headroom covers BLFS
#   packages in Phase 8 such as X.org, a desktop environment, and networking.
# -----------------------------------------------------------------------------

section "Step 4 — Creating the Nullify disk image"

if [[ -f "$LFS_IMG" ]]; then
    warn "Disk image already exists at $LFS_IMG — skipping creation"
    info "Delete it manually to start fresh: rm $LFS_IMG"
else
    info "Allocating ${LFS_SIZE}MB image at $LFS_IMG..."
    info "This may take a minute depending on your disk speed..."

    # dd creates a raw binary file filled with zeros.
    # bs=1M sets the block size to 1 megabyte for efficient writing.
    # count=LFS_SIZE writes that many blocks giving us our target size.
    dd if=/dev/zero of="$LFS_IMG" bs=1M count="$LFS_SIZE" status=progress

    ok "Disk image allocated"

    info "Formatting as ext4..."
    # -L nullify  sets the filesystem label visible in blkid and /etc/fstab
    # -F          forces format on a regular file rather than a block device
    mkfs.ext4 -L nullify -F "$LFS_IMG"

    ok "Formatted as ext4 with label 'nullify'"
fi

# -----------------------------------------------------------------------------
# STEP 5 — MOUNT THE DISK IMAGE
#
# We mount the image file using a loop device — a kernel mechanism that lets
# you treat a regular file as a block device. This gives us a real mountable
# ext4 filesystem from a plain file, which is exactly what we need in WSL2.
#
# After mounting, $LFS (/mnt/lfs) is our build target. Every package we
# compile during the LFS build gets installed under this path.
# -----------------------------------------------------------------------------

section "Step 5 — Mounting the disk image"

info "Creating mount point at $LFS..."
mkdir -p "$LFS"

if mountpoint -q "$LFS"; then
    warn "$LFS is already mounted — skipping"
else
    info "Mounting $LFS_IMG → $LFS via loop device..."
    mount -o loop "$LFS_IMG" "$LFS"
    ok "Mounted successfully"
fi

ok "Nullify disk image is live at $LFS"

# -----------------------------------------------------------------------------
# STEP 6 — CREATE THE LFS DIRECTORY STRUCTURE
#
# These top-level directories follow the FHS (Filesystem Hierarchy Standard)
# — the same layout found on every Linux system from Alpine to Arch. We are
# building a real OS so it needs a real directory structure from day one.
#
# Notable directories:
#   $LFS/tools    → Temporary cross-toolchain (Phase 2 only). Lives outside
#                   /usr so it is trivial to remove after the build finishes.
#   $LFS/sources  → All source tarballs and patches. Keeping them here lets
#                   you safely resume interrupted builds without re-downloading.
# -----------------------------------------------------------------------------

section "Step 6 — Creating Nullify filesystem structure"

info "Creating standard FHS directories..."

mkdir -pv "$LFS"/{etc,var,usr,lib,lib64,bin,sbin,boot,home,root,tmp}
mkdir -pv "$LFS"/usr/{bin,lib,lib64,sbin,include,share}
mkdir -pv "$LFS"/usr/share/{doc,info,man,misc}
mkdir -pv "$LFS"/etc/{opt,sysconfig}
mkdir -pv "$LFS"/lib/firmware
mkdir -pv "$LFS"/media/{floppy,cdrom}
mkdir -pv "$LFS"/opt/{bin,lib}
mkdir -pv "$LFS"/{proc,sys,run,dev}

# The tools directory holds our temporary cross-compiler.
# It is NOT part of the final Nullify system — discarded after Phase 3.
mkdir -pv "$LFS/tools"

# Sources holds all package tarballs. The sticky bit (+t) means only the
# file owner can delete files here — prevents accidental deletions.
mkdir -pv "$LFS/sources"
chmod -v a+wt "$LFS/sources"

ok "Directory structure created"

# Symlink /tools → $LFS/tools so the cross-compiler path works both inside
# and outside the chroot environment without needing modification
ln -sfv "$LFS/tools" /tools 2>/dev/null || true

# -----------------------------------------------------------------------------
# STEP 7 — PERSIST ENVIRONMENT ACROSS WSL2 SESSIONS
#
# WSL2 resets all mounts when it restarts. Without this, you would need to
# manually remount the disk image and re-export $LFS every session. The helper
# script below handles all of that in one command.
# -----------------------------------------------------------------------------

section "Step 7 — Creating session persistence helpers"

cat > /root/remount-nullify.sh << 'REMOUNT'
#!/bin/bash
# Project Nullify — Session remount helper
# ─────────────────────────────────────────
# WSL2 does not persist mounts between sessions. Run this script at the
# start of every terminal session before continuing the LFS build.
#
# Usage: source /root/remount-nullify.sh

export LFS=/mnt/lfs

echo "→ Mounting Nullify disk image..."
mkdir -p $LFS
mount -o loop /root/nullify.img $LFS \
    && echo "✔ Mounted at $LFS" \
    || echo "⚠  Already mounted or mount failed"

export LFS
echo "✔ LFS=$LFS is ready — you can continue the build"
REMOUNT

chmod +x /root/remount-nullify.sh
ok "Remount helper saved → /root/remount-nullify.sh"

# Add LFS export to .bashrc so the variable is always available in new shells
if ! grep -q "export LFS=" /root/.bashrc 2>/dev/null; then
    {
        echo ""
        echo "# Project Nullify — LFS build target"
        echo "export LFS=/mnt/lfs"
    } >> /root/.bashrc
    ok "LFS variable added to /root/.bashrc"
else
    info "LFS already in .bashrc — skipping"
fi

# -----------------------------------------------------------------------------
# STEP 8 — COMMIT SCRIPT TO PROJECT NULLIFY REPO
# -----------------------------------------------------------------------------

section "Step 8 — Syncing to Project Nullify repository"

REPO=~/project-nullify/scripts

if [[ -d "$REPO" ]]; then
    info "Copying script to repo..."
    cp "$0" "$REPO/01-host-setup.sh"
    cd ~/project-nullify
    git add scripts/01-host-setup.sh
    git commit -m "Phase 1: host setup and disk image creation" 2>/dev/null \
        || info "Nothing new to commit"
    git push 2>/dev/null || warn "Push failed — check your GitHub auth with: gh auth status"
    ok "Script committed to project-nullify repo"
else
    warn "Repo not found at $REPO — skipping git sync"
    info "Create it first: mkdir -p ~/project-nullify/scripts"
fi

# -----------------------------------------------------------------------------
# PHASE 1 COMPLETE — SUMMARY
# -----------------------------------------------------------------------------

section "Phase 1 Complete ✔ — Project Nullify disk is ready"

echo ""
echo "  Disk image    : $LFS_IMG  (${LFS_SIZE}MB, ext4, label: nullify)"
echo "  Mounted at    : $LFS"
echo "  LFS version   : $LFS_VERSION"
echo "  Sources dir   : $LFS/sources  (tarballs go here)"
echo "  Tools dir     : $LFS/tools    (temporary cross-toolchain)"
echo ""
echo "  On next WSL2 session run:"
echo "    source /root/remount-nullify.sh"
echo ""
echo "  Next → Run 02-sources.sh to download all LFS source tarballs"
echo ""
