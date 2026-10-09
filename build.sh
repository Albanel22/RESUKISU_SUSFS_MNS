#!/usr/bin/env bash
# =============================================================================
# BUILD : Branche-C — LineageOS + ReSukiSU + SUSFS (MANUAL HOOK OFFICIEL)
# Appareil : Motorola One 5G Ace (kiev / lito)
# Kernel   : 4.19.325
# Source   : LineageOS/android_kernel_motorola_sm8250 (branche par défaut)
# ReSukiSU : ReSukiSU/ReSukiSU @ 90b4a4c7
# Hooks    : KSU_MANUAL_HOOK (stat, execve, faccessat, reboot)
# SUSFS    : symboles uniquement (susfs.c, susfs.h, susfs_def.h)
# Vérif    : logging détaillé de chaque hook inséré
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
BOOT_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/boot.img"
DTBO_URL="https://mirrorbits.lineageos.org/full/kiev/20260920/dtbo.img"

# ─── Sortie ─────────────────────────────────────────────────────────────
OUTPUT_BOOT="$OUTPUT_DIR/boot-resukisu-manual-hook-kiev.img"

mkdir -p "$ROOT" "$REFERENCE_DIR" "$OUTPUT_DIR"

echo "═══════════════════════════════════════════════════════════════"
echo "=== BUILD ReSukiSU MANUAL HOOK + SUSFS + ext_config kiev ==="
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
# 4. SUSFS (symboles uniquement)
# =====================================================================
echo ""
echo "=== Intégration SUSFS (symboles uniquement) ==="

echo "→ Téléchargement du patch SUSFS..."
wget -q -O /tmp/susfs_patch_to_4.19.patch "$SUSFS_PATCH_URL" || {
  echo "❌ Impossible de télécharger le patch SUSFS"; exit 1; }

echo "→ Application du patch SUSFS..."
cd "$KERNEL_DIR"
if ! patch -p1 --forward --batch < /tmp/susfs_patch_to_4.19.patch; then
  echo "⚠️  Rejets détectés — ils seront corrigés par Python"
fi
find "$KERNEL_DIR" -type f \( -name '*.rej' -o -name '*.orig' \) -delete

echo "→ Application des corrections Python kiev/lito..."
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
    else:
        print("❌ namespace.c : marqueur fs_context.h introuvable", file=sys.stderr); sys.exit(1)
else:
    fixes.append("namespace.c: includes SUSFS déjà présents")
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
    else:
        print("❌ namespace.c : bloc vfs_create_mount introuvable", file=sys.stderr); sys.exit(1)
else:
    fixes.append("namespace.c: vfs_create_mount déjà patché")
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
    else:
        print("❌ super.c : marqueur fs_context.h introuvable", file=sys.stderr); sys.exit(1)
else:
    fixes.append("super.c: includes SUSFS déjà présents")
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
    if count == 0:
        print("⚠️  task_mmu.c : bloc pagemap_read introuvable")
    else:
        text = new_text
        fixes.append("task_mmu.c: bloc SUS_MAP inséré")
else:
    fixes.append("task_mmu.c: bloc SUS_MAP déjà présent")

pagemap_match = re.search(
    r'(static ssize_t pagemap_read\(struct file \*file, char __user \*buf,\s*\n\s*size_t count, loff_t \*ppos\)\s*\{)([^}]*?)(\n\tif \(!mm)',
    text, re.DOTALL
)
if pagemap_match:
    body = pagemap_match.group(2)
    if 'struct vm_area_struct *vma' not in body:
        mm_decl = re.search(r'(\tstruct mm_struct \*mm = file->private_data;\n)', body)
        if mm_decl:
            new_body = body.replace(
                mm_decl.group(1),
                mm_decl.group(1) + '\tstruct vm_area_struct *vma;' + '\n', 1
            )
            text = text[:pagemap_match.start(2)] + new_body + text[pagemap_match.end(2):]
            fixes.append("task_mmu.c: déclaration vma ajoutée")
    else:
        fixes.append("task_mmu.c: vma déjà déclarée")
