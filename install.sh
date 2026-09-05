#!/usr/bin/env bash
# Orchestra'yi Claude Code skill dizinine kurar.
set -euo pipefail

usage() {
  cat <<'USAGE'
Kullanim: install.sh --dry-run|--copy [--target DIR] [--no-agents]

Orchestra skill'ini DIR/orchestra altina kurar.
DIR varsayilani: ~/.claude/skills

Ayrica .claude/agents/*.md alt ajanlarini ~/.claude/agents altina kurar
(ORCHESTRA_AGENTS_DIR ile degistirilebilir, --no-agents ile atlanir).
USAGE
}

mode=''; target_root="${ORCHESTRA_SKILLS_DIR:-}"; agents_root="${ORCHESTRA_AGENTS_DIR:-}"; want_agents=1
while (($#)); do
  case "$1" in
    --dry-run) [ -z "$mode" ] || { echo '--dry-run ve --copy birlikte olmaz.' >&2; exit 64; }; mode='dry-run' ;;
    --copy)    [ -z "$mode" ] || { echo '--dry-run ve --copy birlikte olmaz.' >&2; exit 64; }; mode='copy' ;;
    --target)  (($# >= 2)) || { echo '--target bir dizin ister.' >&2; exit 64; }; target_root="$2"; shift ;;
    --no-agents) want_agents=0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Bilinmeyen secenek: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

[ -n "$mode" ] || { usage >&2; exit 64; }
if [ -z "$target_root" ]; then
  [ -n "${HOME:-}" ] || { echo 'HOME ayarla ya da --target DIR ver.' >&2; exit 64; }
  target_root="$HOME/.claude/skills"
fi
[ "$target_root" != '/' ] || { echo "/ altina kurulmaz." >&2; exit 64; }
if [ "$want_agents" = '1' ] && [ -z "$agents_root" ]; then
  [ -n "${HOME:-}" ] || { echo 'HOME ayarla ya da ORCHESTRA_AGENTS_DIR ver.' >&2; exit 64; }
  agents_root="$HOME/.claude/agents"
fi
[ "$agents_root" != '/' ] || { echo "/ altina kurulmaz." >&2; exit 64; }

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
destination="$target_root/orchestra"

files="SKILL.md workers.json scripts/lib.sh scripts/dispatch.sh scripts/orchestra.sh"
for f in $files; do
  [ -f "$repo_root/$f" ] || { echo "Eksik dosya: $repo_root/$f" >&2; exit 66; }
done

# Alt ajanlar: .claude/agents altindaki her .md dosyasi. Bosluklu yollar icin dizi.
agent_files=()
if [ "$want_agents" = '1' ] && [ -d "$repo_root/.claude/agents" ]; then
  while IFS= read -r a; do agent_files+=("$a"); done \
    < <(find "$repo_root/.claude/agents" -maxdepth 1 -type f -name '*.md' | sort)
fi

if [ "$mode" = 'dry-run' ]; then
  printf 'Olusturulacak dizin: %s\n' "$destination/scripts"
  for f in $files; do printf 'Kopyalanacak: %s\n' "$destination/$f"; done
  printf 'Calistirilabilir yapilacak: %s\n' "$destination/scripts/*.sh"
  if ((${#agent_files[@]})); then
    printf 'Olusturulacak dizin: %s\n' "$agents_root"
    for a in "${agent_files[@]}"; do printf 'Kopyalanacak: %s\n' "$agents_root/$(basename "$a")"; done
  fi
  exit 0
fi

[ ! -e "$destination" ] || [ -d "$destination" ] || { echo "Hedef dizin degil: $destination" >&2; exit 73; }
mkdir -p "$destination/scripts"
for f in $files; do cp "$repo_root/$f" "$destination/$f"; done
chmod 0755 "$destination/scripts/"*.sh

if ((${#agent_files[@]})); then
  [ ! -e "$agents_root" ] || [ -d "$agents_root" ] || { echo "Hedef dizin degil: $agents_root" >&2; exit 73; }
  mkdir -p "$agents_root"
  for a in "${agent_files[@]}"; do cp "$a" "$agents_root/$(basename "$a")"; done
  printf 'Alt ajanlar kuruldu: %s (%d dosya)\n' "$agents_root" "${#agent_files[@]}"
fi

printf 'Orchestra kuruldu: %s\n' "$destination"
printf 'Dogrula:  %s preflight\n' "$destination/scripts/orchestra.sh"
