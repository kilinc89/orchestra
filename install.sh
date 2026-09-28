#!/usr/bin/env bash
# Orchestra'yi Claude Code skill dizinine kurar.
set -euo pipefail

usage() {
  cat <<'USAGE'
Kullanim: install.sh --dry-run|--copy [--target DIR] [--no-agents]

Orchestra skill'ini DIR/orchestra, OrchestraG skill'ini DIR/orchestrag altina kurar.
OrchestraG kendi SKILL.md'sini tasir; scripts/ ve workers.json orchestra'ya baglantidir.
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

files="SKILL.md workers.json scripts/lib.sh scripts/dispatch.sh scripts/orchestra.sh scripts/jev.sh"
g_skill="skills/orchestrag/SKILL.md"
for f in $files $g_skill; do
  [ -f "$repo_root/$f" ] || { echo "Eksik dosya: $repo_root/$f" >&2; exit 66; }
done
g_destination="$target_root/orchestrag"

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
  printf 'Kopyalanacak: %s\n' "$g_destination/SKILL.md"
  printf 'Baglanti: %s -> ../orchestra/scripts\n' "$g_destination/scripts"
  printf 'Baglanti: %s -> ../orchestra/workers.json\n' "$g_destination/workers.json"
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

# OrchestraG: ayni script'ler ve kayit, farkli protokol. Goreli baglanti: hedef tasinirsa bozulmaz.
[ ! -e "$g_destination" ] || [ -d "$g_destination" ] || { echo "Hedef dizin degil: $g_destination" >&2; exit 73; }
mkdir -p "$g_destination"
cp "$repo_root/$g_skill" "$g_destination/SKILL.md"
for l in scripts workers.json; do
  [ ! -e "$g_destination/$l" ] || [ -L "$g_destination/$l" ] \
    || { echo "Baglanti yerine gercek dosya var, dokunulmadi: $g_destination/$l" >&2; exit 73; }
  ln -sfn "../orchestra/$l" "$g_destination/$l"
done

if ((${#agent_files[@]})); then
  [ ! -e "$agents_root" ] || [ -d "$agents_root" ] || { echo "Hedef dizin degil: $agents_root" >&2; exit 73; }
  mkdir -p "$agents_root"
  for a in "${agent_files[@]}"; do cp "$a" "$agents_root/$(basename "$a")"; done
  printf 'Alt ajanlar kuruldu: %s (%d dosya)\n' "$agents_root" "${#agent_files[@]}"
fi

printf 'Orchestra kuruldu: %s\n' "$destination"
printf 'OrchestraG kuruldu: %s\n' "$g_destination"
printf 'Dogrula:  %s preflight\n' "$destination/scripts/orchestra.sh"