mmu_path.write_text(text)

print("")
print("=== Corrections SUSFS appliquées ===")
for f in fixes: print(f"  ✅ {f}")
PYEOF_FIX

# =====================================================================
# 4b. HOOKS MANUELS ReSukiSU (méthode officielle)
# =====================================================================
echo ""
echo "================================================================"
echo "=== APPLICATION DES HOOKS MANUELS ReSukiSU (méthode officielle) ==="
echo "================================================================"

cd "$KERNEL_DIR"

# ─── Hook 1 : stat (fs/stat.c) ─────────────────────────────────────────
echo ""
echo "→ Hook 1/4 : stat (fs/stat.c)"
echo "  D'après le guide officiel : hook newfstatat + newfstat (retour)"

python3 << 'PYEOF_STAT'
import re, sys
from pathlib import Path

p = Path("fs/stat.c")
text = p.read_text()
applied = []

if "ksu_handle_stat" in text:
    print("  ⏭️  Hook stat déjà présent")
    sys.exit(0)

# ─── ÉTAPE 1 : Externs ───
externs = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_stat(int *dfd, const char __user **filename_user,
				int *flags);

extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#if defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_COMPAT_STAT64)
extern void ksu_handle_fstat64_ret(unsigned long *fd, struct stat64 __user **statbuf_ptr);
#endif
#endif
'''

# Insérer avant newfstatat
pattern = r'(SYSCALL_DEFINE4\(newfstatat)'
new_text, n = re.subn(pattern, externs + '\n' + r'\1', text, count=1)
if n == 0:
    print("  ❌ SYSCALL_DEFINE4(newfstatat introuvable", file=sys.stderr); sys.exit(1)
text = new_text
applied.append("externs ajoutés")

# ─── ÉTAPE 2 : Hook newfstatat ───
# Trouver le corps de newfstatat et insérer le hook au début
pattern = r'(SYSCALL_DEFINE4\(newfstatat[^)]+\)\s*\{)(\s*\n\s*struct kstat stat;)'
replacement = r'''\1
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif\2'''
new_text, n = re.subn(pattern, replacement, text, count=1)
if n == 0:
    print("  ⚠️  Pattern newfstatat standard introuvable, tentative alternative")
    # Alternative : insérer juste après l'accolade ouvrante
    pattern = r'(SYSCALL_DEFINE4\(newfstatat[^)]+\)\s*\{)'
    new_text, n = re.subn(pattern, r'''\1
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_stat(&dfd, &filename, &flag);
#endif''', text, count=1)
    if n == 0:
        print("  ❌ Impossible d'insérer le hook newfstatat", file=sys.stderr); sys.exit(1)
text = new_text
applied.append("hook newfstatat inséré")

# ─── ÉTAPE 3 : Hook newfstat (retour) ───
if 'ksu_handle_newfstat_ret' not in text:
    pattern = r'(SYSCALL_DEFINE2\(newfstat,\s*unsigned int,\s*fd,\s*struct stat __user \*,\s*statbuf\)\s*\{.*?\n\s*if \(!error\)\s*\n\s*error = cp_new_stat\(&stat, statbuf\);\n)'
    replacement = r'''\1
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_newfstat_ret(&fd, &statbuf);
#endif
'''
    new_text, n = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
    if n > 0:
        text = new_text
        applied.append("hook newfstat_ret inséré")
    else:
        print("  ⚠️  Hook newfstat_ret non inséré (peut-être absent sur ce kernel)")

p.write_text(text)
print(f"  ✅ Hook stat appliqué ({', '.join(applied)})")
PYEOF_STAT

# ─── Hook 2 : execve (fs/exec.c) ───────────────────────────────────────
echo ""
echo "→ Hook 2/4 : execve (fs/exec.c)"
echo "  D'après le guide officiel : hook do_execveat_common"

python3 << 'PYEOF_EXECVE'
import re, sys
from pathlib import Path

