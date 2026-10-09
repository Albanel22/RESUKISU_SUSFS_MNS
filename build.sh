#!/usr/bin/env bash
# =============================================================================
# BUILD : ReSukiSU + SUSFS cyberc3dr + INLINE HOOK (version corrigée)
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche par défaut)
# ReSukiSU : ReSukiSU/ReSukiSU @ 90b4a4c7
# Hooks    : SUSFS Inline hook (posés par le patch cyberc3dr)
# SUSFS    : patch cyberc3dr nGKI + corrections Python intégrées
#
# Changements par rapport à la version "manual hook" :
#  - KSU_MANUAL_HOOK, KSU_TRACEPOINT_HOOK et KSU_SUSFS sont dans le même
#    "choice" Kconfig : exclusifs. SUSFS => inline hook, donc les hooks
#    manuels (ancienne section 4b) sont supprimés.
#  - Les pilotes tactiles (focaltech_0flash_mmi, touchscreen_mmi) ne sont
#    plus désactivés, et leur présence est vérifiée.
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
NGKI_REPO="https://github.com/cyberc3dr/nGKI_Kernel_Build.git"
NGKI_BRANCH="rebase"
SUSFS_PATCH_REL="Patches/Patch/susfs_patch_to_4.19.patch"
BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img"

# ─── Sortie ─────────────────────────────────────────────────────────────
OUTPUT_BOOT="$OUTPUT_DIR/boot-resukisu-cyberc3dr-inlinehook-kiev.img"

mkdir -p "$ROOT" "$REFERENCE_DIR" "$OUTPUT_DIR"

echo "═══════════════════════════════════════════════════════════════"
echo "=== BUILD ReSukiSU + SUSFS cyberc3dr + INLINE HOOK ==="
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

echo "→ Intégration Kconfig ReSukiSU..."
if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"; then
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig"
  echo "✅ source Kconfig ajouté"
fi
if ! grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile"; then
  echo 'obj-$(CONFIG_KSU) += kernelsu/' >> "$KERNEL_DIR/drivers/Makefile"
  echo "✅ obj- Makefile ajouté"
fi
grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig" || { echo "❌ Kconfig ReSukiSU"; exit 1; }
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || { echo "❌ Makefile ReSukiSU"; exit 1; }
echo "✅ ReSukiSU intégré"

# =====================================================================
# 4. SUSFS cyberc3dr + CORRECTIONS PYTHON INTÉGRÉES
# =====================================================================
echo ""
echo "=== Intégration SUSFS cyberc3dr (nGKI 4.19) ==="

NGKI_DIR="/tmp/nGKI_Kernel_Build"
rm -rf "$NGKI_DIR"
git clone --depth=1 --branch "$NGKI_BRANCH" "$NGKI_REPO" "$NGKI_DIR"
SUSFS_PATCH="$NGKI_DIR/$SUSFS_PATCH_REL"

if [ ! -f "$SUSFS_PATCH" ]; then
  echo "❌ Patch nGKI SUSFS 4.19 introuvable : $SUSFS_PATCH"
  exit 1
fi

cd "$KERNEL_DIR"

set +e
patch --batch --forward -p1 < "$SUSFS_PATCH" > /tmp/susfs_patch.log 2>&1
SUSFS_PATCH_RC=$?
set -e

if [ "$SUSFS_PATCH_RC" -ne 0 ]; then
  echo "⚠️  Rejets détectés dans le patch SUSFS cyberc3dr"
  mkdir -p "$REJ_DIR"
  find "$KERNEL_DIR" -type f -name '*.rej' -exec cp {} "$REJ_DIR/" \; 2>/dev/null || true
  echo "→ Corrections Python appliquées ci-dessous"
fi

# Nettoyage des .rej et .orig (les corrections Python vont les remplacer)
find "$KERNEL_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -delete

echo ""
echo "=== Application des corrections Python kiev/lito ==="

python3 << 'PYEOF_FIX'
import re, sys
from pathlib import Path

KERNEL = Path(".")
fixes = []

# ═══════════════════════════════════════════════════════════════════════
# FIX 1 : fs/namespace.c — includes SUSFS
# ═══════════════════════════════════════════════════════════════════════
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
        fixes.append("namespace.c: includes SUSFS ajoutés")
    else:
        print("❌ namespace.c : marqueur fs_context.h non trouvé", file=sys.stderr)
        sys.exit(1)
else:
    fixes.append("namespace.c: includes SUSFS déjà présents")
ns_path.write_text(text)

