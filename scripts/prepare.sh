#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-$PWD}"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
BUNDLE_DIR="${BUNDLE_DIR:-$ROOT}"

# ─── Versions figées ────────────────────────────────────────────────────
RESUKISU_URL="https://github.com/ReSukiSU/ReSukiSU.git"
RESUKISU_COMMIT="90b4a4c70f70c835b01c2be6deac58ee3c0cb4c2"

# ─── Sources SUSFS JackA1ltman (NonGKI_Kernel_Build_2nd) ────────────────
JACKA1LTMAN_RAW="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/main"
SUSFS_PATCH_URL="$JACKA1LTMAN_RAW/Patches/Patch/susfs_patch_to_4.19.patch"
INLINE_HOOK_URL="$JACKA1LTMAN_RAW/Patches/susfs_inline_hook_patches.sh"

# ─── Nettoyage du kernel source ─────────────────────────────────────────
cd "$KERNEL_DIR"
git clean -fdx

# =====================================================================
# 1. CLONE ReSukiSU à la révision figée
# =====================================================================
if [[ ! -d "$ROOT/ReSukiSU/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$RESUKISU_URL" "$ROOT/ReSukiSU"
fi
git -C "$ROOT/ReSukiSU" fetch --depth=1 origin "$RESUKISU_COMMIT"
git -C "$ROOT/ReSukiSU" checkout --detach "$RESUKISU_COMMIT"

# Intégration ReSukiSU dans le kernel source
cp -a "$ROOT/ReSukiSU" "$KERNEL_DIR/KernelSU"
ln -s ../KernelSU/kernel "$KERNEL_DIR/drivers/kernelsu"

# =====================================================================
# 2. INTÉGRATION SUSFS JackA1ltman (remplace l'ancienne méthode manuelle)
# =====================================================================
echo "=== Intégration SUSFS 4.19 JackA1ltman ==="

# 2.1 Télécharger le patch SUSFS 4.19
echo "→ Téléchargement du patch SUSFS 4.19..."
wget -q -O /tmp/susfs_patch_to_4.19.patch "$SUSFS_PATCH_URL" || {
    echo "❌ Impossible de télécharger le patch SUSFS"
    exit 1
}

# 2.2 Appliquer le patch SUSFS
echo "→ Application du patch SUSFS..."
if ! patch -p1 --forward --batch < /tmp/susfs_patch_to_4.19.patch; then
    echo "⚠️  Rejets détectés dans le patch SUSFS"
    echo "→ Fichiers .rej :"
    find . -name '*.rej' -print
    echo ""
    echo "⚠️  Ces rejets doivent être résolus manuellement."
    echo "⚠️  Consulte les .rej un par un et applique les hunks à la main."
    echo "⚠️  Puis relance le workflow."
    exit 1
fi

# 2.3 Télécharger et exécuter le script SUSFS Inline Hook
echo "→ Activation des hooks SUSFS Inline..."
wget -q -O /tmp/susfs_inline_hook_patches.sh "$INLINE_HOOK_URL" || {
    echo "❌ Impossible de télécharger le script de hooks inline"
    exit 1
}

cd "$KERNEL_DIR"
bash /tmp/susfs_inline_hook_patches.sh || {
    echo "❌ Échec de l'application des hooks inline"
    exit 1
}

# =====================================================================
# 3. VÉRIFICATIONS D'INTÉGRATION
# =====================================================================
echo "=== Vérifications d'intégration ==="

# Vérifier les points d'ancrage ReSukiSU
grep -q 'source "drivers/kernelsu/Kconfig"' "$KERNEL_DIR/drivers/Kconfig" || {
    echo "❌ ReSukiSU Kconfig non intégré"
    exit 1
}
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || {
    echo "❌ ReSukiSU Makefile non intégré"
    exit 1
}

# Vérifier les fichiers SUSFS
for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
    [[ -f "$KERNEL_DIR/$f" ]] || {
        echo "❌ Fichier SUSFS manquant : $f"
        exit 1
    }
done

# Vérifier le hook input (utilisé par KSU pour le keyevent hook)
if ! grep -q 'ksu_handle_input_handle_event' "$KERNEL_DIR/drivers/input/input.c"; then
    echo "⚠️  Hook input manquant dans drivers/input/input.c"
    echo "⚠️  Cela peut causer des problèmes au boot."
    echo "⚠️  Vérifie manuellement que le script inline hook l'a bien appliqué."
    exit 1
fi

# Vérifier que les rejets ont été nettoyés
[[ -z "$(find "$KERNEL_DIR" -name '*.rej' -print -quit)" ]] || {
    echo "❌ Des fichiers .rej persistent"
    exit 1
}

# =====================================================================
# 4. RÉCAPITULATIF
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "=== PRÉPARATION TERMINÉE ==="
echo "═══════════════════════════════════════════════════════════════"
echo "Kernel source commit  : $(git -C "$KERNEL_DIR" rev-parse HEAD)"
echo "ReSukiSU commit       : $(git -C "$ROOT/ReSukiSU" rev-parse HEAD)"
echo "SUSFS patch appliqué  : susfs_patch_to_4.19.patch"
echo "SUSFS Inline Hooks    : susfs_inline_hook_patches.sh"
echo "═══════════════════════════════════════════════════════════════"
