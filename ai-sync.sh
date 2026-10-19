#!/usr/bin/env bash
# ai-conf-sync — jednokierunkowa synchronizacja konfiguracji z repo:
#   <repo>/.claude/               -> ~/.claude/   (z wyjątkiem ~/.claude/settings.json)
#   <repo>/managed-settings.json  -> /etc/claude-code/managed-settings.json (root/sudo)
#   <repo>/managed-mcp.json       -> /etc/claude-code/managed-mcp.json      (root/sudo)
#
# Użycie: ai-conf-sync [-n|--dry-run] [--prune] [-f|--force] [-q|--quiet] [-r|--ref REF]
#
#   -n, --dry-run   tylko pokaż, co by się zmieniło
#   --prune         usuń lokalnie pliki, które wcześniej zsynchronizowano, a zniknęły z repo
#                   (dotyczy ~/.claude; pliki managed nigdy nie są usuwane)
#   -f, --force     (zachowane dla zgodności) każdy bieg i tak porównuje pliki z repo
#   -q, --quiet     wypisuj tylko błędy
#   -r, --ref REF   gałąź/tag/commit (domyślnie master)
#
# Zmienne środowiskowe (nadpisują domyślne):
#   AI_CONF_REPO              URL repo (dla prywatnego: git@github.com:barozek90/ai-conf.git)
#   AI_CONF_REF               gałąź (master)
#   AI_CONF_SUBDIR            katalog w repo (.claude)
#   AI_CONF_DEST              katalog docelowy (~/.claude)
#   AI_CONF_CACHE             gdzie trzymać klon, backupy i manifest (~/.cache/ai-conf-sync)
#   AI_CONF_MANAGED_SRC       plik z polityką w repo (managed-settings.json)
#   AI_CONF_MANAGED_DEST      cel polityki (/etc/claude-code/managed-settings.json)
#   AI_CONF_MANAGED_MCP_SRC   plik z serwerami MCP w repo (managed-mcp.json)
#   AI_CONF_MANAGED_MCP_DEST  cel serwerów MCP (/etc/claude-code/managed-mcp.json)

set -euo pipefail

REPO="${AI_CONF_REPO:-https://github.com/barozek90/ai-conf.git}"
REF="${AI_CONF_REF:-master}"
SUBDIR="${AI_CONF_SUBDIR:-.claude}"
DEST="${AI_CONF_DEST:-$HOME/.claude}"
CACHE="${AI_CONF_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/ai-conf-sync}"
MANAGED_SRC="${AI_CONF_MANAGED_SRC:-managed-settings.json}"
MANAGED_DEST="${AI_CONF_MANAGED_DEST:-/etc/claude-code/managed-settings.json}"
MANAGED_MCP_SRC="${AI_CONF_MANAGED_MCP_SRC:-managed-mcp.json}"
MANAGED_MCP_DEST="${AI_CONF_MANAGED_MCP_DEST:-/etc/claude-code/managed-mcp.json}"

CLONE="$CACHE/repo"
BACKUP_ROOT="$CACHE/backup"
MANIFEST="$CACHE/manifest"
STATE="$CACHE/last-commit"

# Pliki, których nigdy nie nadpisujemy, nawet jeśli ktoś wrzuci je do repo
# (dopasowanie po nazwie pliku, w dowolnym podkatalogu).
EXCLUDE=( ".credentials.json" "settings.local.json" "history.jsonl" )

# Ścieżki względne (od katalogu docelowego), których nie ruszamy:
# dokładne dopasowanie, więc dotyczy tylko ~/.claude/settings.json,
# a nie settings.json w podkatalogach.
EXCLUDE_ROOT=( "settings.json" )

DRY_RUN=0 PRUNE=0 FORCE=0 QUIET=0
USE_SUDO=0
mgr_status="" mgr_failed=0