# ═══════════════════════════════════════════════════════════════════════
# FIX 2 : fs/namespace.c — vfs_create_mount (SUS_MOUNT)
# ═══════════════════════════════════════════════════════════════════════
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
        fixes.append("namespace.c: vfs_create_mount patché")
    else:
        print("❌ namespace.c : bloc vfs_create_mount non trouvé", file=sys.stderr)
        sys.exit(1)
else:
    fixes.append("namespace.c: vfs_create_mount déjà patché")
ns_path.write_text(text)

# ═══════════════════════════════════════════════════════════════════════
# FIX 3 : fs/super.c — includes SUSFS
# ═══════════════════════════════════════════════════════════════════════
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
        fixes.append("super.c: includes SUSFS ajoutés")
    else:
        print("❌ super.c : marqueur fs_context.h non trouvé", file=sys.stderr)
        sys.exit(1)
else:
    fixes.append("super.c: includes SUSFS déjà présents")
super_path.write_text(text)

# ═══════════════════════════════════════════════════════════════════════
# FIX 4 : fs/proc/task_mmu.c — SUS_MAP
# ═══════════════════════════════════════════════════════════════════════
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
        fixes.append("task_mmu.c: bloc SUS_MAP inséré")
else:
    fixes.append("task_mmu.c: bloc SUS_MAP déjà présent")

# Déclaration vma
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
            fixes.append("task_mmu.c: déclaration vma ajoutée")
    else:
        fixes.append("task_mmu.c: vma déjà déclarée")
mmu_path.write_text(text)

# ═══════════════════════════════════════════════════════════════════════
# FIX 5 : include susfs_def.h dans fs/stat.c (si nécessaire)
# ═══════════════════════════════════════════════════════════════════════
stat_path = KERNEL / "fs" / "stat.c"
text = stat_path.read_text()
include_block = "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n"
if "#include <linux/susfs_def.h>" not in text:
    marker = "#include <asm/unistd.h>\n"
    if marker in text:
        text = text.replace(marker, marker + "\n" + include_block, 1)
        stat_path.write_text(text)
        fixes.append("stat.c: include susfs_def.h ajouté")

# ═══════════════════════════════════════════════════════════════════════
# FIX 6 : susfs_run_sus_path_loop global
# ═══════════════════════════════════════════════════════════════════════
susfs_c = KERNEL / "fs" / "susfs.c"
if susfs_c.exists():
    text = susfs_c.read_text()
    old = "static void susfs_run_sus_path_loop(void)"
    new = "void susfs_run_sus_path_loop(void)"
    if old in text:
        text = text.replace(old, new, 1)
        susfs_c.write_text(text)
        fixes.append("susfs.c: susfs_run_sus_path_loop global")

print("")
print("=== Corrections appliquées ===")
for f in fixes: print(f"  ✅ {f}")
print("✅ Corrections Python terminées")
PYEOF_FIX

echo "✅ Patch SUSFS cyberc3dr + corrections appliqués"

# =====================================================================
# 4b. VÉRIFICATION DES HOOKS INLINE (posés par le patch SUSFS)
#     (les anciens hooks manuels sont supprimés : KSU_MANUAL_HOOK est
#      exclusif avec KSU_SUSFS dans le choice Kconfig de ReSukiSU)
# =====================================================================
echo ""
echo "=== Vérification des hooks inline (informatif) ==="
for f in \
  "fs/stat.c:ksu_handle_stat" \
  "fs/exec.c:ksu_handle_execveat" \
  "fs/open.c:ksu_handle_faccessat" \
  "kernel/reboot.c:ksu_handle_sys_reboot" \
  "kernel/sys.c:ksu_handle_setresuid" \
  "fs/read_write.c:ksu_handle_sys_read" \
  "drivers/input/input.c:ksu_handle_input_handle_event"; do
  file="${f%%:*}"; sym="${f##*:}"
  if grep -q "$sym" "$file" 2>/dev/null; then
    echo "  ✅ $file : $sym"
  else
    echo "  ⚠️  $file : $sym absent (à confirmer dans le log ReSukiSU 'found')"
  fi
done

# =====================================================================
# 5. CONFIGURATION KERNEL — FUSION defconfig + ext_config kiev
# =====================================================================
cd "$KERNEL_DIR"
rm -rf "$OUT"
mkdir -p "$OUT"

echo ""
echo "=== Configuration kernel ==="

KIEV_EXT_CONFIG="arch/arm64/configs/vendor/ext_config/kiev-default.config"
BASE_DEFCONFIG="arch/arm64/configs/vendor/lito-perf_defconfig"

