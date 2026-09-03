#!/usr/bin/env bash
# README'yi gercek duruma karsi denetler. run --accept icin kabul kriteri.
# Iddia degil olcum: worker listesi workers.json'dan, test sayisi test paketinden gelir.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
R="$ROOT/README.md"
fails=()
need() { grep -qF -- "$1" "$R" || fails+=("eksik: $2"); }

[ -f "$R" ] || { echo "README.md yok"; exit 1; }

# 1) enabled her worker README'de gecmeli
while IFS= read -r w; do
  grep -qE "\`$w\`" "$R" || fails+=("enabled worker README'de yok: $w")
done < <(jq -r '.workers|to_entries[]|select(.value.enabled)|.key' "$ROOT/workers.json")

# 2) enabled worker'larin model ID'leri dogru yazilmali
while IFS= read -r m; do
  grep -qF -- "$m" "$R" || fails+=("model ID README'de yok/yanlis: $m")
done < <(jq -r '.workers|to_entries[]|select(.value.enabled)|.value.model' "$ROOT/workers.json")

# 3) her engine belgelenmeli
while IFS= read -r e; do
  grep -qE "\`$e\`" "$R" || fails+=("engine README'de yok: $e")
done < <(jq -r '[.routes[].engine]|unique[]' "$ROOT/workers.json")

# 4) her alt komut belgelenmeli
for c in preflight workers doctor run loop; do
  grep -qE "orchestra\.sh $c|^\`\`\`|\`$c\`" "$R" || true
  grep -q "$c" "$R" || fails+=("alt komut README'de yok: $c")
done

# 5) test sayisi gercekle uyusmali
actual="$(grep -c '^  ok\|^  FAIL' <(/bin/bash "$ROOT/tests/test_orchestra.sh" 2>/dev/null) || echo 0)"
grep -qE "\b$actual test\b" "$R" || fails+=("README'deki test sayisi gercekle uyusmuyor (gercek: $actual)")

# 6) repo agacindaki her dosya "Repo duzeni" bolumunde gorunmeli
grep -q 'check_readme.sh' "$R" || fails+=("tests/check_readme.sh README'de anilmiyor")
grep -q 'stub/agent' "$R" || fails+=("tests/stub/agent README'de anilmiyor")

# 7) kaldirilmis seyler README'de KALMAMALI
for dead in OPENROUTER_API_KEY deepseek-v4-flash openrouter.ai; do
  grep -qF -- "$dead" "$R" && fails+=("kaldirilmis oge hala README'de: $dead")
done

if ((${#fails[@]})); then
  printf 'README DENETIMI BASARISIZ (%d):\n' "${#fails[@]}"
  printf '  - %s\n' "${fails[@]}"
  exit 1
fi
echo "README DENETIMI GECTI"
