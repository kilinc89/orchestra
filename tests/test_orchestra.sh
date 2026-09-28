#!/usr/bin/env bash
# Davranis testi: scriptler sahte bir codex ile GERCEKTEN calistirilir.
# Sadece "dosya var mi" kontrolu degil.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (beklenen='$3' gelen='$2')"; fi; }

TMP="$(mktemp -d -t orchestra-test)"; trap 'rm -rf "$TMP"' EXIT
export PATH="$ROOT/tests/stub:$PATH"
export ORCHESTRA_WORKERS_FILE="$ROOT/tests/fixture-workers.json"
# Saglik onbellegi ve zamanlayici gercek ~/.cache ve ~/Library'ye ASLA yazilmasin.
export ORCHESTRA_HEALTH_FILE="$TMP/health/health.json"
export ORCHESTRA_LAUNCHD_DIR="$TMP/LaunchAgents" ORCHESTRA_LAUNCHCTL="$ROOT/tests/stub/launchctl"

echo "== 1. sozdizimi: bash 3.2 (macOS varsayilani) =="
for f in scripts/lib.sh scripts/dispatch.sh scripts/orchestra.sh scripts/jev.sh install.sh; do
  [ -f "$ROOT/$f" ] || { bad "$f yok"; continue; }
  if /bin/bash -n "$ROOT/$f" 2>/dev/null; then ok "$f"; else bad "$f sozdizimi"; fi
done

echo "== 2. dispatch: basari yolu =="
d="$TMP/d1"; echo "test" > "$TMP/p.txt"
STUB_MODE=ok /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-native --task-id t1 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "status=ok" "$(jq -r .status "$d/result.json")" "ok"
chk "calisan model dogrulandi" "$(jq -r .model_verified "$d/result.json")" "stub/model-x"
chk "istenen model kaydedildi" "$(jq -r .model_requested "$d/result.json")" "test-native-model"

echo "== 3. dispatch: turn.failed AMA exit 0 (kritik) =="
d="$TMP/d2"
STUB_MODE=failed_exit0 /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-native --task-id t2 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
rc=$?
chk "exit 0'a ragmen status=failed" "$(jq -r .status "$d/result.json")" "failed"
chk "dispatch kendi exit'ini 1 yapti" "$rc" "1"
chk "exit_code alani 0 olarak kaydedildi" "$(jq -r .exit_code "$d/result.json")" "0"
if grep -q "asla last.txt" "$d/last.txt" 2>/dev/null; then
  bad "stderr last.txt'e sizdi"; else ok "stderr worker ciktisina karismadi"; fi
if grep -q "asla last.txt" "$d/stderr.log" 2>/dev/null; then
  ok "stderr ayri dosyada duruyor"; else bad "stderr.log bos"; fi

echo "== 4. dispatch: bos cikti =="
d="$TMP/d3"
STUB_MODE=empty /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-native --task-id t3 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "status=empty" "$(jq -r .status "$d/result.json")" "empty"

echo "== 5. dispatch: worker cagrilamiyor =="
d="$TMP/d4"
STUB_MODE=ok /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-nobin --task-id t4 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "engine binary yok -> unavailable" "$(jq -r .status "$d/result.json")" "unavailable"
chk "model uydurulmadi" "$(jq -r '.model_verified//"null"' "$d/result.json")" "null"
if jq -r '.error' "$d/result.json" | grep -q "PATH'te yok"; then
  ok "blocker sebebi acikca yazildi"; else bad "blocker sebebi belirsiz"; fi
d="$TMP/d5"
STUB_MODE=ok /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-off --task-id t5 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "enabled=false -> unavailable" "$(jq -r .status "$d/result.json")" "unavailable"

echo "== 6. git korumasi (tam yetki modu) =="
ws="$TMP/ws"; mkdir -p "$ws"
jq -n '{objective:"x",tasks:[{id:"a",worker:"t-native",prompt:"is yap"}]}' > "$TMP/tasks.json"
out="$(STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/tasks.json" --workspace "$ws" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "git deposu degil"; then
  ok "versiyonsuz workspace reddedildi"; else bad "versiyonsuz workspace gecti"; fi
