#!/usr/bin/env bash
# Trwale pozwala na zagnieżdżone userns pod bwrap (sandbox Claude Code) na Ubuntu 26.04.
# Wyłącza stockowy profil AppArmor "bwrap-userns-restrict" (podprofil unpriv_bwrap
# odbiera CAP_SYS_ADMIN) i zastępuje go profilem bez ograniczeń dla /usr/bin/bwrap.
#
# Użycie:
#   ./fix-bwrap-apparmor.sh            # zastosuj (idempotentne)
#   ./fix-bwrap-apparmor.sh --revert   # przywróć stockowy profil Ubuntu

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

STOCK=/etc/apparmor.d/bwrap-userns-restrict
CUSTOM=/etc/apparmor.d/bwrap-unconfined
DISABLE_DIR=/etc/apparmor.d/disable
DISABLE_LINK="$DISABLE_DIR/bwrap-userns-restrict"
TEST_USER="${SUDO_USER:-root}"

test_nested() {
  sudo -u "$TEST_USER" bwrap --unshare-user --unshare-pid --ro-bind / / \
    --dev /dev --proc /proc \
    unshare --user --pid --fork --mount-proc true
}

if [ "${1:-}" = "--revert" ]; then
  echo ">> Cofanie zmian"
  apparmor_parser -R "$CUSTOM" 2>/dev/null || true
  rm -f "$CUSTOM"
  rm -f "$DISABLE_LINK"
  if [ -f "$STOCK" ]; then
    apparmor_parser -r "$STOCK"
  fi
  echo ">> Gotowe: przywrócono stockowy profil bwrap-userns-restrict."
  exit 0
fi

if [ ! -f "$STOCK" ]; then
  echo "UWAGA: brak $STOCK, pomijam jego wyłączanie." >&2
fi

echo ">> Wyłączam stockowy profil (symlink w $DISABLE_DIR, przeżywa aktualizacje i restart)"
mkdir -p "$DISABLE_DIR"
if [ -f "$STOCK" ] && [ ! -e "$DISABLE_LINK" ]; then
  ln -s "$STOCK" "$DISABLE_LINK"
fi
if [ -f "$STOCK" ]; then
  apparmor_parser -R "$STOCK" 2>/dev/null || true
fi

echo ">> Zapisuję $CUSTOM"
cat > "$CUSTOM" <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap-unconfined /usr/bin/bwrap flags=(unconfined) {
  userns,
}
EOF

echo ">> Ładuję profil"
apparmor_parser -r "$CUSTOM"

echo ">> Test zagnieżdżonego userns (użytkownik: $TEST_USER)"
if test_nested; then
  echo "OK: zagnieżdżony userns działa. Zrestartuj Claude Code."
else
  echo "BŁĄD: nadal Operation not permitted. Sprawdź:" >&2
  echo "  sudo aa-status | grep -i bwrap" >&2
  echo "  sudo journalctl -k --since '2 min ago' | grep -i 'apparmor.*DENIED' | grep -v dbus" >&2
  exit 1
fi
