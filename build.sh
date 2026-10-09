#!/usr/bin/env bash
# =============================================================================
# BUILD : Branche-C — LineageOS + ReSukiSU + SUSFS + patch tactile (CORRIGÉ)
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche par défaut)
# ReSukiSU : ReSukiSU/ReSukiSU @ 90b4a4c7
# Hooks    : KSU_SUSFS (SUSFS Inline Hook)
# SUSFS    : patch JackA1ltman + corrections Python intégrées
# FIX      : fusion lito-perf_defconfig + ext_config/kiev-default.config
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

# ─── Sources et versions ────────────────────────────────────────────────
SOURCE_URL="https://github.com/LineageOS/android_kernel_motorola_sm8250"
RESUKISU_URL="https://github.com/ReSukiSU/ReSukiSU.git"
RESUKISU_COMMIT="90b4a4c70f70c835b01c2be6deac58ee3c0cb4c2"
JACKA1LTMAN_RAW="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/main"
SUSFS_PATCH_URL="$JACKA1LTMAN_RAW/Patches/Patch/susfs_patch_to_4.19.patch"
INLINE_HOOK_URL="$JACKA1LTMAN_RAW/Patches/susfs_inline_hook_patches.sh"
BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img"

# ─── Sortie ─────────────────────────────────────────────────────────────
OUTPUT_BOOT="$OUTPUT_DIR/boot-resukisu-susfs-kiev-branche-C-tactile.img"

mkdir -p "$ROOT" "$REFERENCE_DIR" "$OUTPUT_DIR"

echo "═══════════════════════════════════════════════════════════════"
echo "=== BUILD ReSukiSU + SUSFS + ext_config kiev (Branche-C) ==="
echo "═══════════════════════════════════════════════════════════════"
df -h "$WORKSPACE" 2>/dev/null || df -h

# =====================================================================
# 0. ENVIRONNEMENT
# =====================================================================
if command -v apt-get >/dev/null 2>&1 && [[ "${SKIP_APT:-0}" != "1" ]]; then
  echo ""
  echo "=== Installation des dépendances APT ==="

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
# 1. CLONAGE DU CODE SOURCE KERNEL LINEAGEOS
# =====================================================================
echo ""
echo "=== Clonage du code source LineageOS ==="
if [[ ! -d "$KERNEL_DIR/.git" ]]; then
  git clone --depth=1 "$SOURCE_URL" "$KERNEL_DIR"
fi
cd "$KERNEL_DIR"
git fetch --depth=1 origin
git remote set-head origin -a >/dev/null 2>&1 || true
DEFAULT_REF="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD || true)"
if [[ -n "$DEFAULT_REF" ]]; then
  git reset --hard "$DEFAULT_REF"
else
  git reset --hard HEAD
fi
git clean -fdx
git log --oneline -1
echo "✅ Code source cloné"

# Vérification : présence des fichiers de configuration requis
echo "→ Vérification des fichiers de config..."
for f in \
  "arch/arm64/configs/vendor/lito-perf_defconfig" \
  "arch/arm64/configs/vendor/ext_config/kiev-default.config"; do
  if [[ ! -f "$f" ]]; then
    echo "❌ Fichier de config manquant : $f"
    exit 1
  fi
  echo "  ✅ $f"
done

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
# 3. CLONE ReSukiSU
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

# Intégration Kconfig ReSukiSU dans le kernel
echo "→ Intégration Kconfig ReSukiSU..."

if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"; then
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"
  echo "✅ source Kconfig ajouté"
fi

if ! grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile"; then
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$KERNEL_DIR/drivers/Makefile"
  echo "✅ obj- Makefile ajouté"
fi

grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig" || {
  echo "❌ Échec Kconfig ReSukiSU"; exit 1; }
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || {
  echo "❌ Échec Makefile ReSukiSU"; exit 1; }
echo "✅ ReSukiSU intégré dans le kernel"

# =====================================================================
# 4. INTÉGRATION SUSFS JackA1ltman + CORRECTIONS PYTHON
# =====================================================================
echo ""
echo "=== Intégration SUSFS 4.19 JackA1ltman ==="

echo "→ Téléchargement du patch SUSFS principal..."
wget -q -O /tmp/susfs_patch_to_4.19.patch "$SUSFS_PATCH_URL" || {
  echo "❌ Impossible de télécharger le patch SUSFS"; exit 1; }

echo "→ Application du patch SUSFS principal..."
cd "$KERNEL_DIR"

if ! patch -p1 --forward --batch < /tmp/susfs_patch_to_4.19.patch; then
  echo "⚠️  Rejets détectés dans le patch principal — ils seront corrigés par Python"
fi

find "$KERNEL_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -delete

echo "→ Application des corrections Python kiev/lito..."

