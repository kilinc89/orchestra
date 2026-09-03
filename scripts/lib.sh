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

log()  { printf '[orchestra] %s\n' "$*" >&2; }
warn() { printf '[orchestra] UYARI: %s\n' "$*" >&2; }
die()  { printf '[orchestra] HATA: %s\n' "$*" >&2; exit 1; }

json_str() { jq -Rn --arg v "$1" '$v'; }

# workers.json'dan alan oku: wcfg <worker> <alan>
wcfg() {
  local worker="$1" field="$2" root; root="$(orc_root)"
  jq -r --arg w "$worker" --arg f "$field" \
    '.workers[$w][$f] | if .==null then "" else . end' "$root/workers.json"
}

rcfg() {
  local route="$1" field="$2" root; root="$(orc_root)"
  jq -r --arg r "$route" --arg f "$field" \
    '.routes[$r][$f] | if .==null then "" else . end' "$root/workers.json"
}

dcfg() {
  local field="$1" root; root="$(orc_root)"
  jq -r --arg f "$field" '.defaults[$f] | if .==null then "" else . end' "$root/workers.json"
}

worker_exists() {
  local root; root="$(orc_root)"
  [ "$(jq -r --arg w "$1" 'has("workers") and (.workers|has($w))' "$root/workers.json")" = "true" ]
}

enabled_workers() {
  local root; root="$(orc_root)"
  jq -r '.workers | to_entries[] | select(.value.enabled) | .key' "$root/workers.json"
}

# Bir worker gercekten cagrilabilir mi? Prose degil, kontrol.
worker_callable() {
  local worker="$1" route env_key
  worker_exists "$worker" || { echo "kayitli degil"; return 1; }
  [ "$(wcfg "$worker" enabled)" = "true" ] || { echo "workers.json'da enabled=false"; return 1; }
  route="$(wcfg "$worker" route)"; [ -n "$route" ] || route="$(dcfg route)"
  local engine; engine="$(rcfg "$route" engine)"
  [ -n "$engine" ] || { echo "route '$route' tanimsiz"; return 1; }
  command -v "$engine" >/dev/null 2>&1 || { echo "$engine PATH'te yok"; return 1; }

  case "$route" in
    native)
      [ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ] || { echo "codex auth.json yok"; return 1; }
      echo "ok"; return 0 ;;
    agy)
      # agy kendi auth'unu tasir; ek anahtar yok.
      [ -d "$HOME/.antigravity" ] || { echo "agy yapilandirilmamis (~/.antigravity yok)"; return 1; }
      echo "ok"; return 0 ;;
  esac

  env_key="$(rcfg "$route" env_key)"
  [ -n "$env_key" ] || { echo "route '$route' icin env_key tanimsiz"; return 1; }
  eval "local keyval=\${$env_key:-}"
  [ -n "${keyval:-}" ] || { echo "$env_key ayarlanmamis"; return 1; }
  echo "ok"; return 0
}

now_ms() { python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null || echo 0; }

slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40 | sed 's/-$//'; }