( cd "$ws" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > f.txt && git add -A && git commit -qm baseline ) >/dev/null 2>&1
echo "kirlilik" > "$ws/dirty.txt"
out="$(STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/tasks.json" --workspace "$ws" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "kirli"; then
  ok "kirli workspace reddedildi"; else bad "kirli workspace gecti"; fi
out="$(STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/tasks.json" --workspace "$ws" --force 2>&1)"
if printf '%s' "$out" | grep -q "git korumasi atlandi"; then ok "--force korumayi asiyor"; else bad "--force calismadi"; fi
rm -f "$ws/dirty.txt"

echo "== 7. dongu: basarisiz gorev yeniden denenir =="
export STUB_COUNT_FILE="$TMP/count"; rm -f "$STUB_COUNT_FILE"
out="$(STUB_MODE=flaky /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/tasks.json" \
  --workspace "$ws" --max-iter 3 2>&1)"; rc=$?
chk "flaky gorev sonunda gecti" "$rc" "0"
if printf '%s' "$out" | grep -q "iterasyon 2"; then ok "2. iterasyona girdi"; else bad "yeniden denemedi"; fi

echo "== 8. dongu: max-iter sinirina uyuluyor =="
out="$(STUB_MODE=failed_exit0 /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/tasks.json" \
  --workspace "$ws" --max-iter 2 2>&1)"; rc=$?
chk "tukenince exit 1" "$rc" "1"
if printf '%s' "$out" | grep -q "iterasyon 3"; then bad "max-iter asildi"; else ok "max-iter=2 asilmadi"; fi

echo "== 9. dongu: kabul kriteri gecince durur =="
out="$(STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/tasks.json" \
  --workspace "$ws" --max-iter 5 --accept "true" 2>&1)"; rc=$?
chk "accept gecince exit 0" "$rc" "0"
if printf '%s' "$out" | grep -q "iterasyon 2"; then bad "gereksiz iterasyon"; else ok "1 iterasyonda durdu"; fi

echo "== 10. hijyen =="
if grep -rIl --exclude-dir=.git --exclude-dir=.orchestra -E '/Users/[a-z]+/' "$ROOT" 2>/dev/null | grep -v tests/ | grep -q .; then
  bad "kisisel mutlak yol gomulu"; else ok "kisisel mutlak yol yok"; fi
if grep -rIn --exclude-dir=.git --exclude-dir=tests -E 'sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}' "$ROOT" 2>/dev/null | grep -q .; then
  bad "anahtar bicimli string"; else ok "anahtar bicimli string yok"; fi
chk "workers.json gecerli" "$(jq empty "$ROOT/workers.json" >/dev/null 2>&1 && echo ok)" "ok"


echo "== 11. agy engine: basari yolu =="
d="$TMP/a1"
STUB_MODE=ok /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-agy --task-id a1 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "agy status=ok"           "$(jq -r .status "$d/result.json")" "ok"
chk "engine=agy kaydedildi"   "$(jq -r .engine "$d/result.json")" "agy"
chk "agy modeli dogrulanamaz -> unverified" "$(jq -r .model_verified "$d/result.json")" "unverified"
chk "conversation_id yakalandi" "$(jq -r .thread_id "$d/result.json")" "agy-stub-1"
if [ -f "$d/usage.json" ]; then ok "token kullanimi saklandi"; else bad "usage.json yok"; fi

echo "== 12. agy engine: status=ERROR =="
d="$TMP/a2"
STUB_MODE=failed_exit0 /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-agy --task-id a2 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "agy ERROR -> failed" "$(jq -r .status "$d/result.json")" "failed"
if grep -q "asla last.txt" "$d/last.txt" 2>/dev/null; then
  bad "agy stderr last.txt'e sizdi"; else ok "agy stderr ayrildi"; fi

echo "== 13. agy engine: bos yanit =="
d="$TMP/a3"
STUB_MODE=empty /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-agy --task-id a3 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "agy bos yanit -> empty" "$(jq -r .status "$d/result.json")" "empty"

