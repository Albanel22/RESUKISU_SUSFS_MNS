#!/usr/bin/env bash
# =============================================================================
# BUILD : LineageOS 23.2 + ReSukiSU + SUSFS JackA1ltman
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche lineage-23.2)
# ReSukiSU : ReSukiSU/ReSukiSU @ 90b4a4c7
# Hooks    : KSU_SUSFS (SUSFS Inline Hook)
# SUSFS    : patch JackA1ltman + patch correctif kiev/lito
# =============================================================================
set -Eeuo pipefail

# ─── Configuration ──────────────────────────────────────────────────────
WORKSPACE="${WORKSPACE:-$PWD}"
ROOT="${ROOT:-$WORKSPACE/work}"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
REFERENCE_DIR="${REFERENCE_DIR:-$ROOT/reference}"
OUTPUT_DIR="${OUTPUT_DIR:-$WORKSPACE/output}"
OUT="${OUT:-$KERNEL_DIR/out}"
REJ_DIR="${REJ_DIR:-$WORKSPACE/rej-analysis}"
JOBS="${JOBS:-$(nproc)}"
LOG="${LOG:-$ROOT/build.log}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

# ─── Versions figées ────────────────────────────────────────────────────
SOURCE_URL="https://github.com/LineageOS/android_kernel_motorola_sm8250"
SOURCE_BRANCH="lineage-23.2"
RESUKISU_URL="https://github.com/ReSukiSU/ReSukiSU.git"
RESUKISU_COMMIT="90b4a4c70f70c835b01c2be6deac58ee3c0cb4c2"
JACKA1LTMAN_RAW="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/main"
SUSFS_PATCH_URL="$JACKA1LTMAN_RAW/Patches/Patch/susfs_patch_to_4.19.patch"
INLINE_HOOK_URL="$JACKA1LTMAN_RAW/Patches/susfs_inline_hook_patches.sh"
BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img"

# ─── Patch correctif local (à créer dans le dépôt) ──────────────────────
FIX_PATCH_LOCAL="$WORKSPACE/susfs_kiev_lito_fix.patch"

# ─── Sortie ─────────────────────────────────────────────────────────────
OUTPUT_BOOT="$OUTPUT_DIR/boot-resukisu-susfs-kiev.img"

mkdir -p "$ROOT" "$REFERENCE_DIR" "$OUTPUT_DIR"

echo "═══════════════════════════════════════════════════════════════"
echo "=== BUILD ReSukiSU + SUSFS JackA1ltman pour kiev ==="
echo "═══════════════════════════════════════════════════════════════"
df -h "$WORKSPACE" 2>/dev/null || df -h

# =====================================================================
# 0. ENVIRONNEMENT
# =====================================================================
if command -v apt-get >/dev/null 2>&1 && [[ "${SKIP_APT:-0}" != "1" ]]; then
  echo ""
  echo "=== Installation des dépendances APT ==="

  # Force HTTPS dans apt-mirrors.txt (HTTP timeout sur GitHub Actions)
  if [[ -f /etc/apt/apt-mirrors.txt ]]; then
    sudo sed -i 's|http://azure.archive.ubuntu.com|https://archive.ubuntu.com|g' /etc/apt/apt-mirrors.txt 2>/dev/null || true
    sudo sed -i 's|http://archive.ubuntu.com|https://archive.ubuntu.com|g' /etc/apt/apt-mirrors.txt 2>/dev/null || true
    echo "→ Miroir corrigé :"
    head -5 /etc/apt/apt-mirrors.txt
  fi

  sudo apt-get update \
    -o Acquire::Retries=2 \
    -o Acquire::http::Timeout=10 \
    -o Acquire::https::Timeout=30

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    bc bison build-essential cpio flex gcc-aarch64-linux-gnu \
    gcc-arm-linux-gnueabi libelf-dev libssl-dev pahole python3 \
    rsync wget curl git unzip zip

  echo "✅ Dépendances installées"
fi

# =====================================================================
# 1. CLONE DU KERNEL LINEAGEOS (par branche)
# =====================================================================
echo ""
echo "=== Clone du kernel LineageOS (branche $SOURCE_BRANCH) ==="
if [[ ! -d "$KERNEL_DIR/.git" ]]; then
  git clone --depth=1 -b "$SOURCE_BRANCH" "$SOURCE_URL" "$KERNEL_DIR"