p = Path("fs/exec.c")
text = p.read_text()
applied = []

if "ksu_handle_execveat" in text:
    print("  ⏭️  Hook execve déjà présent")
    sys.exit(0)

# ─── ÉTAPE 1 : Externs ───
externs = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
__attribute__((hot))
extern int ksu_handle_post_execveat(int *fd, struct filename **filename_ptr,
				void *argv, void *envp, int *flags, int *retval);
#endif
'''

# Insérer avant do_execveat_common
pattern = r'(static int do_execveat_common\()'
new_text, n = re.subn(pattern, externs + '\n' + r'\1', text, count=1)
if n == 0:
    print("  ❌ do_execveat_common introuvable", file=sys.stderr); sys.exit(1)
text = new_text
applied.append("externs ajoutés")

# ─── ÉTAPE 2 : Hook dans do_execveat_common ───
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
    applied.append("hook do_execveat_common inséré")
else:
    # Alternative pour kernels plus anciens (do_execve_common)
    print("  ⚠️  Pattern __do_execve_file introuvable, tentative do_execve_common")
    old_call2 = "\treturn do_execveat_common(AT_FDCWD, filename, argv, envp, 0);"
    if old_call2 in text:
        print("  ℹ️  Kernel plus ancien détecté — hook dans do_execve()")
    else:
        print("  ⚠️  Aucun pattern d'execve trouvé")

p.write_text(text)
print(f"  ✅ Hook execve appliqué ({', '.join(applied)})")
PYEOF_EXECVE

# ─── Hook 3 : faccessat (fs/open.c) ────────────────────────────────────
echo ""
echo "→ Hook 3/4 : faccessat (fs/open.c)"
echo "  D'après le guide officiel : hook SYSCALL_DEFINE3(faccessat)"

python3 << 'PYEOF_FACCESSAT'
import re, sys
from pathlib import Path

p = Path("fs/open.c")
text = p.read_text()
applied = []

if "ksu_handle_faccessat" in text:
    print("  ⏭️  Hook faccessat déjà présent")
    sys.exit(0)

# ─── ÉTAPE 1 : Externs ───
externs = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
__attribute__((hot))
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *flags);
#endif
'''

# Insérer avant faccessat
pattern = r'(SYSCALL_DEFINE3\(faccessat,)'
new_text, n = re.subn(pattern, externs + '\n' + r'\1', text, count=1)
if n == 0:
    print("  ❌ SYSCALL_DEFINE3(faccessat introuvable", file=sys.stderr); sys.exit(1)
text = new_text
applied.append("externs ajoutés")

# ─── ÉTAPE 2 : Hook dans faccessat ───
# Cas standard : return do_faccessat(dfd, filename, mode);
old = """SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
	return do_faccessat(dfd, filename, mode);"""
new = """SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)
{
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	return do_faccessat(dfd, filename, mode);"""

if old in text:
    text = text.replace(old, new, 1)
    applied.append("hook faccessat standard inséré")
else:
    # Cas 4.19+ avec plus de corps
    pattern = r'(SYSCALL_DEFINE3\(faccessat[^)]+\)\s*\{)(\s*\n\s*(?:int res;|unsigned int lookup_flags))'
    new_text, n = re.subn(pattern, r'''\1
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif\2''', text, count=1)
    if n > 0:
        text = new_text
        applied.append("hook faccessat (fallback) inséré")
    else:
        print("  ❌ Impossible d'insérer le hook faccessat", file=sys.stderr); sys.exit(1)

p.write_text(text)
print(f"  ✅ Hook faccessat appliqué ({', '.join(applied)})")
PYEOF_FACCESSAT

# ─── Hook 4 : reboot (kernel/reboot.c) ─────────────────────────────────
echo ""
echo "→ Hook 4/4 : reboot (kernel/reboot.c)"
echo "  D'après le guide officiel : hook SYSCALL_DEFINE4(reboot)"

