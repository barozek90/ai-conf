#!/usr/bin/env bash
# bwrap-userns-fix — pozwala sandboxowi Claude Code (bubblewrap + apply-seccomp) działać
# na Ubuntu z włączonym kernel.apparmor_restrict_unprivileged_userns=1.
#
# Objaw: każde polecenie Bash kończy się błędem
#   apply-seccomp: write /proc/self/setgroups (nested userns is capability-restricted; ...)
# a w dmesg widać: apparmor="DENIED" operation="capable" profile="unpriv_bwrap" capname="sys_admin".
#
# Warianty (wykrywane automatycznie):
#   * Ubuntu 26.04 (jest /etc/apparmor.d/bwrap-userns-restrict):
#       dopisuje /etc/apparmor.d/local/unpriv_bwrap z regułą o wyższym priorytecie,
#       która przywraca capabilities procesom potomnym bwrap.
#       Wymaga AppArmor >= 4.1 (rule priority). Gdy test się nie powiedzie, zmiana jest cofana.
#   * Ubuntu 24.04 (brak aktywnego profilu bwrap, AppArmor 4.0):
#       instaluje /etc/apparmor.d/bwrap zgodnie z dokumentacją Claude Code
#       (flags=(unconfined) + userns).
#
# UWAGA (bezpieczeństwo): oba warianty znoszą ograniczenie, które Ubuntu celowo nakłada na
# procesy potomne /usr/bin/bwrap. Dotyczy to wszystkich użytkowników bwrap na tej maszynie.
#
# Użycie: sudo bwrap-userns-fix.sh [--revert] [--force]
#   --revert   usuń pliki dodane przez ten skrypt i przeładuj AppArmor
#   --force    zainstaluj poprawkę nawet jeśli test wykaże, że sandbox już działa
#
# Skrypt NIE był uruchamiany na docelowych maszynach przy tworzeniu — najpierw użyj na jednej.

set -euo pipefail

MARK="# managed-by: ai-conf bwrap-userns-fix"
SHIPPED="/etc/apparmor.d/bwrap-userns-restrict"
LOCAL_OVERRIDE="/etc/apparmor.d/local/unpriv_bwrap"
OWN_PROFILE="/etc/apparmor.d/bwrap"

REVERT=0 FORCE=0
for a in "$@"; do
  case "$a" in
    --revert) REVERT=1 ;;
    --force)  FORCE=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'nieznana opcja: %s\n' "$a" >&2; exit 2 ;;
  esac
done

die()  { printf 'bwrap-userns-fix: BŁĄD: %s\n' "$*" >&2; exit 1; }
info() { printf 'bwrap-userns-fix: %s\n' "$*"; }

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
command -v apparmor_parser >/dev/null 2>&1 || die "brak apparmor_parser"
command -v bwrap >/dev/null 2>&1 || die "brak bwrap (apt install bubblewrap)"

TEST_USER="${SUDO_USER:-}"
[[ -n "$TEST_USER" && "$TEST_USER" != root ]] || TEST_USER=""

# Test jako zwykły użytkownik (root omija ograniczenia). --uid 0 daje pełne capabilities
# w namespace, a `unshare -m` wymaga CAP_SYS_ADMIN — dokładnie to, co blokuje unpriv_bwrap.
sandbox_ok() {
  [[ -n "$TEST_USER" ]] || return 2
  runuser -u "$TEST_USER" -- bwrap --unshare-user --uid 0 --ro-bind / / unshare -m true >/dev/null 2>&1
}

reload_shipped() { apparmor_parser -r "$SHIPPED"; }

if (( REVERT )); then
  if [[ -f "$LOCAL_OVERRIDE" ]] && grep -qF "$MARK" "$LOCAL_OVERRIDE"; then
    rm -f "$LOCAL_OVERRIDE"; info "usunięto $LOCAL_OVERRIDE"
    [[ -f "$SHIPPED" ]] && reload_shipped
  fi
  if [[ -f "$OWN_PROFILE" ]] && grep -qF "$MARK" "$OWN_PROFILE"; then
    apparmor_parser -R "$OWN_PROFILE" 2>/dev/null || true
    rm -f "$OWN_PROFILE"; info "usunięto $OWN_PROFILE"
  fi
  info "cofnięto"
  exit 0
fi

RESTRICT="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
if [[ "$RESTRICT" != 1 ]]; then
  info "kernel.apparmor_restrict_unprivileged_userns=$RESTRICT — poprawka niepotrzebna"
  exit 0
fi

# shellcheck disable=SC1091
info "system: $(. /etc/os-release; echo "${PRETTY_NAME:-?}"), $(apparmor_parser --version | head -1)"

if (( ! FORCE )) && sandbox_ok; then
  info "test przechodzi bez zmian — nic do zrobienia (--force wymusza instalację)"
  exit 0
fi

if [[ -f "$SHIPPED" ]]; then
  # --- wariant 26.04: nadpisanie reguły `audit deny capability` w unpriv_bwrap ---
  install -d -m 0755 /etc/apparmor.d/local
  [[ -f "$LOCAL_OVERRIDE" ]] && ! grep -qF "$MARK" "$LOCAL_OVERRIDE" \
    && die "$LOCAL_OVERRIDE istnieje i nie pochodzi z tego skryptu — nie nadpisuję"
  cat > "$LOCAL_OVERRIDE" <<EOF
$MARK
# unpriv_bwrap zawiera 'audit deny capability' (priorytet 0); wyższy priorytet przywraca
# capabilities, których apply-seccomp (sandbox Claude Code) potrzebuje w namespace.
priority=1 allow capability,
EOF
  if ! reload_shipped; then
    rm -f "$LOCAL_OVERRIDE"; reload_shipped || true
    die "parser odrzucił regułę priority (AppArmor < 4.1?) — cofnięto"
  fi
else
  # --- wariant 24.04: profil z dokumentacji Claude Code ---
  [[ -f "$OWN_PROFILE" ]] && ! grep -qF "$MARK" "$OWN_PROFILE" \
    && die "$OWN_PROFILE istnieje i nie pochodzi z tego skryptu — nie nadpisuję"
  cat > "$OWN_PROFILE" <<EOF
$MARK
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOF
  if ! apparmor_parser -r "$OWN_PROFILE"; then
    rm -f "$OWN_PROFILE"; die "parser odrzucił profil — cofnięto"
  fi
fi

if sandbox_ok; then
  info "OK: test sandboxa przechodzi. Uruchom nową sesję Claude Code."
else
  rc=$?
  if (( rc == 2 )); then
    info "załadowano; brak SUDO_USER — nie wykonano testu. Sprawdź ręcznie."
  else
    info "test nadal nie przechodzi — cofam zmiany"
    "$0" --revert
    die "poprawka nie zadziałała na tym systemie (zobacz: sudo dmesg | grep 'apparmor=\"DENIED\"')"
  fi
fi