fi
cd "$KERNEL_DIR"
git fetch --depth=1 origin "$SOURCE_BRANCH" 2>/dev/null || true
git reset --hard "origin/$SOURCE_BRANCH" 2>/dev/null || git reset --hard FETCH_HEAD
git clean -fdx
git log --oneline -1
echo "✅ Kernel cloné"

# =====================================================================
# 2. BACKPORT get_cred_rcu (4.19.325)
# =====================================================================
echo ""
echo "=== Backport de get_cred_rcu ==="
if grep -q "get_cred_rcu" include/linux/cred.h; then
  echo "✅ get_cred_rcu déjà présent"
else
  python3 - << 'PYEOF'
import re

with open('include/linux/cred.h', 'r') as f:
    content = f.read()

if 'get_cred_rcu' not in content:
    pattern = r'(static inline const struct cred \*get_cred\(const struct cred \*cred\)\s*\{[^}]*\})'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        insertion = '''

static inline const struct cred *get_cred_rcu(const struct cred *cred)
{
    struct cred *nonconst_cred = (struct cred *) cred;
    if (!cred)
        return NULL;
    if (!atomic_long_inc_not_zero(&nonconst_cred->usage))
        return NULL;
    validate_creds(cred);
    return cred;
}'''
        content = content[:match.end()] + insertion + content[match.end():]
        with open('include/linux/cred.h', 'w') as f:
            f.write(content)
        print("[+] get_cred_rcu ajouté à include/linux/cred.h")

with open('kernel/cred.c', 'r') as f:
    content = f.read()

if 'get_cred_rcu(cred)' not in content:
    content = content.replace(
        'while (!atomic_long_inc_not_zero(&((struct cred *)cred)->usage));',
        'while (!get_cred_rcu(cred));'
    )
    content = content.replace(
        'while (!atomic_inc_not_zero(&((struct cred *)cred)->usage));',
        'while (!get_cred_rcu(cred));'
    )
    with open('kernel/cred.c', 'w') as f:
        f.write(content)
    print("[+] kernel/cred.c modifié")
PYEOF
fi