echo "== 14. karma tur: codex + agy paralel =="
jq -n '{objective:"karma",tasks:[
  {id:"impl",worker:"t-native",prompt:"kodu yaz"},
  {id:"rev", worker:"t-agy",prompt:"incele"}]}' > "$TMP/mixed.json"
ws2="$TMP/ws2"; mkdir -p "$ws2"
( cd "$ws2" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > f.txt && git add -A && git commit -qm baseline ) >/dev/null 2>&1
STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/mixed.json" \
  --workspace "$ws2" --max-iter 1 >/dev/null 2>&1; rc=$?
chk "karma tur basarili" "$rc" "0"
rj="$(find "$ws2/.orchestra/runs" -name round.json | sort | tail -1)"
chk "iki engine de kosuldu" "$(jq -r '[.results[].engine]|sort|join(",")' "$rj")" "agy,codex"


echo "== 15. regresyon: ikinci run kendi cikti dizini yuzunden reddedilmemeli =="
STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/mixed.json" \
  --workspace "$ws2" --max-iter 1 >/dev/null 2>&1
chk "ayni workspace'te ikinci run" "$?" "0"
if git -C "$ws2" status --porcelain | grep -q '.orchestra'; then
  bad ".orchestra/ workspace'i kirletiyor"; else ok ".orchestra/ git'ten haric tutuldu"; fi
if grep -qxF '.orchestra/' "$ws2/.git/info/exclude" 2>/dev/null; then
  ok "exclude .git/info/exclude'a yazildi (kullanici .gitignore'u temiz)"; else bad "exclude yazilmadi"; fi


echo "== 16. yalnizca yerel CLI: harici saglayici kalintisi yok =="
# Worker'lar anahtar tasimaz. Tek bilincli istisna Jev yonlendiricisi (scripts/jev.sh).
if grep -rIn --exclude-dir=.git --exclude-dir=tests --exclude-dir=.orchestra --exclude=jev.sh \
     -iE 'openrouter|deepseek|api[_-]?key' "$ROOT" 2>/dev/null | grep -v README.md | grep -q .; then
  bad "kodda/konfigde harici saglayici izi var"; else ok "kodda harici saglayici/anahtar izi yok"; fi
routes="$(jq -r '.routes|keys|sort|join(",")' "$ROOT/workers.json")"
chk "uc route tanimli" "$routes" "agy,cursor,native"
engines="$(jq -r '[.routes[].engine]|sort|unique|join(",")' "$ROOT/workers.json")"
chk "sadece yerel CLI engine'leri" "$engines" "agent,agy,codex"
if jq -e '[.routes[]|select(has("env_key"))]|length==0' "$ROOT/workers.json" >/dev/null; then
  ok "hicbir route env_key istemiyor"; else bad "bir route hala env_key istiyor"; fi


echo "== 17. cursor engine: basari yolu =="
d="$TMP/c1"
STUB_MODE=ok /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-cursor --task-id c1 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "cursor status=ok"        "$(jq -r .status "$d/result.json")" "ok"
chk "engine=agent kaydedildi" "$(jq -r .engine "$d/result.json")" "agent"
chk "session_id yakalandi"    "$(jq -r .thread_id "$d/result.json")" "cur-stub-1"
chk "cursor modeli dogrulanamaz -> unverified" "$(jq -r .model_verified "$d/result.json")" "unverified"

echo "== 18. REGRESYON: is_error=false (boolean) basari sayilmali =="
# jq'da "false // empty" -> empty. Bu tuzak gercek bir bug'a yol acmisti:
# calisan her cursor worker'i KIRIK gorunuyordu.
if grep -q 'is_error // empty' "$ROOT/scripts/dispatch.sh"; then
  bad "is_error hala falsy-yutan '// empty' ile okunuyor"; else ok "is_error falsy-guvenli okunuyor"; fi
chk "is_error=false -> ok" "$(jq -r .status "$d/result.json")" "ok"

