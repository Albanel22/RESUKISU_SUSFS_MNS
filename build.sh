#!/usr/bin/env bash
# =============================================================================
# BUILD : ReSukiSU + SUSFS cyberc3dr + MANUAL HOOK (combinaison finale)
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche par défaut)
# ReSukiSU : ReSukiSU/ReSukiSU @ 90b4a4c7
# Hooks    : KSU_MANUAL_HOOK (stat, execve, faccessat, reboot)
# SUSFS    : patch cyberc3dr nGKI (méthode backslashxx, PAS inline hook)
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
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
OUTPUT_BOOT="$OUTPUT_DIR/boot-resukisu-cyberc3dr-manualhook-kiev.img"

mkdir -p "$ROOT" "$REFERENCE_DIR" "$OUTPUT_DIR"

echo "═══════════════════════════════════════════════════════════════"
echo "=== BUILD ReSukiSU + SUSFS cyberc3dr + MANUAL HOOK ==="
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
# 4. SUSFS cyberc3dr (méthode backslashxx)
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

REJECTS=$(find "$KERNEL_DIR" -type f -name '*.rej' -print)
SUSFS_FIX_PATCH="${SUSFS_FIX_PATCH:-$SCRIPT_DIR/susfs_kiev_lito_fix.patch}"

if [ "$SUSFS_PATCH_RC" -ne 0 ] || [ -n "$REJECTS" ]; then
  echo "⚠️  Rejets détectés dans le patch SUSFS cyberc3dr"
  mkdir -p "$REJ_DIR"
  find "$KERNEL_DIR" -type f -name '*.rej' -exec cp {} "$REJ_DIR/" \; 2>/dev/null || true

  if [ ! -f "$SUSFS_FIX_PATCH" ]; then
    echo "❌ Rejets SUSFS + correctif kiev/lito absent : $SUSFS_FIX_PATCH"
    echo "→ Les .rej sont sauvegardés dans $REJ_DIR/"
    cat /tmp/susfs_patch.log | tail -30
    exit 1
  fi

  echo "→ Application du correctif kiev/lito..."
  patch --batch --forward -p1 < "$SUSFS_FIX_PATCH" > /tmp/susfs_kiev_lito_fix.log 2>&1 || {
    cat /tmp/susfs_kiev_lito_fix.log
    exit 1
  }
  find "$KERNEL_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -delete
fi

find "$KERNEL_DIR" -type f -name '*.orig' -delete

# Fix include susfs_def.h dans fs/stat.c
python3 - <<'PYEOF_STAT'
from pathlib import Path
path = Path("fs/stat.c")
text = path.read_text()
include = "#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT\n#include <linux/susfs_def.h>\n#endif\n"
if "#include <linux/susfs_def.h>" not in text:
    marker = "#include <asm/unistd.h>\n"
    if marker in text:
        text = text.replace(marker, marker + "\n" + include, 1)
        path.write_text(text)
        print("✅ include susfs_def.h ajouté à fs/stat.c")
PYEOF_STAT

# Fix susfs_run_sus_path_loop global
python3 - <<'PYEOF_SYMBOL'
from pathlib import Path
path = Path("fs/susfs.c")
text = path.read_text()
old = "static void susfs_run_sus_path_loop(void)"
new = "void susfs_run_sus_path_loop(void)"
if old in text:
    text = text.replace(old, new, 1)
    path.write_text(text)
    print("✅ susfs_run_sus_path_loop global")
elif new in text:
    print("✅ susfs_run_sus_path_loop déjà global")
PYEOF_SYMBOL

# Correction Python kiev/lito pour namespace.c, super.c, task_mmu.c
python3 << 'PYEOF_FIX'
import re, sys
from pathlib import Path

KERNEL = Path(".")
fixes = []

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
ns_path.write_text(text)

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
ns_path.write_text(text)

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
super_path.write_text(text)

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
    if count > 0:
        text = new_text
        fixes.append("task_mmu.c: bloc SUS_MAP inséré")
mmu_path.write_text(text)

print("")
print("=== Corrections SUSFS appliquées ===")
for f in fixes: print(f"  ✅ {f}")
PYEOF_FIX