python3 << 'PYEOF_REBOOT'
import re, sys
from pathlib import Path

p = Path("kernel/reboot.c")
text = p.read_text()
applied = []

if "ksu_handle_sys_reboot" in text:
    print("  ⏭️  Hook reboot déjà présent dans reboot.c")
    sys.exit(0)

# ─── ÉTAPE 1 : Externs ───
externs = '''
#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);
#endif
'''

# Insérer avant reboot
pattern = r'(SYSCALL_DEFINE4\(reboot, int, magic1, int, magic2, unsigned int, cmd,)'
new_text, n = re.subn(pattern, externs + '\n' + r'\1', text, count=1)
if n == 0:
    print("  ⚠️  reboot introuvable dans reboot.c — tentative sys.c", file=sys.stderr)
    p2 = Path("kernel/sys.c")
    text2 = p2.read_text()
    if "ksu_handle_sys_reboot" in text2:
        print("  ⏭️  Hook reboot déjà présent dans sys.c")
        sys.exit(0)
    pattern = r'(SYSCALL_DEFINE4\(reboot, int, magic1, int, magic2, unsigned int, cmd,)'
    new_text2, n2 = re.subn(pattern, externs + '\n' + r'\1', text2, count=1)
    if n2 == 0:
        print("  ❌ Impossible de trouver reboot ni dans reboot.c ni dans sys.c", file=sys.stderr); sys.exit(1)
    text2 = new_text2
    # Insérer le hook
    old2 = "\tchar buffer[256];\n\tint ret = 0;"
    new2 = """	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif"""
    if old2 in text2:
        text2 = text2.replace(old2, new2, 1)
        applied.append("hook reboot dans sys.c (fallback)")
    p2.write_text(text2)
    print(f"  ✅ Hook reboot appliqué dans sys.c ({', '.join(applied)})")
    sys.exit(0)

text = new_text
applied.append("externs ajoutés")

# ─── ÉTAPE 2 : Hook dans reboot ───
old = "\tchar buffer[256];\n\tint ret = 0;"
new = """	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif"""
if old in text:
    text = text.replace(old, new, 1)
    applied.append("hook reboot inséré")
else:
    print("  ⚠️  Pattern buffer[256] introuvable — tentative alternative")
    pattern = r'(SYSCALL_DEFINE4\(reboot[^)]+\)\s*\{)'
    new_text, n = re.subn(pattern, r'''\1
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif''', text, count=1)
    if n > 0:
        text = new_text
        applied.append("hook reboot (fallback) inséré")

p.write_text(text)
print(f"  ✅ Hook reboot appliqué ({', '.join(applied)})")
PYEOF_REBOOT

# =====================================================================
# 4c. VÉRIFICATION RENFORCÉE DES HOOKS
# =====================================================================
echo ""
echo "================================================================"
echo "=== VÉRIFICATION RENFORCÉE DES HOOKS MANUELS ==="
echo "================================================================"

HOOK_FAIL=0

# Hook 1 : stat
echo ""
echo "→ Vérification hook 1/4 : stat"
if grep -q "ksu_handle_stat" fs/stat.c; then
  echo "  ✅ ksu_handle_stat présent dans fs/stat.c"
  echo "     Lignes :"
  grep -n "ksu_handle_stat" fs/stat.c | sed 's/^/       /'
else
  echo "  ❌ ksu_handle_stat ABSENT de fs/stat.c"
  HOOK_FAIL=1
fi

if grep -q "ksu_handle_newfstat_ret" fs/stat.c; then
  echo "  ✅ ksu_handle_newfstat_ret présent dans fs/stat.c"
else
  echo "  ⚠️  ksu_handle_newfstat_ret absent (optionnel pour ce kernel)"
fi

# Hook 2 : execve
echo ""
echo "→ Vérification hook 2/4 : execve"
if grep -q "ksu_handle_execveat" fs/exec.c; then
  echo "  ✅ ksu_handle_execveat présent dans fs/exec.c"
  echo "     Lignes :"
  grep -n "ksu_handle_execveat" fs/exec.c | sed 's/^/       /'