echo "== 19. cursor engine: is_error=true =="
d="$TMP/c2"
STUB_MODE=failed_exit0 /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-cursor --task-id c2 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "is_error=true -> failed" "$(jq -r .status "$d/result.json")" "failed"
if grep -q "asla last.txt" "$d/last.txt" 2>/dev/null; then
  bad "cursor stderr last.txt'e sizdi"; else ok "cursor stderr ayrildi"; fi

echo "== 20. cursor engine: bos yanit =="
d="$TMP/c3"
STUB_MODE=empty /bin/bash "$ROOT/scripts/dispatch.sh" --worker t-cursor --task-id c3 \
  --prompt-file "$TMP/p.txt" --out-dir "$d" >/dev/null 2>&1
chk "cursor bos yanit -> empty" "$(jq -r .status "$d/result.json")" "empty"

echo "== 21. engine adi = binary adi (uc engine) =="
for e in $(jq -r '.routes[].engine' "$ROOT/workers.json" | sort -u); do
  if grep -q "\"\$engine\" = \"$e\"" "$ROOT/scripts/dispatch.sh"; then
    ok "dispatch '$e' engine'ini taniyor"
  else bad "dispatch '$e' engine'ini TANIMIYOR (route/dispatch uyusmazligi)"; fi
done

echo "== 22. uc engine ayni turda paralel =="
jq -n '{objective:"uclu",tasks:[
  {id:"a",worker:"t-native",prompt:"x"},
  {id:"b",worker:"t-agy",prompt:"y"},
  {id:"c",worker:"t-cursor",prompt:"z"}]}' > "$TMP/tri.json"
ws3="$TMP/ws3"; mkdir -p "$ws3"
( cd "$ws3" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > f.txt && git add -A && git commit -qm baseline ) >/dev/null 2>&1
STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/tri.json" \
  --workspace "$ws3" --max-iter 1 >/dev/null 2>&1
chk "uclu tur basarili" "$?" "0"
rj3="$(find "$ws3/.orchestra/runs" -name round.json | sort | tail -1)"
chk "uc engine de kosuldu" "$(jq -r '[.results[].engine]|sort|join(",")' "$rj3")" "agent,agy,codex"


echo "== 23. REGRESYON: yolunda BOSLUK olan workspace =="
# Tirnaksiz $(find ...) bosluklu yolda parcalanip round.json'u BOSALTIYORDU;
# sonuc: basarisiz gorevler "0 gorev, 0 basarisiz" diye basarili gorunuyordu.
wss="$TMP/ws bosluklu"; mkdir -p "$wss"
( cd "$wss" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > f.txt && git add -A && git commit -qm baseline ) >/dev/null 2>&1
STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/mixed.json" \
  --workspace "$wss" --max-iter 1 >/dev/null 2>&1
chk "bosluklu yolda run" "$?" "0"
rjs="$(find "$wss/.orchestra/runs" -name round.json | sort | tail -1)"
chk "sonuclar toplandi (bos degil)" "$(jq -r '.results|length' "$rjs")" "2"

echo "== 24. REGRESYON: bosluklu yolda BASARISIZLIK gizlenmemeli =="
# Ayri workspace: ayni dizinde birden fazla kosu olunca "find | tail -1" sirasiz
# davranip onceki turun round.json'unu secebiliyordu (flaky testin sebebi).
wss2="$TMP/ws2 bosluklu"; mkdir -p "$wss2"
( cd "$wss2" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > f.txt && git add -A && git commit -qm baseline ) >/dev/null 2>&1
STUB_MODE=failed_exit0 /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/mixed.json" \
  --workspace "$wss2" --max-iter 1 >/dev/null 2>&1
chk "basarisiz tur exit 1 dondu" "$?" "1"
rjs2="$(find "$wss2/.orchestra/runs" -name round.json | sort | tail -1)"
chk "basarisizlik round.json'da gorunuyor" \
  "$(jq -r '[.results[]|select(.status!="ok")]|length' "$rjs2")" "2"

