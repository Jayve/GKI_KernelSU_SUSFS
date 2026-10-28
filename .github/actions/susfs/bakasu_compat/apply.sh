#!/usr/bin/env bash
# BakaSU kernel-side SUSFS compat layer
#
# The susfs4ksu 50_add_susfs_in_gki patch extern-declares five kernel symbols:
#   my_write_context, my_write_access, my_setprocattr       (selinux hooks)
#   ksu_setup_preinit_file, ksu_preinit_handle_post_execveat (fs/exec.c)
#
# What BakaSU itself provides changed between checkouts:
#   * dac2d186 era: my_write_context/my_write_access are static in
#     selinux_hide.c, my_setprocattr does not exist and there is no preinit/;
#   * current BakaSU (d5e9e025+): selinux_hide.c exports the three SELinux
#     hooks through __maybe_static as soon as susfs_compat.mk sees the patched
#     hooks.c (KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE), and
#     preinit/preinit.c defines both preinit hooks under CONFIG_KSU_SUSFS.
#
# A plain global stub therefore collides with BakaSU's own definitions on new
# checkouts ("duplicate symbol" from the LTO link), while dropping the stubs
# entirely breaks old ones. Every stub is emitted as __weak instead: the
# linker always prefers BakaSU's strong definition, and the stub is only used
# when the checkout keeps the symbol static or does not have it at all.
# Kbuild links built-in.a with --whole-archive, so the choice is resolved
# deterministically on every supported kernel version.
#
# We drop bakasu_susfs_compat.c directly into kernel/BakaSU/kernel/ (the
# directory symlinked into common/drivers/kernelsu/) and add it to the Kbuild
# so it's compiled and linked into vmlinux.
#
# The stubs are inert (return -EINVAL/0) so a checkout without its own SUSFS
# glue keeps the stock behavior instead of failing to link.

set -eo pipefail

KSU_DIR="${1:-BakaSU}"
KERNEL_ROOT="${KERNEL_ROOT:-$PWD}"

BAKASU_KSU="$KERNEL_ROOT/$KSU_DIR/kernel"
BAKASU_KBUILD="$BAKASU_KSU/Kbuild"

[ -f "$BAKASU_KSU/feature/selinux_hide.c" ] || {
  echo "::error::BakaSU selinux_hide.c not found at $BAKASU_KSU/feature/selinux_hide.c" >&2
  exit 1
}
[ -f "$BAKASU_KBUILD" ] || {
  echo "::error::BakaSU Kbuild not found at $BAKASU_KBUILD" >&2
  exit 1
}

# compat.c: weak fallbacks for the symbols the SUSFS patch expects
cat > "$BAKASU_KSU/bakasu_susfs_compat.c" <<'COMPAT'
/* BakaSU SUSFS compat: weak fallbacks for SUSFS patch extern references.
 *
 * BakaSU defines some or all of these itself depending on the checkout:
 *   - selinux_hide.c exports my_write_context/my_write_access/
 *     my_setprocattr through __maybe_static once susfs_compat.mk sees the
 *     SUSFS patch in security/selinux/hooks.c;
 *   - preinit/preinit.c defines ksu_setup_preinit_file and
 *     ksu_preinit_handle_post_execveat under CONFIG_KSU_SUSFS.
 *
 * Everything below is __weak on purpose: a strong BakaSU definition always
 * wins and the stub only fills in for checkouts that keep the symbol static
 * or do not have it. That keeps both layouts linkable without guessing the
 * BakaSU revision at patch time.
 */

#include <linux/compiler.h>
#include <linux/fs.h>

struct filename;
struct user_arg_ptr;

/* ------------------------------------------------------------------ */
/* my_write_context / my_write_access                                 */
/*   Referenced by the selinuxfs.c write_op[] wrappers added by the    */
/*   SUSFS 50_add_susfs patch. A missing implementation keeps the      */
/*   stock (rejected) write behavior.                                  */
/* ------------------------------------------------------------------ */

__weak ssize_t my_write_context(struct file *file, char *buf, size_t size)
{
    return -EINVAL;
}

__weak ssize_t my_write_access(struct file *file, char *buf, size_t size)
{
    return -EINVAL;
}

/* ------------------------------------------------------------------ */
/* my_setprocattr                                                     */
/*   Referenced by the hooks.c handle_selinux_setprocattr() wrapper   */
/*   added by the SUSFS 50_add_susfs patch. Return 0 (allow).         */
/* ------------------------------------------------------------------ */

__weak int my_setprocattr(const char *name, void *value, size_t size)
{
    return 0;
}

/* ------------------------------------------------------------------ */
/* Preinit support                                                    */
/*   Referenced by fs/exec.c (SUSFS patch). -EINVAL leaves the exec    */
/*   path untouched when BakaSU has no preinit implementation.         */
/* ------------------------------------------------------------------ */

__weak int ksu_setup_preinit_file(struct filename **filename_ptr,
                                  struct user_arg_ptr *argv_user)
{
    return -EINVAL;
}

__weak int ksu_preinit_handle_post_execveat(int *fd,
                                            struct filename **filename_ptr,
                                            void *argv_user, void *envp_user,
                                            int *flags, int *retval,
                                            int *preinit_fd)
{
    return 0;
}
COMPAT

# Register compat object in Kbuild
if ! grep -q 'bakasu_susfs_compat.o' "$BAKASU_KBUILD"; then
  cat >> "$BAKASU_KBUILD" <<'KBUILD'

# BakaSU SUSFS compat object
obj-y += bakasu_susfs_compat.o
KBUILD
  echo "BakaSU compat: added obj-y to Kbuild"
fi

echo "BakaSU SUSFS compat layer applied (bakasu_susfs_compat.c + Kbuild)"