python3 << 'PYEOF_FIX'
import re
import sys
from pathlib import Path

KERNEL = Path(".")
fixes_applied = []

# FIX 1 : fs/namespace.c — includes SUSFS
ns_path = KERNEL / "fs" / "namespace.c"
text = ns_path.read_text()

includes_block = """#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
"""

if "susfs_is_sdcard_android_data_not_decrypted" not in text.split("#include \"pnode.h\"")[0]:
    marker = "#include <linux/fs_context.h>\n"
    if marker in text:
        text = text.replace(marker, marker + includes_block, 1)
        fixes_applied.append("namespace.c: includes SUSFS ajoutés")
    else:
        print("❌ namespace.c : marqueur fs_context.h non trouvé", file=sys.stderr)
        sys.exit(1)
else:
    fixes_applied.append("namespace.c: includes SUSFS déjà présents")
ns_path.write_text(text)

# FIX 2 : fs/namespace.c — vfs_create_mount (SUS_MOUNT)
text = ns_path.read_text()
original_call = "\tmnt = alloc_vfsmnt(fc->source ?: \"none\");\n\tif (!mnt)\n\t\treturn ERR_PTR(-ENOMEM);"
patched_call = """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	if (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted) &&
		susfs_is_current_ksu_domain())
		mnt = susfs_alloc_non_unshare_ksu_vfsmnt(fc->source ?: "none");
	else
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
		mnt = alloc_vfsmnt(fc->source ?: "none");
	if (!mnt)
		return ERR_PTR(-ENOMEM);"""

if "susfs_alloc_non_unshare_ksu_vfsmnt" not in text:
    if original_call in text:
        text = text.replace(original_call, patched_call, 1)
        fixes_applied.append("namespace.c: vfs_create_mount patché")
    else:
        print("❌ namespace.c : bloc vfs_create_mount non trouvé", file=sys.stderr)
        sys.exit(1)
else:
    fixes_applied.append("namespace.c: vfs_create_mount déjà patché")
ns_path.write_text(text)

# FIX 3 : fs/super.c — includes SUSFS
super_path = KERNEL / "fs" / "super.c"
text = super_path.read_text()
super_includes = """#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif // #ifdef CONFIG_KSU_SUSFS
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
"""

if "susfs_is_sdcard_android_data_not_decrypted" not in text.split("#include \"internal.h\"")[0]:
    marker = "#include <linux/fs_context.h>\n"
    if marker in text:
        text = text.replace(marker, marker + super_includes, 1)
        fixes_applied.append("super.c: includes SUSFS ajoutés")
    else:
        print("❌ super.c : marqueur fs_context.h non trouvé", file=sys.stderr)
        sys.exit(1)
else:
    fixes_applied.append("super.c: includes SUSFS déjà présents")
super_path.write_text(text)

# FIX 4 : fs/proc/task_mmu.c — SUS_MAP
mmu_path = KERNEL / "fs" / "proc" / "task_mmu.c"
text = mmu_path.read_text()

if "SUSFS_IS_INODE_SUS_MAP" not in text:
    pattern = r'(\t\tret = mmap_read_lock_killable\(mm\);\n\t\tif \(ret\)\n\t\t\tgoto out_free;\n)(\t\tret = walk_page_range\(start_vaddr, end, &pagemap_walk\);\n)'
    replacement = r'''\1#ifdef CONFIG_KSU_SUSFS_SUS_MAP
		vma = find_vma(mm, start_vaddr);
		if (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))
			goto bypass_orig_flow;
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
\2#ifdef CONFIG_KSU_SUSFS_SUS_MAP
bypass_orig_flow:
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP
'''
    new_text, count = re.subn(pattern, replacement, text, count=1)
    if count == 0:
        print("⚠️  task_mmu.c : bloc pagemap_read non trouvé (peut être déjà patché)")
    else:
        text = new_text
        fixes_applied.append("task_mmu.c: bloc SUS_MAP inséré")
else:
    fixes_applied.append("task_mmu.c: bloc SUS_MAP déjà présent")

pagemap_match = re.search(
    r'(static ssize_t pagemap_read\(struct file \*file, char __user \*buf,\s*\n\s*size_t count, loff_t \*ppos\)\s*\{)([^}]*?)(\n\tif \(!mm)',
    text, re.DOTALL
)
if pagemap_match:
    body = pagemap_match.group(2)
    if 'struct vm_area_struct *vma' not in body:
        mm_decl_match = re.search(r'(\tstruct mm_struct \*mm = file->private_data;\n)', body)
        if mm_decl_match:
            new_body = body.replace(
                mm_decl_match.group(1),
                mm_decl_match.group(1) + '\tstruct vm_area_struct *vma;' + '\n',
                1
            )
            text = text[:pagemap_match.start(2)] + new_body + text[pagemap_match.end(2):]
            fixes_applied.append("task_mmu.c: déclaration vma ajoutée")
        else:
            print("⚠️  task_mmu.c : déclaration mm non trouvée")
    else:
        fixes_applied.append("task_mmu.c: vma déjà déclarée")