echo "== 25. Jev: anahtar deposu (Keychain kapali, dosya yolu) =="
export ORCHESTRA_JEV_KEYCHAIN=0 ORCHESTRA_JEV_KEY_FILE="$TMP/jev/typesafe.key"
unset TYPESAFE_API_KEY
/bin/bash "$ROOT/scripts/orchestra.sh" jev-key status >/dev/null 2>&1
chk "anahtar yokken status exit 1" "$?" "1"
printf 'ts_test_SECRET1234\n' | /bin/bash "$ROOT/scripts/orchestra.sh" jev-key set >/dev/null 2>&1
chk "anahtar stdin'den kaydedildi" "$(cat "$ORCHESTRA_JEV_KEY_FILE")" "ts_test_SECRET1234"
chk "anahtar dosyasi 0600" "$(stat -f '%Lp' "$ORCHESTRA_JEV_KEY_FILE" 2>/dev/null || stat -c '%a' "$ORCHESTRA_JEV_KEY_FILE")" "600"
st="$(/bin/bash "$ROOT/scripts/orchestra.sh" jev-key status 2>&1)"
if printf '%s' "$st" | grep -q 'SECRET1234'; then bad "status anahtari acik basti"; else ok "status anahtari maskeledi"; fi
chk "status kaynagi dosya" "$(printf '%s' "$st" | awk '{print $2}')" "file"

echo "== 26. Jev (OrchestraG, --pool all): iki asama, kanit, anahtar argv'ye dusmez =="
jq -n '{objective:"j",tasks:[
  {id:"impl",worker:"auto",prompt:"parser.ts icinde parseConfig yaz"},
  {id:"fixed",worker:"t-agy",prompt:"incele"}]}' > "$TMP/jt.json"
rm -f "$TMP/jev/bodies"
STUB_JEV_ROLE=implement STUB_JEV_WORKER=t-native STUB_CURL_ARGV="$TMP/jev/argv" STUB_CURL_STDIN="$TMP/jev/stdin" \
  STUB_CURL_BODIES="$TMP/jev/bodies" \
  /bin/bash "$ROOT/scripts/orchestra.sh" route --tasks "$TMP/jt.json" --out "$TMP/jt.out.json" >/dev/null 2>&1
chk "route exit 0" "$?" "0"
chk "auto gorev atandi" "$(jq -r '.tasks[0].worker' "$TMP/jt.out.json")" "t-native"
chk "routing kaniti yazildi" "$(jq -r '.tasks[0].routing|"\(.confidence) \(.role) \(.kind) \(.pool)"' "$TMP/jt.out.json")" "0.93 implement worker all"
chk "sabit worker'a dokunulmadi" "$(jq -r '.tasks[1].worker+":"+(.tasks[1].routing//"yok"|tostring)' "$TMP/jt.out.json")" "t-agy:yok"
chk "iki ayri soru soruldu" "$(jq -s -r 'map(.questions|keys[0])|join(",")' "$TMP/jev/bodies")" "role,worker"
chk "ikinci soru yalnizca o roldeki adaylari gordu" \
  "$(jq -s -r '.[1].questions.worker.criteria|keys|join(",")' "$TMP/jev/bodies")" "s-deep,s-impl,t-native"
chk "kapali alt ajan aday degil" "$(jq -s -r '[.[0].questions.role.criteria|keys[]]|join(",")' "$TMP/jev/bodies")" "implement,loop,review"
if grep -q 'SECRET1234' "$TMP/jev/argv"; then bad "anahtar curl argv'sinde"; else ok "anahtar argv'de yok"; fi
if grep -q 'Bearer ts_test_SECRET1234' "$TMP/jev/stdin"; then ok "anahtar stdin config ile gitti"; else bad "Authorization basligi gitmedi"; fi
if grep -q 'SECRET1234' "$TMP/jt.out.json" "$TMP/jev/bodies"; then bad "anahtar ciktiya/govdeye sizdi"; else ok "anahtar ciktiya sizmadi"; fi

echo "== 27. Jev (Orchestra, --pool claude): yalnizca Claude alt ajanlari =="
rm -f "$TMP/jev/bodies"
STUB_JEV_ROLE=review STUB_CURL_BODIES="$TMP/jev/bodies" \
  /bin/bash "$ROOT/scripts/orchestra.sh" route --pool claude --prompt "incele" > "$TMP/jev/c1.json" 2>/dev/null