# =====================================================================
# 3. CLONE ReSukiSU (commit figé)
# =====================================================================
echo ""
echo "=== Clone ReSukiSU @ $RESUKISU_COMMIT ==="
RESUKISU_DIR="$ROOT/ReSukiSU"
if [[ ! -d "$RESUKISU_DIR/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$RESUKISU_URL" "$RESUKISU_DIR"
fi
git -C "$RESUKISU_DIR" fetch --depth=1 origin "$RESUKISU_COMMIT"
git -C "$RESUKISU_DIR" checkout --detach "$RESUKISU_COMMIT"
git -C "$RESUKISU_DIR" log --oneline -1

rm -rf "$KERNEL_DIR/KernelSU" "$KERNEL_DIR/drivers/kernelsu"
cp -a "$RESUKISU_DIR" "$KERNEL_DIR/KernelSU"
ln -s ../KernelSU/kernel "$KERNEL_DIR/drivers/kernelsu"

# =====================================================================
# 4. INTÉGRATION SUSFS JackA1ltman
# =====================================================================
echo ""
echo "=== Intégration SUSFS 4.19 JackA1ltman ==="

echo "→ Téléchargement du patch SUSFS principal..."
wget -q -O /tmp/susfs_patch_to_4.19.patch "$SUSFS_PATCH_URL" || {
  echo "❌ Impossible de télécharger le patch SUSFS"; exit 1; }

echo "→ Application du patch SUSFS principal..."
cd "$KERNEL_DIR"

# Appliquer le patch principal (peut échouer partiellement)
PATCH_OK=1
if ! patch -p1 --forward --batch < /tmp/susfs_patch_to_4.19.patch; then
  PATCH_OK=0
  echo "⚠️  Rejets détectés dans le patch principal"
  mkdir -p "$REJ_DIR"
  find "$KERNEL_DIR" -type f -name '*.rej' -exec cp {} "$REJ_DIR/" \; 2>/dev/null || true
fi

# Nettoyer les .rej et .orig pour permettre l'application du patch correctif
find "$KERNEL_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -delete

# Appliquer le patch correctif kiev/lito si nécessaire
if [[ "$PATCH_OK" -eq 0 ]]; then
  echo ""
  echo "=== Application du patch correctif kiev/lito ==="

  if [[ ! -f "$FIX_PATCH_LOCAL" ]]; then
    echo "❌ Patch correctif introuvable : $FIX_PATCH_LOCAL"
    echo "   Crée ce fichier dans la racine de ton dépôt."
    exit 1
  fi

  if ! patch -p1 --forward --batch < "$FIX_PATCH_LOCAL"; then
    echo "❌ Échec du patch correctif kiev/lito"
    mkdir -p "$REJ_DIR"
    find "$KERNEL_DIR" -type f -name '*.rej' -exec cp {} "$REJ_DIR/" \; 2>/dev/null || true
    exit 1
  fi

  echo "✅ Patch correctif kiev/lito appliqué"
fi

# Nettoyer les éventuels restes
find "$KERNEL_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -delete

echo "→ Activation des hooks SUSFS Inline..."
wget -q -O /tmp/susfs_inline_hook_patches.sh "$INLINE_HOOK_URL" || {
  echo "❌ Impossible de télécharger le script inline hook"; exit 1; }
bash /tmp/susfs_inline_hook_patches.sh || {
  echo "❌ Échec des hooks inline"; exit 1; }

# =====================================================================
# 4b. VÉRIFICATIONS D'INTÉGRATION
# =====================================================================
echo ""
echo "=== Vérifications d'intégration ==="

grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig" || {
  echo "❌ ReSukiSU Kconfig non intégré"; exit 1; }
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || {
  echo "❌ ReSukiSU Makefile non intégré"; exit 1; }

for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
  [[ -f "$KERNEL_DIR/$f" ]] || { echo "❌ Fichier SUSFS manquant : $f"; exit 1; }
done

grep -q 'ksu_handle_input_handle_event' "$KERNEL_DIR/drivers/input/input.c" || {
  echo "❌ Hook input manquant dans drivers/input/input.c"; exit 1; }

echo "✅ Intégration validée"

# =====================================================================
# 4c. FIX DÉCLARATION vma DANS task_mmu.c
# =====================================================================
echo ""
echo "=== Vérification de la déclaration vma dans pagemap_read ==="

TASK_MMU="$KERNEL_DIR/fs/proc/task_mmu.c"
if grep -q 'SUSFS_IS_INODE_SUS_MAP' "$TASK_MMU"; then
  # Vérifier si vma est déclarée dans pagemap_read
  if ! awk '/static ssize_t pagemap_read/,/^}/' "$TASK_MMU" | grep -q 'struct vm_area_struct \*vma'; then
    echo "→ Ajout de la déclaration vma dans pagemap_read..."
    python3 - << 'PYEOF_VMA'
import re
path = 'fs/proc/task_mmu.c'
with open(path, 'r') as f:
    content = f.read()

# Trouver le début de pagemap_read
pattern = r'(static ssize_t pagemap_read\(struct file \*file, char __user \*buf,\s*\n\s*size_t count, loff_t \*ppos\)\s*\{)'
match = re.search(pattern, content)
if match:
    # Vérifier si vma est déjà déclarée dans les premières lignes
    start = match.end()
    body_snippet = content[start:start+500]
    if 'struct vm_area_struct *vma' not in body_snippet:
        # Ajouter la déclaration juste après l'accolade ouvrante
        insertion = '\n\tstruct vm_area_struct *vma;'
        content = content[:start] + insertion + content[start:]
        with open(path, 'w') as f:
            f.write(content)
        print("[+] Déclaration vma ajoutée dans pagemap_read")
    else:
        print("[i] vma déjà déclarée")
PYEOF_VMA
  else
    echo "✅ vma déjà déclarée"
  fi
fi

# =====================================================================
# 5. CONFIGURATION KERNEL
# =====================================================================
cd "$KERNEL_DIR"
rm -rf "$OUT"

printf '%s\n' '=== Configuration ReSukiSU : mode SUSFS Inline Hook ==='

make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  vendor/lito-perf_defconfig

SCRIPTS_CONFIG="$KERNEL_DIR/scripts/config"
if [[ ! -x "$SCRIPTS_CONFIG" ]]; then
  chmod +x "$SCRIPTS_CONFIG"
fi

"$SCRIPTS_CONFIG" --file "$OUT/.config" \
  --enable KSU \
  --enable KSU_MULTI_MANAGER_SUPPORT \
  --disable KSU_TRACEPOINT_HOOK \
  --disable KSU_MANUAL_HOOK \
  --disable KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
  --disable KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
  --disable KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
  --enable THREAD_INFO_IN_TASK \
  --enable KSU_SUSFS \
  --enable KSU_SUSFS_SUS_PATH \
  --enable KSU_SUSFS_SUS_MOUNT \
  --enable KSU_SUSFS_SUS_KSTAT \
  --enable KSU_SUSFS_SPOOF_UNAME \
  --enable KSU_SUSFS_ENABLE_LOG \
  --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
  --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
  --enable KSU_SUSFS_OPEN_REDIRECT \
  --enable KSU_SUSFS_SUS_MAP \
  --disable KPROBES \
  --disable HAVE_KPROBES \
  --disable KPROBE_EVENTS \
  --enable KALLSYMS \
  --enable KALLSYMS_ALL \
  --disable CC_WERROR

make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# =====================================================================
# CONTRÔLE STRICT
# =====================================================================
grep -q '^CONFIG_KSU=y$' "$OUT/.config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT/.config"
! grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$OUT/.config"
! grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y$' "$OUT/.config"

for option in \
  CONFIG_KSU_SUSFS_SUS_PATH \
  CONFIG_KSU_SUSFS_SUS_MOUNT \
  CONFIG_KSU_SUSFS_SUS_KSTAT \
  CONFIG_KSU_SUSFS_SPOOF_UNAME \
  CONFIG_KSU_SUSFS_ENABLE_LOG \
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
  CONFIG_KSU_SUSFS_OPEN_REDIRECT \
  CONFIG_KSU_SUSFS_SUS_MAP; do
  grep -q "^${option}=y$" "$OUT/.config" || {
    echo "Option SUSFS absente : $option" >&2
    exit 1
  }
done

grep -E 'CONFIG_(KSU|KSU_SUSFS|KSU_MANUAL_HOOK|THREAD_INFO_IN_TASK)' "$OUT/.config" | tee "$ROOT/ksu-susfs.config"

# =====================================================================
# 6. PATCH SIGNATURES MODULE
# =====================================================================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# =====================================================================
# 7. PATCH TACTILE
# =====================================================================
printf '%s\n' '=== Patch tactile ==='
if [[ -f "techpack/display/msm/msm_drv.c" ]]; then
  if ! grep -q "panel_register_notifier" techpack/display/msm/msm_drv.c; then
    printf '%s\n' '' '/* --- Début Patch Tactile --- */' \
      '#include <linux/notifier.h>' \
      '#include <linux/module.h>' \
      'static BLOCKING_NOTIFIER_HEAD(motorola_panel_notifier_list);' \
      'int panel_register_notifier(struct notifier_block *nb) {' \
      '    return blocking_notifier_chain_register(&motorola_panel_notifier_list, nb);' \
      '}' \
      'EXPORT_SYMBOL(panel_register_notifier);' \
      'int panel_unregister_notifier(struct notifier_block *nb) {' \
      '    return blocking_notifier_chain_unregister(&motorola_panel_notifier_list, nb);' \
      '}' \
      'EXPORT_SYMBOL(panel_unregister_notifier);' \
      'void touch_set_state(int state) { return; }' \
      'EXPORT_SYMBOL(touch_set_state);' \
      '/* --- Fin Patch Tactile --- */' \
      >> techpack/display/msm/msm_drv.c
    printf '%s\n' '✅ Patch tactile appliqué'
  fi
fi

# =====================================================================
# 8. COMPILATION
# =====================================================================
printf '%s\n' '=== Compilation du kernel et des modules ==='
make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  KCFLAGS=-Wno-error -j"$JOBS" Image.gz modules 2>&1 | tee "$LOG"

test -s "$OUT/arch/arm64/boot/Image.gz"
find "$OUT" -type f -name '*.ko' -print -quit | grep -q .
sha256sum "$OUT/arch/arm64/boot/Image.gz"
printf '%s\n' '✅ Compilation ReSukiSU/SUSFS réussie'

# =====================================================================
# 9. TÉLÉCHARGEMENT DES IMAGES DE RÉFÉRENCE
# =====================================================================
echo ""
echo "=== Téléchargement boot.img / dtbo.img de référence ==="
cd "$ROOT"
if [[ ! -f "$REFERENCE_DIR/boot.img" ]]; then
  wget --retry-connrefused --tries=5 -O "$REFERENCE_DIR/boot.img" "$BOOT_URL"
fi
if [[ ! -f "$REFERENCE_DIR/dtbo.img" ]]; then
  wget --retry-connrefused --tries=5 -O "$REFERENCE_DIR/dtbo.img" "$DTBO_URL"
fi
sha256sum "$REFERENCE_DIR/boot.img" "$REFERENCE_DIR/dtbo.img"

# =====================================================================
# 10. REPACK DU BOOT.IMG (Python embarqué)
# =====================================================================
echo ""
echo "=== Repack du boot.img ==="

REPACK_PY="$ROOT/repack_bootimg_inline.py"
cat > "$REPACK_PY" << 'PYEOF_REPACK'
#!/usr/bin/env python3
import hashlib
import os
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(os.environ["ROOT"])
REFERENCE = Path(os.environ["REFERENCE_BOOT"])
KERNEL = Path(os.environ["KERNEL_IMAGE"])
MODULE_ROOT = Path(os.environ["MODULE_ROOT"])
OUTPUT = Path(os.environ["OUTPUT_BOOT"])
MODULE_RELEASE = os.environ.get("MODULE_RELEASE", "4.19.325-resukisu-susfs")
PAGE_SIZE = 4096
TARGET_SIZE = REFERENCE.stat().st_size


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def put_u32(buf, off, value):
    struct.pack_into("<I", buf, off, value)


def align(value, page=PAGE_SIZE):
    return (value + page - 1) // page * page


def run(cmd, cwd=None, stdin=None, stdout=None):
    print("+", " ".join(str(x) for x in cmd))
    subprocess.run(cmd, cwd=cwd, stdin=stdin, stdout=stdout, check=True)


def make_ramdisk(tmp):
    old_gz = Path(tmp) / "ramdisk.old.gz"
    old_cpio = Path(tmp) / "ramdisk.old.cpio"
    ramdisk_dir = Path(tmp) / "ramdisk"
    old = REFERENCE.read_bytes()
    old_kernel_size = u32(old, 8)
    old_ramdisk_size = u32(old, 16)
    old_ramdisk_off = PAGE_SIZE + align(old_kernel_size)
    old_gz.write_bytes(old[old_ramdisk_off:old_ramdisk_off + old_ramdisk_size])
    with old_cpio.open("wb") as out:
        run(["gzip", "-dc", str(old_gz)], stdout=out)
    ramdisk_dir.mkdir()
    with old_cpio.open("rb") as inp:
        run(["cpio", "-idmuv"], cwd=ramdisk_dir, stdin=inp)

    modules = sorted(MODULE_ROOT.rglob("*.ko"))
    if not modules:
        raise SystemExit("No kernel modules found")
    module_dir = ramdisk_dir / "lib" / "modules" / MODULE_RELEASE
    module_dir.mkdir(parents=True, exist_ok=True)
    manifest = []
    for module in modules:
        rel = module.relative_to(MODULE_ROOT)
        dest = module_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(module, dest)
        manifest.append(str(Path("lib/modules") / MODULE_RELEASE / rel))
    (module_dir / "modules.order").write_text("\n".join(manifest) + "\n")
    (module_dir / "modules.load").write_text("\n".join(manifest) + "\n")

    new_cpio = Path(tmp) / "ramdisk.new.cpio"
    new_gz = Path(tmp) / "ramdisk.new.gz"
    find_proc = subprocess.Popen(["find", ".", "-print0"], cwd=ramdisk_dir,
                                  stdout=subprocess.PIPE)
    with new_cpio.open("wb") as out:
        run(["cpio", "--null", "-o", "-H", "newc"], cwd=ramdisk_dir,
            stdin=find_proc.stdout, stdout=out)
    find_proc.wait()
    with new_gz.open("wb") as out:
        run(["gzip", "-9", "-c", str(new_cpio)], stdout=out)
    return new_gz.read_bytes(), len(modules), sum(x.stat().st_size for x in modules)


def main():
    if not REFERENCE.is_file() or not KERNEL.is_file():
        raise SystemExit("Reference boot.img or compiled Image.gz is missing")
    original = REFERENCE.read_bytes()
    if original[:8] != b"ANDROID!":
        raise SystemExit("Reference is not an Android boot image")
    original_kernel_size = u32(original, 8)
    original_ramdisk_size = u32(original, 16)
    original_second_size = u32(original, 24)
    page = u32(original, 36) or PAGE_SIZE
    if page != PAGE_SIZE:
        raise SystemExit(f"Unsupported page size: {page}")
    old_kernel_off = page
    old_ramdisk_off = old_kernel_off + align(original_kernel_size, page)
    old_second_off = old_ramdisk_off + align(original_ramdisk_size, page)
    old_tail_off = old_second_off + align(original_second_size, page)
    old_ramdisk_end = old_ramdisk_off + original_ramdisk_size
    if old_tail_off < old_ramdisk_end:
        raise SystemExit("Invalid boot image layout")
    tail = original[old_tail_off:]

    with tempfile.TemporaryDirectory(prefix="boot-repack-", dir=ROOT) as tmp:
        ramdisk, module_count, module_bytes = make_ramdisk(tmp)

    kernel = KERNEL.read_bytes()
    header = bytearray(original[:page])
    put_u32(header, 8, len(kernel))
    put_u32(header, 16, len(ramdisk))
    digest = hashlib.sha1(kernel + ramdisk + tail).digest()
    header[576:596] = digest
    header[596:608] = b"\0" * 12

    image = bytearray(header)
    image += kernel
    image += b"\0" * (align(len(image), page) - len(image))
    image += ramdisk
    image += b"\0" * (align(len(image), page) - len(image))
    image += tail
    if len(image) < TARGET_SIZE:
        image += b"\0" * (TARGET_SIZE - len(image))
    OUTPUT.write_bytes(image)

    print(f"output={OUTPUT}")
    print(f"size={len(image)} bytes ({len(image) / 1048576:.2f} MiB)")
    print(f"kernel={len(kernel)} bytes")
    print(f"ramdisk={len(ramdisk)} bytes")
    print(f"modules={module_count} files, {module_bytes} uncompressed bytes")
    print(f"sha256={hashlib.sha256(image).hexdigest()}")
    print(f"original_size={TARGET_SIZE} bytes")


if __name__ == "__main__":
    main()
PYEOF_REPACK

ROOT="$ROOT" \
REFERENCE_BOOT="$REFERENCE_DIR/boot.img" \
KERNEL_IMAGE="$OUT/arch/arm64/boot/Image.gz" \
MODULE_ROOT="$OUT" \
OUTPUT_BOOT="$OUTPUT_BOOT" \
  python3 "$REPACK_PY"

# =====================================================================
# 11. COLLECTE DES ARTEFACTS
# =====================================================================
echo ""
echo "=== Collecte des artefacts ==="
cp "$REFERENCE_DIR/dtbo.img" "$OUTPUT_DIR/dtbo.img" 2>/dev/null || true
cp "$OUT/arch/arm64/boot/Image.gz" "$OUTPUT_DIR/Image.gz" 2>/dev/null || true
cp "$LOG" "$OUTPUT_DIR/build.log" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "=== BUILD TERMINÉ ==="
echo "═══════════════════════════════════════════════════════════════"
ls -lh "$OUTPUT_DIR/"
echo ""
echo "SHA-256 du boot.img :"
sha256sum "$OUTPUT_BOOT" 2>/dev/null || true