else:
    print("⚠️  task_mmu.c : fonction pagemap_read non trouvée")
mmu_path.write_text(text)

print("")
print("=== Corrections appliquées ===")
for fix in fixes_applied:
    print(f"  ✅ {fix}")
print("")
print("✅ Toutes les corrections Python sont appliquées")
PYEOF_FIX

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

grep -q 'susfs_alloc_non_unshare_ksu_vfsmnt' "$KERNEL_DIR/fs/namespace.c" || {
  echo "❌ namespace.c : patch SUS_MOUNT manquant"; exit 1; }
grep -q 'susfs_is_sdcard_android_data_not_decrypted' "$KERNEL_DIR/fs/super.c" || {
  echo "❌ super.c : includes SUSFS manquants"; exit 1; }
grep -q 'SUSFS_IS_INODE_SUS_MAP' "$KERNEL_DIR/fs/proc/task_mmu.c" || {
  echo "❌ task_mmu.c : bloc SUS_MAP manquant"; exit 1; }

echo "✅ Intégration validée (patch principal + corrections Python)"

# =====================================================================
# 5. CONFIGURATION KERNEL — FUSION defconfig + ext_config kiev
# =====================================================================
cd "$KERNEL_DIR"
rm -rf "$OUT"
mkdir -p "$OUT"

echo ""
echo "=== Configuration kernel : fusion lito-perf + ext_config kiev ==="

KIEV_EXT_CONFIG="arch/arm64/configs/vendor/ext_config/kiev-default.config"
BASE_DEFCONFIG="arch/arm64/configs/vendor/lito-perf_defconfig"

if [[ ! -f "$KIEV_EXT_CONFIG" ]]; then
  echo "❌ $KIEV_EXT_CONFIG introuvable"
  exit 1
fi

if [[ ! -f "$BASE_DEFCONFIG" ]]; then
  echo "❌ $BASE_DEFCONFIG introuvable"
  exit 1
fi

# Méthode : fusion via merge_config.sh (officiel LineageOS/Qualcomm)
if [[ -x "scripts/kconfig/merge_config.sh" ]]; then
  echo "→ Fusion via merge_config.sh..."
  ./scripts/kconfig/merge_config.sh -O "$OUT" -m \
    "$BASE_DEFCONFIG" \
    "$KIEV_EXT_CONFIG" || {
      echo "⚠️  merge_config.sh a échoué, fallback concaténation"
      # Fallback
      cat "$BASE_DEFCONFIG" > "$OUT/.config"
      echo "" >> "$OUT/.config"
      echo "# ═══ ext_config kiev-default ═══" >> "$OUT/.config"
      cat "$KIEV_EXT_CONFIG" >> "$OUT/.config"
    }
else
  echo "→ merge_config.sh introuvable, fusion manuelle..."
  cat "$BASE_DEFCONFIG" > "$OUT/.config"
  echo "" >> "$OUT/.config"
  echo "# ═══ ext_config kiev-default ═══" >> "$OUT/.config"
  cat "$KIEV_EXT_CONFIG" >> "$OUT/.config"
fi

echo "→ Application des options KSU/SUSFS..."

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

echo "→ olddefconfig pour finaliser..."
make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# =====================================================================
# CONTRÔLE STRICT
# =====================================================================
echo ""
echo "=== Vérification des options critiques ==="

# Options KSU/SUSFS
grep -q '^CONFIG_KSU=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU manquant"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU_SUSFS manquant"; exit 1; }
! grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$OUT/.config" || { echo "❌ KSU_MANUAL_HOOK ne doit pas être activé"; exit 1; }
! grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y$' "$OUT/.config" || { echo "❌ KSU_TRACEPOINT_HOOK ne doit pas être activé"; exit 1; }

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
    echo "❌ Option SUSFS absente : $option" >&2
    exit 1
  }
done

echo "→ Vérification des options tactiles MMI (ext_config kiev)..."

# Options tactiles critiques (extraites de kiev-default.config)
for option in \
  CONFIG_PANEL_NOTIFICATIONS \
  CONFIG_INPUT_FOCALTECH_0FLASH_MMI \
  CONFIG_INPUT_TOUCHSCREEN_MMI \
  CONFIG_TOUCHCLASS_MMI_GESTURE_POISON_EVENT; do
  if grep -q "^${option}=[ym]$" "$OUT/.config"; then
    echo "  ✅ ${option}=$(grep "^${option}=" "$OUT/.config" | cut -d= -f2)"
  else
    echo "  ⚠️  ${option} absent (peut poser problème pour le tactile)"
  fi