echo "✅ Patch SUSFS cyberc3dr appliqué"

# =====================================================================
# 4b. HOOKS MANUELS ReSukiSU (obligatoires)
# =====================================================================
echo ""
echo "================================================================"
echo "=== HOOKS MANUELS ReSukiSU (stat, execve, faccessat, reboot) ==="
echo "================================================================"

# Hook 1 : stat
echo "→ Hook 1/4 : stat (fs/stat.c)"
python3 << 'PYEOF_STAT'
import re, sys
from pathlib import Path
p = Path("fs/stat.c")
text = p.read_text()
if "ksu_handle_stat" in text:
    print("  ⏭️  déjà présent"); sys.exit(0)
externs = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#endif
'''
pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
new_text, n = re.subn(pattern, externs + '\n' + r'\1', text, count=1)
if n == 0: print("  ❌ newfstatat introuvable", file=sys.stderr); sys.exit(1)
text = new_text
pattern = r'(SYSCALL_DEFINE4\(newfstatat[^)]+\)\s*\{)'
new_text, n = re.subn(pattern, r'''\1
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif''', text, count=1)
if n > 0: text = new_text
p.write_text(text)
print("  ✅ Hook stat appliqué")
PYEOF_STAT

# Hook 2 : execve
echo "→ Hook 2/4 : execve (fs/exec.c)"
python3 << 'PYEOF_EXECVE'
import re, sys
from pathlib import Path
p = Path("fs/exec.c")
text = p.read_text()
if "ksu_handle_execveat" in text:
    print("  ⏭️  déjà présent"); sys.exit(0)
externs = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags);
__attribute__((hot))
extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags, int *retval);
#endif
'''
pattern = r'(static int do_execveat_common\()'
new_text, n = re.subn(pattern, externs + '\n' + r'\1', text, count=1)
if n == 0: print("  ❌ do_execveat_common introuvable", file=sys.stderr); sys.exit(1)
text = new_text

old_call = "\treturn __do_execve_file(fd, filename, argv, envp, flags, NULL);"
new_call = """#ifdef CONFIG_KSU_MANUAL_HOOK
	int retval;
	ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
	retval = __do_execve_file(fd, filename, argv, envp, flags, NULL);
	ksu_handle_post_execveat(&fd, &filename, &argv, &envp, &flags, &retval);
	return retval;
#else
	return __do_execve_file(fd, filename, argv, envp, flags, NULL);
#endif"""
if old_call in text:
    text = text.replace(old_call, new_call, 1)
p.write_text(text)
print("  ✅ Hook execve appliqué")
PYEOF_EXECVE

# Hook 3 : faccessat
echo "→ Hook 3/4 : faccessat (fs/open.c)"
python3 << 'PYEOF_FACCESSAT'
import re, sys
from pathlib import Path
p = Path("fs/open.c")
text = p.read_text()
if "ksu_handle_faccessat" in text:
    print("  ⏭️  déjà présent"); sys.exit(0)