if [[ -x "scripts/kconfig/merge_config.sh" ]]; then
  echo "→ Fusion via merge_config.sh..."
  ./scripts/kconfig/merge_config.sh -O "$OUT" -m "$BASE_DEFCONFIG" "$KIEV_EXT_CONFIG" || {
    cat "$BASE_DEFCONFIG" > "$OUT/.config"
    echo "" >> "$OUT/.config"
    echo "# ═══ ext_config kiev-default ═══" >> "$OUT/.config"
    cat "$KIEV_EXT_CONFIG" >> "$OUT/.config"
  }
else
  cat "$BASE_DEFCONFIG" > "$OUT/.config"
  echo "" >> "$OUT/.config"
  echo "# ═══ ext_config kiev-default ═══" >> "$OUT/.config"
  cat "$KIEV_EXT_CONFIG" >> "$OUT/.config"
fi

echo "→ Application des options KSU/SUSFS (inline hook)..."

SCRIPTS_CONFIG="$KERNEL_DIR/scripts/config"
[[ -x "$SCRIPTS_CONFIG" ]] || chmod +x "$SCRIPTS_CONFIG"

# ═══════════════════════════════════════════════════════════════════
# CONFIG FINALE (le tactile n'est PAS touché : il vient de kiev-default)
# ═══════════════════════════════════════════════════════════════════
"$SCRIPTS_CONFIG" --file "$OUT/.config" \
  --enable KSU \
  --enable KSU_MULTI_MANAGER_SUPPORT \
  --disable KSU_TAMPER_SYSCALL_TABLE \
  --disable KSU_HACK_ARM64_BRANCH_LINK \
  --disable KSU_TRACEPOINT_HOOK \
  --disable KSU_MANUAL_HOOK \
  --disable KSU_KPROBES_KSUD \
  --enable KSU_LSM_SECURITY_HOOKS \
  --enable KSU_FEATURE_SULOG \
  --enable KSU_FEATURE_ADBROOT \
  --enable THREAD_INFO_IN_TASK \
  --enable KSU_SUSFS \
  --enable KSU_SUSFS_SUS_PATH \
  --enable KSU_SUSFS_SUS_MOUNT \
  --enable KSU_SUSFS_SUS_KSTAT \
  --enable KSU_SUSFS_SPOOF_UNAME \
  --enable KSU_SUSFS_ENABLE_LOG \
  --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
  --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
  --disable KSU_SUSFS_OPEN_REDIRECT \
  --disable KSU_SUSFS_SUS_MAP \
  --disable KPROBES \
  --disable HAVE_KPROBES \
  --disable KPROBE_EVENTS \
  --enable KALLSYMS \
  --enable KALLSYMS_ALL \
  --disable CC_WERROR

echo "→ olddefconfig..."
make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# =====================================================================
# VÉRIFICATIONS CRITIQUES
# =====================================================================
echo ""
echo "=== Vérification des options critiques ==="

grep -q '^CONFIG_KSU=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU_SUSFS"; exit 1; }
! grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$OUT/.config" || { echo "❌ KSU_MANUAL_HOOK doit être désactivé (inline hook)"; exit 1; }
! grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y$' "$OUT/.config" || { echo "❌ KSU_TRACEPOINT_HOOK doit être désactivé"; exit 1; }
echo "  ✅ KSU + SUSFS (inline hook)"

for option in \
  CONFIG_KSU_SUSFS_SUS_PATH \
  CONFIG_KSU_SUSFS_SUS_MOUNT \
  CONFIG_KSU_SUSFS_SUS_KSTAT \
  CONFIG_KSU_SUSFS_SPOOF_UNAME \
  CONFIG_KSU_SUSFS_ENABLE_LOG \
  CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
  CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG; do
  grep -q "^${option}=y$" "$OUT/.config" || { echo "❌ $option manquant"; exit 1; }
done
echo "  ✅ Fonctionnalités SUSFS activées"

grep -q '^CONFIG_PANEL_NOTIFICATIONS=y$' "$OUT/.config" && echo "  ✅ PANEL_NOTIFICATIONS=y" || { echo "❌ PANEL_NOTIFICATIONS"; exit 1; }

# Tactile : doit rester actif (modules vendor Motorola comme backslashxx)
grep -q '^CONFIG_INPUT_FOCALTECH_0FLASH_MMI=[ym]$' "$OUT/.config" \
  || { echo "❌ INPUT_FOCALTECH_0FLASH_MMI non activé"; grep -iE 'FOCALTECH|TOUCHSCREEN_MMI' "$OUT/.config" || true; exit 1; }
grep -q '^CONFIG_INPUT_TOUCHSCREEN_MMI=[ym]$' "$OUT/.config" \
  || { echo "❌ INPUT_TOUCHSCREEN_MMI non activé"; grep -iE 'FOCALTECH|TOUCHSCREEN_MMI' "$OUT/.config" || true; exit 1; }
