#!/usr/bin/env bash
# Ortak yardimcilar. Bash 3.2 uyumlu (macOS varsayilani):
#   - associative array YOK, mapfile YOK, ${var,,} YOK, "wait -n" YOK
#   - bos dizi genisletmesi daima ${arr[@]+"${arr[@]}"} kalibiyla

orc_root() {
  # Kisisel mutlak yol gomulmez; her zaman kaynagindan cozulur.
  local src="${BASH_SOURCE[0]}"
  while [ -h "$src" ]; do src="$(readlink "$src")"; done
  cd -- "$(dirname -- "$src")/.." && pwd -P
}

# Testler fixture bir kayit dosyasi verebilsin diye override edilebilir.
workers_file() { printf '%s' "${ORCHESTRA_WORKERS_FILE:-$(orc_root)/workers.json}"; }

log()  { printf '[orchestra] %s\n' "$*" >&2; }
warn() { printf '[orchestra] UYARI: %s\n' "$*" >&2; }
die()  { printf '[orchestra] HATA: %s\n' "$*" >&2; exit 1; }

json_str() { jq -Rn --arg v "$1" '$v'; }

# workers.json'dan alan oku: wcfg <worker> <alan>
wcfg() {
  local worker="$1" field="$2"
  jq -r --arg w "$worker" --arg f "$field" \
    '.workers[$w][$f] | if .==null then "" else . end' "$(workers_file)"
}

rcfg() {
  local route="$1" field="$2"
  jq -r --arg r "$route" --arg f "$field" \
    '.routes[$r][$f] | if .==null then "" else . end' "$(workers_file)"
}

dcfg() {
  local field="$1"
  jq -r --arg f "$field" '.defaults[$f] | if .==null then "" else . end' "$(workers_file)"
}

worker_exists() {
  [ "$(jq -r --arg w "$1" 'has("workers") and (.workers|has($w))' "$(workers_file)")" = "true" ]
}

enabled_workers() {
  jq -r '.workers | to_entries[] | select(.value.enabled) | .key' "$(workers_file)"
}

# Bir worker gercekten cagrilabilir mi? Prose degil, kontrol.
worker_callable() {
  local worker="$1" route engine
  worker_exists "$worker" || { echo "kayitli degil"; return 1; }
  [ "$(wcfg "$worker" enabled)" = "true" ] || { echo "workers.json'da enabled=false"; return 1; }
  route="$(wcfg "$worker" route)"; [ -n "$route" ] || route="$(dcfg route)"
  engine="$(rcfg "$route" engine)"
  [ -n "$engine" ] || { echo "route '$route' tanimsiz"; return 1; }
  command -v "$engine" >/dev/null 2>&1 || { echo "$engine PATH'te yok"; return 1; }

  case "$route" in
    native)
      # codex kendi ChatGPT girisini kullanir; harici anahtar yok.
      [ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ] \
        || { echo "codex girisi yok (codex login)"; return 1; }
      echo "ok"; return 0 ;;
    agy)
      # agy kendi auth'unu tasir; harici anahtar yok.
      [ -d "$HOME/.antigravity" ] \
        || { echo "agy yapilandirilmamis (~/.antigravity yok)"; return 1; }
      echo "ok"; return 0 ;;
    cursor)
      # Cursor Agent (binary adi: agent) kendi girisini tasir; harici anahtar yok.
      [ -d "$HOME/.cursor" ] \
        || { echo "cursor yapilandirilmamis (~/.cursor yok)"; return 1; }
      echo "ok"; return 0 ;;
    *)
      echo "desteklenmeyen route: $route"; return 1 ;;
  esac
}

now_ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || echo 0; }

slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40 | sed 's/-$//'; }
