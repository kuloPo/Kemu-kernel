#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: build-kernel.sh OUTPUT" >&2
    exit 2
fi
kernel_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
root=$(dirname "$kernel_dir")
output=$(realpath -m "$1")
config="$kernel_dir/kemu.config"
jobs=$(nproc)
kernel_version=$(make -s --no-print-directory -C "$kernel_dir" kernelversion)
android_version=$(sed -n 's/^BRANCH=\(android[0-9][0-9]*\)-.*/\1/p' "$kernel_dir/build.config.constants")
kmi_generation=$(sed -n 's/^KMI_GENERATION=\([0-9][0-9]*\)$/\1/p' "$kernel_dir/build.config.constants")
if [ -z "$android_version" ] || [ -z "$kmi_generation" ]; then
    echo 'Cannot determine Android version or KMI generation from build.config.constants.' >&2
    exit 1
fi
commit=$(git -C "$kernel_dir" rev-parse --short=9 HEAD)
release="$kernel_version-$android_version-$kmi_generation-kemu-g$commit"

export PATH="$root/clang-r536225/bin:$root/rust-1.82.0/bin:$root/clang-tools/bin:$PATH"
export LIBCLANG_PATH="$root/clang-r536225/lib"
export LD_LIBRARY_PATH="$root/kernel-build-tools/lib64:${LD_LIBRARY_PATH:-}"
export KBUILD_BUILD_USER=kemu KBUILD_BUILD_HOST=kernel-build
export KBUILD_BUILD_VERSION=kemu
export KBUILD_GENDWARFKSYMS_STABLE=1
export RUSTC_FORCE_RUSTC_VERSION=rustc-android
export KRUSTFLAGS="--remap-path-prefix=$root=/proc/self/cwd --remap-path-prefix=$root/rust-1.82.0=/proc/self/cwd/prebuilts/rust/linux-x86/1.82.0"

if ! command -v cpio >/dev/null; then
    echo 'cpio is required; install it with the host package manager.' >&2
    exit 1
fi

mkdir -p "$output"
if [ ! -f "$output/.config" ]; then
    cp "$config" "$output/.config"
fi
make_args=(-C "$kernel_dir" O="$output" ARCH=x86_64 LLVM=1 LLVM_IAS=1
    "KERNELRELEASE=$release" "PAHOLE=$root/kernel-build-tools/bin/pahole"
    KCFLAGS=-D__ANDROID_COMMON_KERNEL__
    HOSTCFLAGS=-Wno-error=incompatible-pointer-types-discards-qualifiers)

printf 'Kernel release: %s\nParallel jobs: %s\n' "$release" "$jobs"
clang --version | head -1
rustc --version
bindgen --version
cpio --version | head -1
"$root/kernel-build-tools/bin/pahole" --version
make "${make_args[@]}" olddefconfig
diff -u "$config" "$output/.config" > "$output/config.diff" || {
    cat "$output/config.diff"
    echo 'Kernel configuration changed; inspect before building.' >&2
    exit 1
}
make "${make_args[@]}" -j"$jobs" bzImage modules
sha256sum "$output/arch/x86/boot/bzImage" "$output/vmlinux" "$output/Module.symvers"