echo "  ✅ Tactile (focaltech_0flash_mmi / touchscreen_mmi) activé"

grep -E 'CONFIG_(KSU|KSU_SUSFS|PANEL_NOTIFICATIONS|INPUT_FOCALTECH|INPUT_TOUCHSCREEN|TOUCHCLASS)' "$OUT/.config" | tee "$ROOT/ksu-susfs.config"

# =====================================================================
# 6. PATCH SIGNATURES MODULE
# =====================================================================
echo ""
echo "=== Patch signatures module ==="
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c
sed -i 's/if (!check_modstruct_version(/if (0 \&\& !check_modstruct_version(/g' kernel/module.c
sed -i 's/if (same_magic(/if (0 \&\& same_magic(/g' kernel/module.c
echo "✅ Patch signatures module appliqué"

# =====================================================================
# 7. FIX BUGS KERNEL LINEAGEOS
# =====================================================================
echo ""
echo "=== Fix bugs kernel LineageOS ==="
DSI_FILE="$KERNEL_DIR/techpack/display/msm/dsi/dsi_display_mot_ext.c"
if [[ -f "$DSI_FILE" ]] && grep -q "^static static " "$DSI_FILE"; then
  sed -i 's/^static static /static /' "$DSI_FILE"
  echo "  ✅ Fix duplicate static appliqué"
fi

# =====================================================================
# 8. COMPILATION
# =====================================================================
echo ""
echo "=== Compilation du kernel et des modules ==="
make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  KCFLAGS=-Wno-error -j"$JOBS" Image.gz modules 2>&1 | tee "$LOG"

test -s "$OUT/arch/arm64/boot/Image.gz" || { echo "❌ Image.gz manquante"; exit 1; }
find "$OUT" -type f -name '*.ko' -print -quit | grep -q . || { echo "❌ Aucun module .ko"; exit 1; }

# Les modules tactiles doivent avoir été compilés
for ko in focaltech_0flash_mmi.ko touchscreen_mmi.ko; do
  if find "$OUT" -type f -name "$ko" | grep -q .; then
    echo "  ✅ $ko compilé"
  else
    echo "❌ $ko absent de la compilation"; exit 1
  fi
done

sha256sum "$OUT/arch/arm64/boot/Image.gz"
echo "✅ Compilation réussie"

# =====================================================================
# 9. TÉLÉCHARGEMENT DES IMAGES DE RÉFÉRENCE
# =====================================================================
echo ""
echo "=== Téléchargement boot.img / dtbo.img ==="
cd "$ROOT"
if [[ ! -f "$REFERENCE_DIR/boot.img" ]]; then
  wget --retry-connrefused --tries=5 -O "$REFERENCE_DIR/boot.img" "$BOOT_URL"
fi
if [[ ! -f "$REFERENCE_DIR/dtbo.img" ]]; then
  wget --retry-connrefused --tries=5 -O "$REFERENCE_DIR/dtbo.img" "$DTBO_URL"
fi
sha256sum "$REFERENCE_DIR/boot.img" "$REFERENCE_DIR/dtbo.img"

# =====================================================================
# 10. REPACK DU BOOT.IMG
# =====================================================================
echo ""
echo "=== Repack du boot.img ==="

REPACK_PY="$ROOT/repack_bootimg_inline.py"
cat > "$REPACK_PY" << 'PYEOF_REPACK'
#!/usr/bin/env python3
import hashlib, os, shutil, struct, subprocess, tempfile
from pathlib import Path

ROOT = Path(os.environ["ROOT"])
REFERENCE = Path(os.environ["REFERENCE_BOOT"])
KERNEL = Path(os.environ["KERNEL_IMAGE"])
MODULE_ROOT = Path(os.environ["MODULE_ROOT"])
OUTPUT = Path(os.environ["OUTPUT_BOOT"])
MODULE_RELEASE = os.environ.get("MODULE_RELEASE", "4.19.325-resukisu-susfs")
PAGE_SIZE = 4096
TARGET_SIZE = REFERENCE.stat().st_size

def u32(buf, off): return struct.unpack_from("<I", buf, off)[0]
def put_u32(buf, off, value): struct.pack_into("<I", buf, off, value)
def align(value, page=PAGE_SIZE): return (value + page - 1) // page * page
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
    find_proc = subprocess.Popen(["find", ".", "-print0"], cwd=ramdisk_dir, stdout=subprocess.PIPE)
    with new_cpio.open("wb") as out:
        run(["cpio", "--null", "-o", "-H", "newc"], cwd=ramdisk_dir, stdin=find_proc.stdout, stdout=out)
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
cp "$OUT/.config" "$OUTPUT_DIR/final.config" 2>/dev/null || true
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
