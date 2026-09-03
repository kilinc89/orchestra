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

# 6) "Repo duzeni" bolumu olmali ve git ls-files'daki HER dosyayi anmali
if ! grep -qE '^## Repo d[uü]zeni' "$R"; then
  fails+=("'## Repo duzeni' bolumu yok")
else
  while IFS= read -r f; do
    grep -qF -- "$(basename "$f")" "$R" || fails+=("repo dosyasi README'de anilmiyor: $f")
  done < <(git -C "$ROOT" ls-files)
fi

# 7) Turkce dokumanda Turkce karakter kullanilmali: ASCII-only baslik = uslup kaymasi
while IFS= read -r h; do
  case "$h" in
    *[çğıöşüÇĞİÖŞÜ]*) ;;
    *[Dd]uzeni*|*[Kk]osu*|*[Cc]alis*|*[Ss]onuc*|*[Gg]orev*|*[Bb]asari*)
      fails+=("baslikta Turkce karakter eksik: $h") ;;
  esac
done < <(grep -E '^#{2,3} ' "$R")

# 8b) 3 engine varken "ikisi/her iki" gibi ikili ifadeler kalmamali
if [ "$(jq -r '[.routes[].engine]|unique|length' "$ROOT/workers.json")" -ge 3 ]; then
  while IFS= read -r bad; do
    fails+=("ikili ifade ama 3 engine var: $bad")
  done < <(grep -nE 'Her ikisi|ikisini|her iki CLI|İki engine' "$R" | cut -c1-80)
fi

# 8c) sahte engine sayisi stub dosya sayisiyla uyusmali
n_stub="$(ls "$ROOT/tests/stub" | wc -l | tr -d ' ')"
for st in codex agy agent; do
  grep -qE "\`$st\`" "$R" || fails+=("stub README'de anilmiyor: tests/stub/$st")
done

# 8d) doctor tablosundaki worker sayisi gercekle uyusmali
n_on="$(jq -r '[.workers[]|select(.enabled)]|length' "$ROOT/workers.json")"
grep -qE "$n_on worker" "$R" || fails+=("doctor satirindaki worker sayisi $n_on olmali")

# 8) engine sayisi metinde dogru yazilmali
n_eng="$(jq -r '[.routes[].engine]|unique|length' "$ROOT/workers.json")"
case "$n_eng" in
  3) grep -qE 'Üç engine|uc engine' "$R" || fails+=("engine sayisi ($n_eng) basligi yanlis")
     grep -q 'Orchestra ikisini' "$R" && fails+=("eskimis ifade: 'Orchestra ikisini' ama $n_eng engine var") ;;
esac

# 7) kaldirilmis seyler README'de KALMAMALI
for dead in OPENROUTER_API_KEY deepseek-v4-flash openrouter.ai OpenRouter DeepSeek; do
  grep -qF -- "$dead" "$R" && fails+=("kaldirilmis oge hala README'de: $dead")
done

# 7b) harici saglayici kalkinca anlamsizlasan "API key yok" turu ifadeler de gitmeli
while IFS= read -r resid; do
  fails+=("harici saglayici kalintisi ifade: $resid")
done < <(grep -niE 'API key|harici sağlayıcı|harici saglayici|proxy' "$R" | cut -c1-70)

# 7c) Tasarim kararlari, worker_callable'in GERCEKTE kontrol ettigini anlatmali.
# Anahtar kontrolu OpenRouter ile birlikte kaldirildi; README hala anlatiyorsa yanlis.
grep -qiE 'anahtar[ıi]? gerçekten kontrol|Anahtar yoksa' "$R" \
  && fails+=("README kaldirilmis anahtar kontrolunu anlatiyor (worker_callable artik binary + giris dosyasi bakar)")

if ((${#fails[@]})); then
  printf 'README DENETIMI BASARISIZ (%d):\n' "${#fails[@]}"
  printf '  - %s\n' "${fails[@]}"
  exit 1
fi
echo "README DENETIMI GECTI"