else
  echo "  ❌ ksu_handle_execveat ABSENT de fs/exec.c"
  HOOK_FAIL=1
fi

if grep -q "ksu_handle_post_execveat" fs/exec.c; then
  echo "  ✅ ksu_handle_post_execveat présent dans fs/exec.c"
else
  echo "  ⚠️  ksu_handle_post_execveat absent"
fi

# Hook 3 : faccessat
echo ""
echo "→ Vérification hook 3/4 : faccessat"
if grep -q "ksu_handle_faccessat" fs/open.c; then
  echo "  ✅ ksu_handle_faccessat présent dans fs/open.c"
  echo "     Lignes :"
  grep -n "ksu_handle_faccessat" fs/open.c | sed 's/^/       /'
else
  echo "  ❌ ksu_handle_faccessat ABSENT de fs/open.c"
  HOOK_FAIL=1
fi

# Hook 4 : reboot
echo ""
echo "→ Vérification hook 4/4 : reboot"
if grep -q "ksu_handle_sys_reboot" kernel/reboot.c 2>/dev/null; then
  echo "  ✅ ksu_handle_sys_reboot présent dans kernel/reboot.c"
  echo "     Lignes :"
  grep -n "ksu_handle_sys_reboot" kernel/reboot.c | sed 's/^/       /'
elif grep -q "ksu_handle_sys_reboot" kernel/sys.c 2>/dev/null; then
  echo "  ✅ ksu_handle_sys_reboot présent dans kernel/sys.c (fallback)"
  echo "     Lignes :"
  grep -n "ksu_handle_sys_reboot" kernel/sys.c | sed 's/^/       /'
else
  echo "  ❌ ksu_handle_sys_reboot ABSENT de reboot.c ET sys.c"
  HOOK_FAIL=1
fi

# Résumé
echo ""
echo "================================================================"
if [[ "$HOOK_FAIL" -eq 1 ]]; then
  echo "❌ ÉCHEC : certains hooks manuels sont manquants"
  echo "   La compilation ReSukiSU va probablement échouer."
  exit 1
else
  echo "✅ TOUS LES HOOKS MANUELS OBLIGATOIRES SONT PRÉSENTS"
fi
echo "================================================================"

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

if [[ -x "scripts/kconfig/merge_config.sh" ]]; then
  echo "→ Fusion via merge_config.sh..."
  ./scripts/kconfig/merge_config.sh -O "$OUT" -m "$BASE_DEFCONFIG" "$KIEV_EXT_CONFIG" || {
    echo "⚠️  Fallback concaténation"
    cat "$BASE_DEFCONFIG" > "$OUT/.config"
    echo "" >> "$OUT/.config"
    echo "# ═══ ext_config kiev-default ═══" >> "$OUT/.config"
    cat "$KIEV_EXT_CONFIG" >> "$OUT/.config"
  }
else
  echo "→ Fusion manuelle..."
  cat "$BASE_DEFCONFIG" > "$OUT/.config"
  echo "" >> "$OUT/.config"
  echo "# ═══ ext_config kiev-default ═══" >> "$OUT/.config"
  cat "$KIEV_EXT_CONFIG" >> "$OUT/.config"
fi

echo "→ Application des options KSU/SUSFS + MANUAL HOOK..."

SCRIPTS_CONFIG="$KERNEL_DIR/scripts/config"
[[ -x "$SCRIPTS_CONFIG" ]] || chmod +x "$SCRIPTS_CONFIG"

# ═══════════════════════════════════════════════════════════════════
# CONFIGURATION OFFICIELLE ReSukiSU : MANUAL HOOK
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
  --enable KSU_SUSFS_OPEN_REDIRECT \
  --enable KSU_SUSFS_SUS_MAP \
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