log()  { (( QUIET )) || printf '%s\n' "$*"; }
warn() { printf 'ai-conf-sync: UWAGA: %s\n' "$*" >&2; }
die()  { printf 'ai-conf-sync: BŁĄD: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "brak polecenia: $1"; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    --prune)      PRUNE=1 ;;
    -f|--force)   FORCE=1 ;;
    -q|--quiet)   QUIET=1 ;;
    -r|--ref)     [[ $# -ge 2 ]] || die "brak wartości dla $1"; REF="$2"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "nieznana opcja: $1 (zobacz --help)" ;;
  esac
  shift
done

need git
need cmp
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1

is_excluded() {
  local rel="$1" pat
  for pat in "${EXCLUDE[@]}"; do
    [[ "$rel" == "$pat" || "$rel" == */"$pat" ]] && return 0
  done
  return 1
}

is_protected_root() {
  local rel="$1" pat
  for pat in "${EXCLUDE_ROOT[@]}"; do
    [[ "$rel" == "$pat" ]] && return 0
  done
  return 1
}

# ------------------------------------------------- pomocnicze: pliki managed
nearest_existing() {             # najbliższy istniejący element ścieżki
  local p="$1"
  while [[ ! -e "$p" ]]; do p="$(dirname "$p")"; done
  printf '%s' "$p"
}

priv() { if (( USE_SUDO )); then sudo "$@"; else "$@"; fi; }

# sync_managed <ścieżka w repo> <cel>
# Zwraca 0 gdy OK (lub nic do zrobienia), 1 przy błędzie. Ustawia file_status.
sync_managed() {
  local rel="$1" dst="$2"
  local src="$CLONE/$rel"
  local dir tmp existed=0 owner=()
  dir="$(dirname "$dst")"
  tmp="$dst.ai-conf.tmp"

  if [[ ! -e "$src" && ! -L "$src" ]]; then
    file_status="brak w repo"
    return 0
  fi
  # symlink w repo mógłby wskazywać na dowolny plik (a kopiujemy jako root)
  if [[ -L "$src" || ! -f "$src" ]]; then
    warn "pomijam $rel: to nie jest zwykły plik (symlink?)"
    return 1
  fi

  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    file_status="bez zmian"
    return 0
  fi

  if (( HAVE_JQ )); then
    jq -e . "$src" >/dev/null 2>&1 \
      || { warn "pomijam $rel: niepoprawny JSON w repo"; return 1; }
  else
    warn "brak jq — nie waliduję $rel"
  fi

  [[ -e "$dst" ]] && existed=1
  if (( existed )); then
    log "aktualizuję  $rel -> $dst"; file_status="zaktualizowany"
  else
    log "dodaję       $rel -> $dst"; file_status="dodany"
  fi
  (( DRY_RUN )) && return 0

  if [[ $EUID -ne 0 && ! -w "$(nearest_existing "$dir")" ]]; then
    command -v sudo >/dev/null 2>&1 \
      || { warn "do zapisu $dst potrzebny root, a brak sudo"; return 1; }
    USE_SUDO=1
  fi
  if [[ $EUID -eq 0 || $USE_SUDO -eq 1 ]]; then owner=(-o root -g root); fi

  if (( existed )); then
    mkdir -p "$BACKUP_ROOT/$STAMP/_managed"
    cp -p "$dst" "$BACKUP_ROOT/$STAMP/_managed/$(basename "$dst")" \
      || { warn "nie udało się zrobić backupu $dst"; return 1; }
  fi

  priv mkdir -p -m 0755 "$dir" || return 1
  priv install -m 0644 ${owner[@]+"${owner[@]}"} "$src" "$tmp" || return 1
  priv mv -f "$tmp" "$dst" || { priv rm -f "$tmp"; return 1; }   # podmiana atomowa
  return 0
}

# ---------------------------------------------------------------- 1. repo
mkdir -p "$CACHE"
if [[ -d "$CLONE/.git" ]]; then
  git -C "$CLONE" remote set-url origin "$REPO"
  git -C "$CLONE" fetch -q --depth 1 origin "$REF" \
    || die "nie udało się pobrać $REF z $REPO"
  git -C "$CLONE" reset -q --hard FETCH_HEAD
  git -C "$CLONE" clean -qfdx
else
  git clone -q --depth 1 --branch "$REF" "$REPO" "$CLONE" \
    || die "nie udało się sklonować $REPO ($REF)"
fi

SRC="$CLONE/$SUBDIR"
[[ -d "$SRC" ]] || die "w repo nie ma katalogu '$SUBDIR'"

COMMIT="$(git -C "$CLONE" rev-parse --short HEAD)"
LAST="$(cat "$STATE" 2>/dev/null || true)"

# Nie kończymy wcześniej, gdy commit się nie zmienił: lokalne pliki mogły zostać
# usunięte lub zmienione ręcznie, a porównanie plików (cmp) jest tanie.
if [[ "$COMMIT" == "$LAST" ]]; then
  log "repo bez zmian (commit $COMMIT), sprawdzam spójność plików lokalnych"
fi

# ---------------------------------------------------------------- 2. sync
mkdir -p "$DEST"
STAMP="$(date +%Y%m%d-%H%M%S)"
n_add=0 n_upd=0 n_skip=0 n_del=0
new_manifest=()

backup() {                       # backup "<ścieżka względna>"
  local rel="$1" dst="$DEST/$1"
  mkdir -p "$BACKUP_ROOT/$STAMP/$(dirname "$rel")"
  cp -p "$dst" "$BACKUP_ROOT/$STAMP/$rel"
}

while IFS= read -r -d '' src; do
  rel="${src#"$SRC"/}"
  dst="$DEST/$rel"

  if is_excluded "$rel"; then
    warn "pomijam $rel (na liście wykluczeń)"
    continue
  fi
  if is_protected_root "$rel"; then
    log "pomijam $rel (chroniony, nie ruszam lokalnego pliku)"
    continue
  fi
  new_manifest+=("$rel")

  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    n_skip=$((n_skip + 1))
    continue
  fi

  if [[ -L "$dst" ]]; then
    warn "pomijam $rel: lokalnie jest symlinkiem"
    continue
  fi

  if [[ "$rel" == *.json && $HAVE_JQ -eq 1 ]] && ! jq -e . "$src" >/dev/null 2>&1; then
    warn "pomijam $rel: niepoprawny JSON w repo"
    continue
  fi

  if [[ -e "$dst" ]]; then
    log "aktualizuję  $rel"; n_upd=$((n_upd + 1))
  else
    log "dodaję       $rel"; n_add=$((n_add + 1))
  fi
  (( DRY_RUN )) && continue

  [[ -e "$dst" ]] && backup "$rel"
  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst.ai-conf.tmp"           # cp -p zachowuje bit +x z gita
  mv -f "$dst.ai-conf.tmp" "$dst"           # podmiana atomowa
  [[ "$rel" == hooks/* && "$rel" == *.sh ]] && chmod +x "$dst"
done < <(find "$SRC" -type f -not -path '*/.git/*' -print0 | sort -z)

# ---------------------------------------------------------------- 2b. managed
# Błąd jednego pliku nie blokuje drugiego; końcowy kod wyjścia to 1 przy dowolnym błędzie.
file_status=""
if sync_managed "$MANAGED_SRC" "$MANAGED_DEST"; then
  mgr_status="settings: $file_status"
else
  mgr_failed=1; mgr_status="settings: błąd"
fi
if sync_managed "$MANAGED_MCP_SRC" "$MANAGED_MCP_DEST"; then
  mgr_status+=", mcp: $file_status"
else
  mgr_failed=1; mgr_status+=", mcp: błąd"
fi

# ---------------------------------------------------------------- 3. prune
if (( PRUNE )) && [[ -f "$MANIFEST" ]]; then
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    # starszy manifest mógł zawierać pliki, które teraz są chronione
    is_excluded "$rel" && continue
    is_protected_root "$rel" && continue
    found=0
    for m in ${new_manifest[@]+"${new_manifest[@]}"}; do
      [[ "$m" == "$rel" ]] && { found=1; break; }
    done
    (( found )) && continue
    dst="$DEST/$rel"
    [[ -f "$dst" ]] || continue
    log "usuwam       $rel (nie ma już w repo)"; n_del=$((n_del + 1))
    (( DRY_RUN )) && continue
    backup "$rel"
    rm -f -- "$dst"
  done < "$MANIFEST"
fi

# ---------------------------------------------------------------- 4. stan
if (( ! DRY_RUN )); then
  printf '%s\n' ${new_manifest[@]+"${new_manifest[@]}"} > "$MANIFEST"
  printf '%s\n' "$COMMIT" > "$STATE"
  # trzymaj tylko 10 ostatnich backupów
  # (|| true: gdy nie ma jeszcze żadnego backupu, ls kończy się błędem, a pipefail ubiłby skrypt)
  ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +11 | xargs -r rm -rf || true
fi

log "gotowe: commit $COMMIT | dodane $n_add, zaktualizowane $n_upd, bez zmian $n_skip, usunięte $n_del | managed: ${mgr_status:-?}$( (( DRY_RUN )) && printf ' [dry-run]')"

if (( mgr_failed )); then
  exit 1
fi
