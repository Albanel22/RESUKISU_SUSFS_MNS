#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-$PWD}"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
BUNDLE_DIR="${BUNDLE_DIR:-$ROOT}"
RESUKISU_URL="https://github.com/ReSukiSU/ReSukiSU.git"
RESUKISU_COMMIT="90b4a4c70f70c835b01c2be6deac58ee3c0cb4c2"
SOURCE_COMMIT="c21b90c6860eeade8da37ea1212aa6135cf99e1f"

cd "$KERNEL_DIR"
git reset --hard "$SOURCE_COMMIT"
git clean -fdx

if [[ ! -d "$ROOT/ReSukiSU/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$RESUKISU_URL" "$ROOT/ReSukiSU"
fi
git -C "$ROOT/ReSukiSU" fetch --depth=1 origin "$RESUKISU_COMMIT"
git -C "$ROOT/ReSukiSU" checkout --detach "$RESUKISU_COMMIT"

cp -a "$ROOT/ReSukiSU" "$KERNEL_DIR/KernelSU"
ln -s ../KernelSU/kernel "$KERNEL_DIR/drivers/kernelsu"
for f in fs/sus_su.c fs/susfs.c include/linux/sus_su.h include/linux/susfs.h include/linux/susfs_def.h; do
  cp "$BUNDLE_DIR/integration/$(basename "$f")" "$KERNEL_DIR/$f"
done

git apply --reject --whitespace=nowarn "$BUNDLE_DIR/integration/kernel-adaptations.patch" || true
if [[ -f "$KERNEL_DIR/fs/Makefile.rej" ]]; then
  grep -q 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' "$KERNEL_DIR/fs/Makefile" || \
    sed -i '/^ifeq (\$(CONFIG_BLOCK),y)$/i obj-$(CONFIG_KSU_SUSFS) += susfs.o\nobj-$(CONFIG_KSU_SUSFS_SUS_SU) += sus_su.o\n' "$KERNEL_DIR/fs/Makefile"
  rm -f "$KERNEL_DIR/fs/Makefile.rej"
fi
find "$KERNEL_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -delete

grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile"
grep -q 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' "$KERNEL_DIR/fs/Makefile"
grep -q 'ksu_handle_input_handle_event' "$KERNEL_DIR/drivers/input/input.c"
[[ ! -e "$KERNEL_DIR/fs/Makefile.rej" ]]

echo "Prepared source commit: $(git -C "$KERNEL_DIR" rev-parse HEAD)"
echo "Prepared ReSukiSU commit: $(git -C "$ROOT/ReSukiSU" rev-parse HEAD)"