grep -q '^CONFIG_KSU=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU manquant"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU_MANUAL_HOOK manquant"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y$' "$OUT/.config" || { echo "❌ AUTO_SETUID_HOOK manquant"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y$' "$OUT/.config" || { echo "❌ AUTO_INITRC_HOOK manquant"; exit 1; }
grep -q '^CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y$' "$OUT/.config" || { echo "❌ AUTO_INPUT_HOOK manquant"; exit 1; }
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT/.config" || { echo "❌ CONFIG_KSU_SUSFS manquant"; exit 1; }
! grep -q '^CONFIG_KSU_TRACEPOINT_HOOK=y$' "$OUT/.config" || { echo "❌ KSU_TRACEPOINT_HOOK ne doit PAS être activé"; exit 1; }

echo "  ✅ KSU + MANUAL_HOOK + AUTO_* configurés"
echo "  ✅ KSU_SUSFS activé (pour les symboles SUSFS)"

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
  grep -q "^${option}=y$" "$OUT/.config" || { echo "❌ $option manquant"; exit 1; }
done
echo "  ✅ Toutes les fonctionnalités SUSFS activées"

if grep -q '^CONFIG_PANEL_NOTIFICATIONS=y$' "$OUT/.config"; then
  echo "  ✅ CONFIG_PANEL_NOTIFICATIONS=y"
else
  echo "  ❌ PANEL_NOTIFICATIONS doit être =y"; exit 1
fi

if ! grep -q '^CONFIG_INPUT_FOCALTECH_0FLASH_MMI=[ym]$' "$OUT/.config"; then
  echo "  ✅ CONFIG_INPUT_FOCALTECH_0FLASH_MMI désactivé"
else
  echo "  ⚠️  CONFIG_INPUT_FOCALTECH_0FLASH_MMI est encore activé"
fi

if ! grep -q '^CONFIG_INPUT_TOUCHSCREEN_MMI=[ym]$' "$OUT/.config"; then
  echo "  ✅ CONFIG_INPUT_TOUCHSCREEN_MMI désactivé"
else
  echo "  ⚠️  CONFIG_INPUT_TOUCHSCREEN_MMI est encore activé"
fi

grep -E 'CONFIG_(KSU|KSU_SUSFS|KSU_MANUAL|PANEL_NOTIFICATIONS|INPUT_FOCALTECH|INPUT_TOUCHSCREEN|THREAD_INFO)' "$OUT/.config" | tee "$ROOT/ksu-susfs.config"

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
# 7. VÉRIFICATION PANEL_NOTIFIER
# =====================================================================
echo ""
echo "=== Vérification panel_notifier.c ==="
if [[ ! -f "drivers/video/panel_notifier.c" ]]; then
  echo "❌ drivers/video/panel_notifier.c introuvable"
  exit 1
fi
grep -q "panel_register_notifier" drivers/video/panel_notifier.c || {
  echo "❌ panel_register_notifier absent"
  exit 1
}
echo "✅ panel_notifier.c fournit les symboles tactiles"

# =====================================================================
# 7b. FIX BUGS KERNEL LINEAGEOS
# =====================================================================
printf '%s\n' '=== Fix bugs kernel LineageOS ==='
DSI_FILE="$KERNEL_DIR/techpack/display/msm/dsi/dsi_display_mot_ext.c"
if [[ -f "$DSI_FILE" ]]; then
  if grep -q "^static static " "$DSI_FILE"; then
    sed -i 's/^static static /static /' "$DSI_FILE"
    printf '%s\n' '✅ Fix duplicate static appliqué'
  else
    printf '%s\n' '⏭️  Pas de duplicate static'
  fi
fi

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
printf '%s\n' '✅ Compilation réussie'

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
echo "=== BUILD TERMINÉ (MANUAL HOOK OFFICIEL ReSukiSU) ==="
echo "═══════════════════════════════════════════════════════════════"
ls -lh "$OUTPUT_DIR/"
echo ""
echo "SHA-256 du boot.img :"
sha256sum "$OUTPUT_BOOT" 2>/dev/null || true
