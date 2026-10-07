#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-$PWD}"
KERNEL_DIR="${KERNEL_DIR:-$ROOT/kernel}"
OUT="${OUT:-$KERNEL_DIR/out}"
JOBS="${JOBS:-$(nproc)}"
LOG="${LOG:-$ROOT/build.log}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

cd "$KERNEL_DIR"
rm -rf "$OUT"

printf '%s\n' '=== Configuration ReSukiSU : mode MANUAL_HOOK + SUSFS JackA1ltman ==='

make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  vendor/lito-perf_defconfig

SCRIPTS_CONFIG="$KERNEL_DIR/scripts/config"
if [[ ! -x "$SCRIPTS_CONFIG" ]]; then
  chmod +x "$SCRIPTS_CONFIG"
fi

# =====================================================================
# CONFIGURATION KSU + SUSFS
# =====================================================================
# ReSukiSU 90b4a4c7 place KSU_TRACEPOINT_HOOK, KSU_MANUAL_HOOK et
# KSU_SUSFS dans un choice exclusif.
#
# ── Ancienne méthode (à l'origine du kernel panic) ──
# Le mode SUSFS Inline Hook (KSU_SUSFS=y) est activé par défaut mais il
# dépend d'une API SUSFS spécifique qui n'était pas alignée avec la
# version backportée. D'où le crash au boot.
#
# ── Nouvelle méthode (JackA1ltman) ──
# On bascule sur CONFIG_KSU_MANUAL_HOOK=y, le mode le plus compatible
# pour les kernels non-GKI (3.4 → 6.18). Le patch SUSFS est appliqué
# par prepare.sh via susfs_patch_to_4.19.patch + les hooks inline.
# =====================================================================

"$SCRIPTS_CONFIG" --file "$OUT/.config" \
  --enable KSU \
  --enable KSU_MULTI_MANAGER_SUPPORT \
  --enable KSU_MANUAL_HOOK \
  --disable KSU_TRACEPOINT_HOOK \
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
# CONTRÔLE STRICT : vérifier que le mode attendu est bien sélectionné
# =====================================================================
grep -q '^CONFIG_KSU=y$' "$OUT/.config"
grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$OUT/.config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$OUT/.config"
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
# 5. PATCH SIGNATURES MODULE
# =====================================================================
sed -i 's/if (!check_version(/if (0 \&\& !check_version(/g' kernel/module.c

# =====================================================================
# 6. PATCH TACTILE
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
# 7. COMPILATION
# =====================================================================
printf '%s\n' '=== Compilation du kernel et des modules ==='
make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
  KCFLAGS=-Wno-error -j"$JOBS" Image.gz modules 2>&1 | tee "$LOG"

test -s "$OUT/arch/arm64/boot/Image.gz"
find "$OUT" -type f -name '*.ko' -print -quit | grep -q .
sha256sum "$OUT/arch/arm64/boot/Image.gz"
printf '%s\n' '✅ Compilation ReSukiSU/SUSFS réussie'
