#!/usr/bin/env bash
# Jev yonlendirici - TypeSafe'in System One modeli Jev'e "bu gorevi hangi worker
# yapmali?" diye sorar. Jev metin uretmez: secim + olasilik + confidence dondurur.
# Karar tavsiyedir; orkestrator (Claude) aile kuralini ve doctor sonucunu yine denetler.
#
# Alt komutlar:
#   jev.sh key set|status|delete
#   jev.sh route --tasks FILE [--out FILE] | --prompt TEXT  [--pool claude|all] [--exclude w1,w2]
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

KEY_SERVICE='orchestra-typesafe'
KEY_ACCOUNT="${USER:-orchestra}"
key_file() { printf '%s' "${ORCHESTRA_JEV_KEY_FILE:-$HOME/.config/orchestra/typesafe.key}"; }
# Testler Keychain'e dokunmasin diye kapatilabilir.
use_keychain() {
  [ "${ORCHESTRA_JEV_KEYCHAIN:-1}" = "1" ] && command -v security >/dev/null 2>&1
}

# workers.json'daki "jev" blogu; yoksa varsayilan.
jcfg() {
  jq -r --arg f "$1" --arg d "$2" '(.jev // {})[$f] // $d | tostring' "$(workers_file)"
}

usage() {
  cat <<'USAGE'
Kullanim:
  jev.sh key set       anahtari stdin'den (ya da gizli istemden) okuyup saklar
  jev.sh key status    anahtarin nereden geldigini maskeli gosterir
  jev.sh key delete    saklanan anahtari siler
  jev.sh route --tasks FILE [--out FILE] [--pool claude|all] [--exclude w1,w2]
  jev.sh route --prompt TEXT [--pool claude|all] [--exclude w1,w2]

  Anahtar sirasi: TYPESAFE_API_KEY ortam degiskeni > macOS Keychain
  (servis: orchestra-typesafe) > ~/.config/orchestra/typesafe.key (0600).
  Anahtar asla argv'ye, log'a ya da kosu dizinine yazilmaz.

  route: "worker": "auto" (ya da worker'i olmayan) gorevleri Jev'e sorar.
    --pool claude  yalnizca Claude Code alt ajanlari (Orchestra)
    --pool all     alt ajanlar + GPT/Gemini/Composer CLI worker'lari (OrchestraG, varsayilan)
  --pool all, secimden once saglik onbellegini (orchestra.sh health) 4 saatten
  eskiyse yeniler; kotasi dolan ya da kirik worker'lar aday olmaz.
  Once is turu, sonra o turdeki adaylar arasindan worker sorulur. Iki cevaptan
  biri havuzun esiginin (jev.min_confidence) altindaysa worker ATANMAZ, "auto"
  kalir ve cikis kodu 2 olur - karari orkestrator verir.
USAGE
}

# --- anahtar deposu ---
key_get() {
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then printf '%s' "$TYPESAFE_API_KEY"; return 0; fi
  if use_keychain; then
    security find-generic-password -s "$KEY_SERVICE" -a "$KEY_ACCOUNT" -w 2>/dev/null && return 0
  fi
  [ -f "$(key_file)" ] && { tr -d '\n' < "$(key_file)"; return 0; }
  return 1
}

key_source() {
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then echo env; return; fi
  if use_keychain && security find-generic-password -s "$KEY_SERVICE" -a "$KEY_ACCOUNT" >/dev/null 2>&1; then
    echo keychain; return; fi
  [ -f "$(key_file)" ] && { echo file; return; }
  echo none
}

cmd_key() {
  case "${1:-}" in
    set)
      local k=''
      if [ -t 0 ]; then
        printf 'TypeSafe anahtari (gorunmez): ' >&2; IFS= read -rs k; echo >&2
      else
        IFS= read -r k || true
      fi
      k="$(printf '%s' "$k" | tr -d '[:space:]')"
      [ -n "$k" ] || die "bos anahtar"
      # security -i komutu tirnakla okur; tirnak/ters bolu iceren anahtar bozulur.
      case "$k" in *'"'*|*'\'*) die "anahtarda tirnak veya ters bolu olamaz" ;; esac
      if use_keychain; then
        # -w degeri argv yerine stdin'den gider: ps ciktisinda gorunmez.
        printf 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' "$KEY_SERVICE" "$KEY_ACCOUNT" "$k" \
          | security -i >/dev/null 2>&1 || die "Keychain'e yazilamadi"
        rm -f "$(key_file)"
        log "anahtar Keychain'e kaydedildi (servis: $KEY_SERVICE, hesap: $KEY_ACCOUNT)"
      else
        mkdir -p "$(dirname "$(key_file)")"
        ( umask 077; printf '%s\n' "$k" > "$(key_file)" )
        chmod 600 "$(key_file)"
        log "anahtar dosyaya kaydedildi: $(key_file) (0600)"
      fi ;;
    status)
      local src k; src="$(key_source)"
      [ "$src" != none ] || { echo "anahtar yok -> jev.sh key set"; return 1; }
      k="$(key_get)"
      printf 'kaynak: %s  anahtar: ****%s (%d karakter)\n' "$src" "${k: -4}" "${#k}" ;;
    delete)
      if use_keychain; then
        security delete-generic-password -s "$KEY_SERVICE" -a "$KEY_ACCOUNT" >/dev/null 2>&1 \
          && log "Keychain kaydi silindi" || true
      fi
      [ -f "$(key_file)" ] && rm -f "$(key_file)" && log "anahtar dosyasi silindi"
      [ -z "${TYPESAFE_API_KEY:-}" ] || warn "TYPESAFE_API_KEY ortam degiskeni hala ayarli"
      return 0 ;;
    *) usage >&2; exit 64 ;;
  esac
}