chk "review -> tek aday s-deep" "$(jq -r '.worker+" "+.kind+" "+.model' "$TMP/jev/c1.json")" "s-deep subagent opus"
chk "rolde tek aday: worker sorusu yok" "$(jq -s length "$TMP/jev/bodies")" "1"
STUB_JEV_ROLE=implement STUB_JEV_WORKER=t-native \
  /bin/bash "$ROOT/scripts/orchestra.sh" route --pool claude --prompt "x" > "$TMP/jev/c2.json" 2>/dev/null
chk "claude havuzunda CLI worker secilemez" "$(jq -r .status "$TMP/jev/c2.json")" "error"
STUB_JEV_ROLE=review /bin/bash "$ROOT/scripts/orchestra.sh" route --pool claude --prompt "x" --exclude s-deep \
  > "$TMP/jev/c3.json" 2>/dev/null
chk "haric tutulunca rolde aday kalmadi" "$(jq -r .error "$TMP/jev/c3.json")" "bu rolde aday yok"
/bin/bash "$ROOT/scripts/orchestra.sh" route --pool bogus --prompt "x" >/dev/null 2>&1
chk "gecersiz havuz reddedildi" "$?" "1"

echo "== 28. Jev: havuz esikleri (Orchestra 0.5, OrchestraG 0.4) =="
STUB_JEV_ROLE=implement STUB_JEV_CONF=0.45 \
  /bin/bash "$ROOT/scripts/orchestra.sh" route --pool all --prompt "x" > "$TMP/jev/t1.json" 2>/dev/null
chk "OrchestraG: 0.45 yeterli" "$(jq -r '.status+" "+(.min_confidence|tostring)' "$TMP/jev/t1.json")" "ok 0.4"
STUB_JEV_ROLE=implement STUB_JEV_CONF=0.45 \
  /bin/bash "$ROOT/scripts/orchestra.sh" route --pool claude --prompt "x" > "$TMP/jev/t2.json" 2>/dev/null
chk "Orchestra: 0.45 yetmez -> exit 2" "$?" "2"
chk "Orchestra: dusuk guven worker asamasinda" "$(jq -r '.status+" "+.stage' "$TMP/jev/t2.json")" "low_confidence worker"
STUB_JEV_ROLE_CONF=0.3 /bin/bash "$ROOT/scripts/orchestra.sh" route --tasks "$TMP/jt.json" --out "$TMP/jt.low.json" >/dev/null 2>&1
chk "is turu belirsiz -> exit 2" "$?" "2"
chk "is turu belirsiz -> auto kaldi" "$(jq -r '.tasks[0].worker' "$TMP/jt.low.json")" "auto"
chk "belirsizlik role asamasinda kaydedildi" "$(jq -r '.tasks[0].routing|.status+" "+.stage' "$TMP/jt.low.json")" "low_confidence role"
STUB_JEV_MODE=http401 /bin/bash "$ROOT/scripts/orchestra.sh" route --tasks "$TMP/jt.json" --out "$TMP/jt.401.json" >/dev/null 2>&1
chk "HTTP 401 -> exit 2" "$?" "2"
chk "HTTP hatasi kaydedildi" "$(jq -r '.tasks[0].routing.http+" "+.tasks[0].routing.error' "$TMP/jt.401.json")" "401 invalid api key"

echo "== 29. Jev: anahtar yoksa cagri yapilmaz, run auto gorevi reddeder =="
rm -f "$ORCHESTRA_JEV_KEY_FILE"
STUB_CURL_ARGV="$TMP/jev/argv.none" /bin/bash "$ROOT/scripts/orchestra.sh" route --prompt "x" >/dev/null 2>&1
chk "anahtar yok -> exit 1" "$?" "1"
if [ -f "$TMP/jev/argv.none" ]; then bad "anahtarsiz curl cagrildi"; else ok "anahtarsiz ag cagrisi yok"; fi
STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/jt.json" --workspace "$ws3" --max-iter 1 >/dev/null 2>&1
chk "run auto gorevi reddetti" "$?" "1"
jq -n '{objective:"s",tasks:[{id:"a",worker:"s-impl",prompt:"x"}]}' > "$TMP/js.json"
out="$(STUB_MODE=ok /bin/bash "$ROOT/scripts/orchestra.sh" run --tasks "$TMP/js.json" --workspace "$ws3" --max-iter 1 2>&1)"
chk "run alt ajan gorevini reddetti" "$?" "1"
if printf '%s' "$out" | grep -q 'Agent tool'; then ok "red mesaji Agent tool'u gosteriyor"; else bad "red mesaji belirsiz"; fi
unset ORCHESTRA_JEV_KEYCHAIN ORCHESTRA_JEV_KEY_FILE