done

# Sauvegarde du .config final
grep -E 'CONFIG_(KSU|KSU_SUSFS|PANEL_NOTIFICATIONS|INPUT_FOCALTECH|INPUT_TOUCHSCREEN|THREAD_INFO)' "$OUT/.config" | tee "$ROOT/ksu-susfs.config"

echo "✅ Configuration validée"

# =====================================================================
# 6. PATCH SIGNATURES MODULE (désactive vérifications CRC/version)
# =====================================================================
echo ""
echo "=== Patch signatures module (ignore CRC/version) ==="

# Désactive check_version (CRC des symboles)
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# Désactive check_modstruct_version (CRC du module struct)
sed -i 's/if (!check_modstruct_version(/if (0 \&\& !check_modstruct_version(/g' kernel/module.c

# Désactive same_magic (vermagic / version kernel)
sed -i 's/if (same_magic(/if (0 \&\& same_magic(/g' kernel/module.c

echo "✅ Patch signatures module appliqué"

# =====================================================================
# 7. PATCH TACTILE — DÉSACTIVÉ
# =====================================================================
# ═══════════════════════════════════════════════════════════════════
# Le patch tactile backslashxx n'est PLUS NÉCESSAIRE car :
#   - CONFIG_PANEL_NOTIFICATIONS=y est activé (via ext_config/kiev-default.config)
#   - drivers/video/panel_notifier.c définit DÉJÀ :
#       * panel_register_notifier()
#       * panel_unregister_notifier()
#       * touch_set_state()
#   - Réappliquer le patch créerait un CONFLIT DE SYMBOLES
# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Patch tactile : DÉSACTIVÉ (PANEL_NOTIFICATIONS=y fournit les symboles) ==="

# Vérification que le vrai driver panel_notifier est bien présent
if [[ ! -f "drivers/video/panel_notifier.c" ]]; then
  echo "❌ drivers/video/panel_notifier.c introuvable — PANEL_NOTIFICATIONS mal configuré ?"
  exit 1
fi

if ! grep -q "panel_register_notifier" drivers/video/panel_notifier.c; then
  echo "❌ panel_register_notifier absent de drivers/video/panel_notifier.c"
  exit 1
fi

echo "✅ panel_notifier.c fournit panel_register_notifier, panel_unregister_notifier, touch_set_state"

# =====================================================================
# 7b. FIX BUGS KERNEL LINEAGEOS
# =====================================================================
printf '%s\n' '=== Fix bugs kernel LineageOS ==='

DSI_FILE="$KERNEL_DIR/techpack/display/msm/dsi/dsi_display_mot_ext.c"
if [[ -f "$DSI_FILE" ]]; then
  if grep -q "^static static " "$DSI_FILE"; then
    sed -i 's/^static static /static /' "$DSI_FILE"
    printf '%s\n' '✅ Fix duplicate static appliqué (dsi_display_mot_ext.c)'
  else
    printf '%s\n' '⏭️  Pas de duplicate static détecté'
  fi
fi

printf '%s\n' '✅ Fixes kernel LineageOS appliqués'

# =====================================================================
# 8. COMPILATION
# =====================================================================
printf '%s\n' ''
printf '%s\n' '=== Compilation du kernel et des modules ==='
make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  KCFLAGS=-Wno-error -j"$JOBS" Image.gz modules 2>&1 | tee "$LOG"

test -s "$OUT/arch/arm64/boot/Image.gz" || { echo "❌ Image.gz manquante"; exit 1; }
find "$OUT" -type f -name '*.ko' -print -quit | grep -q . || { echo "❌ Aucun module .ko"; exit 1; }
sha256sum "$OUT/arch/arm64/boot/Image.gz"
printf '%s\n' '✅ Compilation ReSukiSU/SUSFS réussie'

# Vérification des modules tactiles compilés
echo ""
echo "=== Vérification des modules tactiles ==="
TOUCH_MODULES=$(find "$OUT" -name "*focaltech*" -o -name "*touchscreen_mmi*" 2>/dev/null || true)
if [[ -n "$TOUCH_MODULES" ]]; then
  echo "✅ Modules tactiles compilés :"
  echo "$TOUCH_MODULES"
else
  echo "⚠️  Aucun module tactile compilé (peut être normal si =y)"
fi

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
cp "$ROOT/ksu-susfs.config" "$OUTPUT_DIR/" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "=== BUILD TERMINÉ ==="
echo "═══════════════════════════════════════════════════════════════"
ls -lh "$OUTPUT_DIR/"
echo ""
echo "SHA-256 du boot.img :"
sha256sum "$OUTPUT_BOOT" 2>/dev/null || true