# --- aday havuzu ---
# Iki havuz:
#   claude  yalnizca Claude Code alt ajanlari (workers.json "subagents"). Orkestrator
#           bunlari Agent tool ile calistirir; dispatch.sh'tan gecmezler.
#   all     alt ajanlar + cagrilabilir CLI worker'lari (GPT, Gemini, Composer, ...).
# Cikti: {"<ad>": {"kind","roles":[...],"model","use_for"}}
candidates_json() {
  local pool="$1" exclude=",$2," w names='' bad
  if [ "$pool" = all ]; then
    # Son saglik kontrolunde kotasi dolan ya da kirik olan worker aday olamaz.
    bad=",$(unhealthy_workers | cut -f1 | tr '\n' ','),"
    for w in $(enabled_workers); do
      case "$bad" in *",$w,"*) continue ;; esac
      [ "$(worker_callable "$w" 2>/dev/null || true)" = "ok" ] && names="$names $w"
    done
  fi
  jq -c --arg ex "$exclude" --arg names "$names" '
    def roles: (.role // .roles) | if type=="array" then . else [.] end;
    ($names | split(" ") | map(select(.!=""))) as $ok
    | ((.subagents // {}) | with_entries(select((.key|startswith("$")|not) and .value.enabled != false))
        | map_values({kind:"subagent", roles:roles, model, use_for:(.use_for//"")}))
      + ((.workers // {}) | with_entries(select(.key as $k | $ok | index($k)))
        | map_values({kind:"worker", roles:roles, model, use_for:(.use_for//"")}))
    | with_entries(select(.key as $k | $ex | contains(","+$k+",") | not))
  ' "$(workers_file)"
}

ROLE_TEXT='{
  "loop": "Repetitive iteration or bulk mechanical edits: rename, reformat, apply the same change many times, re-run until a check passes.",
  "implement": "Writing or changing code: new features, bug fixes, refactors, tests. The worker edits files.",
  "review": "Reading without editing: code review, security audit, verifying another worker'"'"'s output, architecture judgement, hard diagnosis."
}'

# jev_ask <govde dosyasi> <cikti dosyasi>  -> HTTP kodu stdout'a
jev_ask() {
  local body="$1" out="$2" key code
  key="$(key_get)" || die "TypeSafe anahtari yok. Kaydet: scripts/orchestra.sh jev-key set"
  # Anahtar curl'e stdin uzerinden config olarak gider; argv'de gorunmez.
  set +e
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$key" \
    | "${ORCHESTRA_JEV_CURL:-curl}" -sS --config - -X POST "$(jcfg url https://api.typesafe.ai/v1/systemone)" \
        --max-time "$(jcfg timeout_sec 30)" -H 'Content-Type: application/json' \
        --data-binary @"$body" -o "$out" -w '%{http_code}' 2>"$out.err")"
  set -e
  printf '%s' "${code:-000}"
}

# ask_choice <gorev> <soru id> <talimat> <kriter json> -> Jev cevabi (answers[qid]) ya da hata
ask_choice() {
  local text="$1" qid="$2" instr="$3" crit="$4" body resp code msg
  body="$(mktemp -t orchestra-jev)"; resp="$(mktemp -t orchestra-jev-resp)"
  jq -n --arg t "$text" --arg q "$qid" --arg i "$instr" --argjson c "$crit" --arg m "$(jcfg model jev-latest)" \
    '{state:{task:$t}, model:$m, questions:{($q):{type:"choice", instructions:$i, criteria:$c}}}' > "$body"
  code="$(jev_ask "$body" "$resp")"
  rm -f "$body"
  if [ "$code" != "200" ]; then
    msg="$(jq -r '(.detail|objects|.message) // (.detail|strings) // (.error|objects|.message) // (.error|strings) // .message // empty' "$resp" 2>/dev/null | head -c 200)"
    [ -n "$msg" ] || msg="$(head -c 200 "$resp.err" 2>/dev/null)"
    rm -f "$resp" "$resp.err"
    jq -nc --arg c "$code" --arg m "$msg" '{status:"error", http:$c, error:$m}'
    return 1
  fi
  jq -c --arg q "$qid" '.answers[$q] + {jev_model:.model}' "$resp"
  rm -f "$resp" "$resp.err"
}

# Esik havuza gore: jev.min_confidence sayi ya da {"claude":..,"all":..} olabilir.
min_conf() {
  jq -r --arg p "$1" '(.jev // {}).min_confidence as $m
    | if ($m|type)=="object" then ($m[$p] // 0.5) elif $m==null then 0.5 else $m end' "$(workers_file)"
}

# route_one: karari verir ve havuz "all" ise saglik nedeniyle disarida kalanlari kanit olarak ekler.
route_one() {
  local d rc=0
  d="$(route_decide "$@")" || rc=$?
  if [ "$2" = all ] && [ -n "$d" ]; then
    d="$(jq -c --arg u "$(unhealthy_workers | tr '\t' '=' | tr '\n' ',')" --arg age "$(health_age)" '
      . + {unhealthy_excluded: ($u|split(",")|map(select(.!=""))),
           health_age_sec: (if $age=="" then null else ($age|tonumber) end)}' <<<"$d")"
  fi
  printf '%s\n' "$d"
  return "$rc"
}

# route_decide <gorev> <havuz> <exclude> -> karar JSON'u stdout'a
# Iki atomik soru, sirayla: (1) is ne tur? (2) o turdeki adaylardan hangisi?
# Benzer worker'lar olasiligi bolup guveni dusurmesin diye ikinci soru yalnizca
# birinci cevabin rolundeki adaylari gorur.
route_decide() {
  local text="$1" pool="$2" exclude="$3" cands roles min r rc role rconf pick w
  cands="$(candidates_json "$pool" "$exclude")"
  [ "$(jq 'length' <<<"$cands")" -gt 0 ] || { jq -nc --arg p "$pool" '{status:"error",pool:$p,error:"aday yok"}'; return 1; }
  min="$(min_conf "$pool")"

  roles="$(jq -c --argjson rt "$ROLE_TEXT" '[.[].roles[]]|unique as $u | $rt|with_entries(select(.key as $k|$u|index($k)))' <<<"$cands")"
  if [ "$(jq 'length' <<<"$roles")" -eq 1 ]; then
    role="$(jq -r 'keys[0]' <<<"$roles")"; rconf=1
  else
    r="$(ask_choice "$text" role 'What kind of work does `task` ask for?' "$roles")" || { echo "$r"; return 1; }
    role="$(jq -r .choice <<<"$r")"; rconf="$(jq -r .confidence <<<"$r")"
    if jq -e --argjson m "$min" '.confidence < $m' <<<"$r" >/dev/null; then
      jq -c --arg p "$pool" --argjson m "$min" '{status:"low_confidence", stage:"role", pool:$p, min_confidence:$m,
        role:.choice, role_confidence:.confidence, role_probabilities:.probabilities, jev_model}' <<<"$r"
      return 0
    fi
  fi

  local in_role; in_role="$(jq -c --arg r "$role" 'with_entries(select(.value.roles|index($r)))' <<<"$cands")"
  [ "$(jq 'length' <<<"$in_role")" -gt 0 ] || {
    jq -nc --arg p "$pool" --arg r "$role" '{status:"error",pool:$p,role:$r,error:"bu rolde aday yok"}'; return 1; }
  if [ "$(jq 'length' <<<"$in_role")" -eq 1 ]; then
    jq -c --arg p "$pool" --arg r "$role" --argjson rc "$rconf" --argjson m "$min" \
      'keys[0] as $k | {status:"ok", pool:$p, min_confidence:$m, worker:$k, kind:.[$k].kind, model:.[$k].model,
        confidence:1, role:$r, role_confidence:$rc, note:"rolde tek aday; worker sorusu sorulmadi"}' <<<"$in_role"
    return 0
  fi

  w="$(ask_choice "$text" worker \
    "Which worker is the best fit to carry out \`task\`? The work is of kind \"$role\"; compare each worker's model and use_for." \
    "$(jq -c 'map_values({model, use_for})' <<<"$in_role")")" || { echo "$w"; return 1; }
  jq -c --argjson c "$in_role" --arg p "$pool" --arg r "$role" --argjson rc "$rconf" --argjson m "$min" '
    .choice as $k
    | {pool:$p, min_confidence:$m, worker:$k, kind:($c[$k // ""].kind), model:($c[$k // ""].model),
       confidence, probabilities, role:$r, role_confidence:$rc, jev_model}
    | .status = (if ($k|type)!="string" or ($c|has($k)|not) then "error"
                 elif .confidence < $m then "low_confidence" else "ok" end)
    | if .status=="low_confidence" then .stage="worker" else . end
  ' <<<"$w"
}

cmd_route() {
  local tasks='' out='' prompt='' exclude='' pool=all
  while (($#)); do
    case "$1" in
      --tasks)   tasks="${2:-}"; shift 2 ;;
      --out)     out="${2:-}"; shift 2 ;;
      --prompt)  prompt="${2:-}"; shift 2 ;;
      --exclude) exclude="${2:-}"; shift 2 ;;
      --pool)    pool="${2:-}"; shift 2 ;;
      *) die "route: bilinmeyen secenek: $1" ;;
    esac
  done
  case "$pool" in claude|all) ;; *) die "route: --pool claude|all olmali" ;; esac
  # CLI worker'lari yalnizca "all" havuzunda; onbellek eskiyse secimden once yenile.
  if [ "$pool" = all ] && [ "${ORCHESTRA_HEALTH_AUTO:-1}" = 1 ]; then
    "$(orc_root)/scripts/orchestra.sh" health --if-stale --quiet || warn "saglik kontrolu yenilenemedi; mevcut onbellek kullaniliyor"
  fi
  if [ -n "$prompt" ]; then
    local d; d="$(route_one "$prompt" "$pool" "$exclude")" || { echo "$d"; return 1; }
    echo "$d"; [ "$(jq -r .status <<<"$d")" = ok ] || return 2
    return 0
  fi
  [ -n "$tasks" ] || die "route: --tasks ya da --prompt zorunlu"
  [ -f "$tasks" ] && jq empty "$tasks" 2>/dev/null || die "route: gecerli bir gorev dosyasi degil: $tasks"

  local cur n i tid w text ex dec unresolved=0
  cur="$(cat "$tasks")"
  n="$(jq '.tasks|length' <<<"$cur")"
  i=0
  while [ "$i" -lt "$n" ]; do
    w="$(jq -r --argjson i "$i" '.tasks[$i].worker // "auto"' <<<"$cur")"
    if [ "$w" = "auto" ]; then
      tid="$(jq -r --argjson i "$i" '.tasks[$i].id' <<<"$cur")"
      text="$(jq -r --argjson i "$i" '.tasks[$i].prompt' <<<"$cur")"
      # Gorev bazli haric tutma: uygulayanin ailesinden inceleyici secilmesin diye.
      ex="$(jq -r --argjson i "$i" --arg g "$exclude" '[($g|split(",")[]|select(.!="")), (.tasks[$i].exclude // [])[]]|join(",")' <<<"$cur")"
      dec="$(route_one "$text" "$pool" "$ex" || true)"
      [ -n "$dec" ] || dec='{"status":"error","error":"bos yanit"}'
      if [ "$(jq -r .status <<<"$dec")" = ok ]; then
        cur="$(jq --argjson i "$i" --argjson d "$dec" '.tasks[$i].worker = $d.worker | .tasks[$i].routing = $d' <<<"$cur")"
        log "$tid -> $(jq -r '.worker+" ["+.kind+"] (confidence "+(.confidence|tostring)+")"' <<<"$dec")"
      else
        cur="$(jq --argjson i "$i" --argjson d "$dec" '.tasks[$i].worker = "auto" | .tasks[$i].routing = $d' <<<"$cur")"
        warn "$tid atanamadi: $(jq -c '{status,stage,worker,confidence,role,role_confidence,error}|with_entries(select(.value!=null))' <<<"$dec")"
        unresolved=$((unresolved+1))
      fi
    fi
    i=$((i+1))
  done
  if [ -n "$out" ]; then printf '%s\n' "$cur" > "$out"; log "yazildi: $out"
  else printf '%s\n' "$cur"; fi
  [ "$unresolved" -eq 0 ] || { warn "$unresolved gorev 'auto' kaldi; karari orkestrator vermeli."; return 2; }
}

sub="${1:-}"; [ $# -gt 0 ] && shift || true
case "$sub" in
  key)   cmd_key "$@" ;;
  route) cmd_route "$@" ;;
  ''|--help|-h) usage ;;
  *) usage >&2; exit 64 ;;
esac