echo "== 30. install: Orchestra + OrchestraG =="
it="$TMP/inst"
/bin/bash "$ROOT/install.sh" --copy --target "$it" --no-agents >/dev/null 2>&1
chk "install exit 0" "$?" "0"
chk "orchestra skill adi" "$(sed -n 's/^name: //p' "$it/orchestra/SKILL.md")" "orchestra"
chk "orchestrag skill adi" "$(sed -n 's/^name: //p' "$it/orchestrag/SKILL.md")" "orchestrag"
chk "iki skill de Opus 5.5" "$(cat "$it/orchestra/SKILL.md" "$it/orchestrag/SKILL.md" | grep -c '^model: claude-opus-5-5$')" "2"
chk "orchestrag scripts baglanti" "$(readlink "$it/orchestrag/scripts")" "../orchestra/scripts"
out="$(ORCHESTRA_WORKERS_FILE= /bin/bash "$it/orchestrag/scripts/orchestra.sh" workers 2>&1)"
if printf '%s' "$out" | grep -q 'claude-opus'; then ok "orchestrag yolundan kayit okundu"; else bad "orchestrag workers.json'u bulamadi"; fi
/bin/bash "$ROOT/install.sh" --copy --target "$it" --no-agents >/dev/null 2>&1
chk "ikinci kurulum da exit 0" "$?" "0"

echo "== 31. health: kota dolu worker ayri etiketlenir =="
HF="$ORCHESTRA_HEALTH_FILE"; rm -f "$HF"
STUB_MODE=ok STUB_AGENT_MODE=quota /bin/bash "$ROOT/scripts/orchestra.sh" health --quiet >/dev/null 2>&1
chk "health exit 0" "$?" "0"
chk "onbellek yazildi" "$(jq -r '.workers|keys|join(",")' "$HF")" "t-agy,t-cursor,t-native,t-nobin"
chk "kotasi dolan -> quota" "$(jq -r '.workers["t-cursor"].status' "$HF")" "quota"
chk "calisan -> ok" "$(jq -r '.workers["t-native"].status+","+.workers["t-agy"].status' "$HF")" "ok,ok"
chk "binary yok -> unavailable" "$(jq -r '.workers["t-nobin"].status' "$HF")" "unavailable"
chk "aralik kaydedildi" "$(jq -r .interval_sec "$HF")" "14400"
if [ -e "$HF.lock" ]; then bad "kilit birakildi"; else ok "kilit temizlendi"; fi

echo "== 32. route: kotasi dolan worker aday olmaz =="
rm -f "$TMP/jev/bodies"; before="$(jq -r .checked_at "$HF")"
STUB_JEV_ROLE=review STUB_CURL_BODIES="$TMP/jev/bodies" \
  /bin/bash "$ROOT/scripts/orchestra.sh" route --pool all --prompt "incele" > "$TMP/jev/h1.json" 2>/dev/null
chk "review adaylarinda t-cursor yok" "$(jq -s -r '.[1].questions.worker.criteria|keys|join(",")' "$TMP/jev/bodies")" "s-deep,t-agy"
chk "disarida kalan kanitta" "$(jq -r '.unhealthy_excluded|join(",")' "$TMP/jev/h1.json")" "t-cursor=quota"
chk "taze onbellek yeniden kontrol edilmedi" "$(jq -r .checked_at "$HF")" "$before"
STUB_JEV_ROLE=review STUB_JEV_WORKER=t-cursor \
  /bin/bash "$ROOT/scripts/orchestra.sh" route --pool all --prompt "incele" > "$TMP/jev/h2.json" 2>/dev/null