externs = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);
#endif
'''
pattern = r'(SYSCALL_DEFINE3\(faccessat,)'
new_text, n = re.subn(pattern, externs + '\n' + r'\1', text, count=1)
if n == 0: print("  ❌ faccessat introuvable", file=sys.stderr); sys.exit(1)
text = new_text
pattern = r'(SYSCALL_DEFINE3\(faccessat[^)]+\)\s*\{)'
new_text, n = re.subn(pattern, r'''\1
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif''', text, count=1)
if n > 0: text = new_text
p.write_text(text)
print("  ✅ Hook faccessat appliqué")
PYEOF_FACCESSAT

# Hook 4 : reboot
echo "→ Hook 4/4 : reboot (kernel/reboot.c)"
python3 << 'PYEOF_REBOOT'
import re, sys
from pathlib import Path
p = Path("kernel/reboot.c")
text = p.read_text()
if "ksu_handle_sys_reboot" in text:
    print("  ⏭️  déjà présent"); sys.exit(0)
externs = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''
pattern = r'(SYSCALL_DEFINE4\(reboot, int, magic1, int, magic2, unsigned int, cmd,)'
new_text, n = re.subn(pattern, externs + '\n' + r'\1', text, count=1)
if n == 0:
    print("  ⚠️  reboot introuvable dans reboot.c", file=sys.stderr); sys.exit(1)
text = new_text
old = "\tchar buffer[256];\n\tint ret = 0;"
new = """	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif"""
if old in text:
    text = text.replace(old, new, 1)
p.write_text(text)
print("  ✅ Hook reboot appliqué")
PYEOF_REBOOT

# Vérification finale
echo ""
echo "=== Vérification des hooks ==="
HOOK_FAIL=0
for f in "fs/stat.c:ksu_handle_stat" "fs/exec.c:ksu_handle_execveat" "fs/open.c:ksu_handle_faccessat" "kernel/reboot.c:ksu_handle_sys_reboot"; do
  file="${f%%:*}"; sym="${f##*:}"
  if grep -q "$sym" "$file"; then
    echo "  ✅ $file : $sym"
  else
    echo "  ❌ $file : $sym MANQUANT"
    HOOK_FAIL=1
  fi
done
[[ "$HOOK_FAIL" -eq 0 ]] || { echo "❌ Hooks manquants"; exit 1; }

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

echo "→ Application des options KSU/SUSFS + MANUAL HOOK..."

SCRIPTS_CONFIG="$KERNEL_DIR/scripts/config"
[[ -x "$SCRIPTS_CONFIG" ]] || chmod +x "$SCRIPTS_CONFIG"

# ═══════════════════════════════════════════════════════════════════
# CONFIG FINALE : MANUAL_HOOK + SUSFS cyberc3dr (PAS de KSU_SUSFS)
# ═══════════════════════════════════════════════════════════════════
"$SCRIPTS_CONFIG" --file "$OUT/.config" \
  --enable KSU \
  --enable KSU_MULTI_MANAGER_SUPPORT \
  --disable KSU_TAMPER_SYSCALL_TABLE \
  --disable KSU_HACK_ARM64_BRANCH_LINK \
  --disable KSU_TRACEPOINT_HOOK \
  --enable KSU_MANUAL_HOOK \
  --enable KSU_MANUAL_HOOK_AUTO_SETUID_HOOK \
  --enable KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
  --enable KSU_MANUAL_HOOK_AUTO_INPUT_HOOK \
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
  --disable CC_WERROR \
  --disable INPUT_FOCALTECH_0FLASH_MMI \
  --disable INPUT_TOUCHSCREEN_MMI \
  --disable TOUCHCLASS_MMI_GESTURE_POISON_EVENT

echo "→ olddefconfig..."
make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

# =====================================================================
# VÉRIFICATIONS CRITIQUES
# =====================================================================
echo ""
echo "=== Vérification des options critiques ==="

grep -q '^CONFIG_KSU=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU_MANUAL_HOOK"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y$' "$OUT/.config" || { echo "❌ AUTO_SETUID"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y$' "$OUT/.config" || { echo "❌ AUTO_INITRC"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y$' "$OUT/.config" || { echo "❌ AUTO_INPUT"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU_SUSFS"; exit 1; }
! grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y$' "$OUT/.config" || { echo "❌ KSU_TRACEPOINT_HOOK doit être désactivé"; exit 1; }

echo "  ✅ KSU + MANUAL_HOOK + SUSFS (cyberc3dr)"

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

grep -E 'CONFIG_(KSU|KSU_SUSFS|KSU_MANUAL|PANEL_NOTIFICATIONS|INPUT_FOCALTECH|INPUT_TOUCHSCREEN)' "$OUT/.config" | tee "$ROOT/ksu-susfs.config"

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
cp "$LOG" "$OUTPUT_DIR/build.log" 2>/dev/null || true
cp "$ROOT/ksu-susfs.config" "$OUTPUT_DIR/" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "=== BUILD TERMINÉ (ReSukiSU + SUSFS cyberc3dr + MANUAL HOOK) ==="
echo "═══════════════════════════════════════════════════════════════"
ls -lh "$OUTPUT_DIR/"
echo ""
echo "SHA-256 du boot.img :"
sha256sum "$OUTPUT_BOOT" 2>/dev/null || true