chk "Jev kotasi dolani secse bile atanmaz" "$(jq -r .status "$TMP/jev/h2.json")" "error"

echo "== 33. route: onbellek 4 saatten eskiyse yenilenir =="
jq '.checked_at = (.checked_at - 14401)' "$HF" > "$HF.x" && mv "$HF.x" "$HF"
old="$(jq -r .checked_at "$HF")"
ORCHESTRA_HEALTH_AUTO=0 STUB_JEV_ROLE=review /bin/bash "$ROOT/scripts/orchestra.sh" route --pool all --prompt "x" >/dev/null 2>&1
chk "ORCHESTRA_HEALTH_AUTO=0 -> yenileme yok" "$(jq -r .checked_at "$HF")" "$old"
STUB_MODE=ok STUB_JEV_ROLE=review /bin/bash "$ROOT/scripts/orchestra.sh" route --pool all --prompt "x" > "$TMP/jev/h3.json" 2>/dev/null
if [ "$(jq -r .checked_at "$HF")" -gt "$old" ]; then ok "eski onbellek yenilendi"; else bad "eski onbellek yenilenmedi"; fi
chk "kota acilinca worker geri geldi" "$(jq -r '.workers["t-cursor"].status' "$HF")" "ok"
chk "artik disarida kalan yok" "$(jq -r '.unhealthy_excluded|length' "$TMP/jev/h3.json")" "0"
rm -f "$HF"
STUB_JEV_ROLE=review /bin/bash "$ROOT/scripts/orchestra.sh" route --pool claude --prompt "x" >/dev/null 2>&1
if [ -f "$HF" ]; then bad "claude havuzu CLI ping'i atti"; else ok "claude havuzu saglik kontrolu yapmaz"; fi

echo "== 34. health: takilan worker zaman asiminda kirik sayilir =="
STUB_MODE=ok STUB_AGENT_MODE=hang /bin/bash "$ROOT/scripts/orchestra.sh" health --quiet >/dev/null 2>&1
chk "takilan -> broken" "$(jq -r '.workers["t-cursor"].status' "$HF")" "broken"
chk "sebep zaman asimi" "$(jq -r '.workers["t-cursor"].detail' "$HF")" "zaman asimi (3s)"
if pgrep -f 'stub/agent' >/dev/null 2>&1; then bad "takilan surec oldurulmedi"; else ok "takilan surec olduruldu"; fi

echo "== 35. schedule: 4 saatte bir LaunchAgent =="
STUB_LAUNCHCTL_LOG="$TMP/lc.log" /bin/bash "$ROOT/scripts/orchestra.sh" schedule install >/dev/null 2>&1
chk "schedule install exit 0" "$?" "0"
pl="$ORCHESTRA_LAUNCHD_DIR/com.orchestra.health.plist"
chk "StartInterval 14400" "$(plutil -extract StartInterval raw "$pl" 2>/dev/null)" "14400"
chk "health --quiet calistirir" "$(plutil -extract ProgramArguments.2 raw "$pl" 2>/dev/null) $(plutil -extract ProgramArguments.3 raw "$pl" 2>/dev/null)" "health --quiet"
if plutil -lint "$pl" >/dev/null 2>&1; then ok "plist gecerli"; else bad "plist gecersiz"; fi
if grep -q '^bootstrap gui/' "$TMP/lc.log"; then ok "launchd'ye yuklendi"; else bad "bootstrap cagrilmadi"; fi
/bin/bash "$ROOT/scripts/orchestra.sh" schedule remove >/dev/null 2>&1
if [ -f "$pl" ]; then bad "remove plist'i silmedi"; else ok "remove plist'i sildi"; fi

echo
if [ "$FAIL" -eq 0 ]; then echo "PASS: $PASS test gecti, 0 basarisiz"; exit 0
else echo "FAIL: $PASS gecti, $FAIL BASARISIZ"; exit 1; fi
