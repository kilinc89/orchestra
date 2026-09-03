#!/usr/bin/env bash
# Tek bir worker'i calistirir ve normalize edilmis result.json uretir.
#
# Iki engine desteklenir:
#   codex -> OpenAI Codex CLI (JSONL event akisi)  : native  (ChatGPT OAuth)
#   agy   -> Antigravity CLI  (tek JSON nesnesi)   : agy     (kendi auth'u)
# Harici saglayici / API key yolu YOK.
#
# Tasarim kurallari:
#   1) Exit koduna GUVENILMEZ. codex, turn.failed'da bile 0 doner; agy timeout'ta
#      status=ERROR yazar. Basari daima ciktidan cikarilir.
#   2) stdout ve stderr asla birlestirilmez; hata mesaji worker ciktisi gibi gorunmez.
#   3) Calisan model dogrulanamiyorsa "unverified" yazilir, ASLA varsayilmaz.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

worker=''; task_id=''; prompt_file=''; out_dir=''; work_dir=''; schema_file=''
add_dirs=(); timeout_sec=''

while (($#)); do
  case "$1" in
    --worker)      worker="${2:-}"; shift 2 ;;
    --task-id)     task_id="${2:-}"; shift 2 ;;
    --prompt-file) prompt_file="${2:-}"; shift 2 ;;
    --out-dir)     out_dir="${2:-}"; shift 2 ;;
    --cd)          work_dir="${2:-}"; shift 2 ;;
    --add-dir)     add_dirs+=("${2:-}"); shift 2 ;;
    --schema)      schema_file="${2:-}"; shift 2 ;;
    --timeout)     timeout_sec="${2:-}"; shift 2 ;;
    *) die "dispatch: bilinmeyen secenek: $1" ;;
  esac
done

[ -n "$worker" ]      || die "dispatch: --worker zorunlu"
[ -n "$task_id" ]     || die "dispatch: --task-id zorunlu"
[ -n "$prompt_file" ] || die "dispatch: --prompt-file zorunlu"
[ -n "$out_dir" ]     || die "dispatch: --out-dir zorunlu"
[ -f "$prompt_file" ] || die "dispatch: prompt dosyasi yok: $prompt_file"

emit_result() {  # status, model_verified, error, exit_code, duration, bytes, thread
  jq -n --arg t "$task_id" --arg w "$worker" --arg s "$1" \
        --arg mr "${model:-}" --arg mv "$2" --arg rt "${route:-}" --arg en "${engine:-}" \
        --arg err "$3" --arg th "$7" \
        --argjson ec "$4" --argjson dur "$5" --argjson bytes "$6" \
    '{task_id:$t,worker:$w,status:$s,route:$rt,engine:$en,
      model_requested:(if $mr=="" then null else $mr end),
      model_verified:(if $mv=="" then null else $mv end),
      exit_code:$ec,duration_ms:$dur,output_bytes:$bytes,
      thread_id:(if $th=="" then null else $th end),
      error:(if $err=="" then null else $err end)}' > "$out_dir/result.json"
}

mkdir -p "$out_dir"
reason="$(worker_callable "$worker" || true)"
if [ "$reason" != "ok" ]; then
  emit_result "unavailable" "" "$reason" null 0 0 ""
  log "$task_id: worker '$worker' cagrilamiyor ($reason)"
  exit 3
fi

route="$(wcfg "$worker" route)"; [ -n "$route" ] || route="$(dcfg route)"
engine="$(rcfg "$route" engine)"
model="$(wcfg "$worker" model)"
sandbox="$(dcfg sandbox)"
[ -n "$timeout_sec" ] || timeout_sec="$(dcfg timeout_sec)"

raw="$out_dir/raw.out"; errlog="$out_dir/stderr.log"; last="$out_dir/last.txt"
: > "$raw"; : > "$errlog"; : > "$last"

started="$(now_ms)"; exit_code=0

if [ "$engine" = "codex" ]; then
  args=(exec --json --skip-git-repo-check --ephemeral -s "$sandbox" -m "$model" -o "$last")
  [ "$sandbox" = "danger-full-access" ] && args+=(--dangerously-bypass-approvals-and-sandbox)
  [ -n "$work_dir" ] && args+=(-C "$work_dir")
  [ -n "$schema_file" ] && args+=(--output-schema "$schema_file")
  if ((${#add_dirs[@]})); then for d in "${add_dirs[@]}"; do args+=(--add-dir "$d"); done; fi
  set +e; codex "${args[@]}" - < "$prompt_file" > "$raw" 2> "$errlog"; exit_code=$?; set -e

  fail_msg="$(jq -rs '[.[]|select(.type=="turn.failed")|.error.message//""]|first//""' "$raw" 2>/dev/null || echo '')"
  [ -n "$fail_msg" ] || fail_msg="$(jq -rs '[.[]|select(.type=="error")|.message//""]|first//""' "$raw" 2>/dev/null || echo '')"
  completed="$(jq -rs '[.[]|select(.type=="turn.completed")]|length' "$raw" 2>/dev/null || echo 0)"
  thread_id="$(jq -rs '[.[]|select(.type=="thread.started")|.thread_id//""]|first//""' "$raw" 2>/dev/null || echo '')"
  model_verified="$(jq -rs '[..|objects|select(has("model"))|.model|select(type=="string")]|first//""' "$raw" || echo '')"

elif [ "$engine" = "agy" ]; then
  # agy prompt'u argüman olarak alir ve -C yerine cwd kullanir.
  args=(--print "$(cat "$prompt_file")" --model "$model"
        --output-format json --print-timeout "${timeout_sec}s"
        --disable-slash-commands)
  [ "$sandbox" = "danger-full-access" ] && args+=(--dangerously-skip-permissions)
  [ -n "$schema_file" ] && args+=(--json-schema "$schema_file")
  if ((${#add_dirs[@]})); then for d in "${add_dirs[@]}"; do args+=(--add-dir "$d"); done; fi
  set +e
  ( [ -n "$work_dir" ] && cd "$work_dir"; agy "${args[@]}" ) > "$raw" 2> "$errlog"
  exit_code=$?; set -e

  agy_status="$(jq -r '.status//""' "$raw" 2>/dev/null || echo '')"
  fail_msg="$(jq -r '.error//""' "$raw" 2>/dev/null || echo '')"
  thread_id="$(jq -r '.conversation_id//""' "$raw" 2>/dev/null || echo '')"
  # jq -r bos string icin bile newline basar; printf ile ham yaz ki bos gercekten 0 byte olsun.
  printf '%s' "$(jq -r '.response//""' "$raw" 2>/dev/null || true)" > "$last"
  # agy JSON'unda calisan model geri donmuyor -> dogrulanamaz, uydurulmaz.
  model_verified=''
  completed=0
  [ -n "$agy_status" ] && [ "$agy_status" != "ERROR" ] && completed=1
  [ -n "$fail_msg" ] || { [ "$agy_status" = "ERROR" ] && fail_msg="agy status=ERROR"; }
  # token kullanimini sakla
  jq -c '.usage//{}' "$raw" > "$out_dir/usage.json" 2>/dev/null || true
else
  emit_result "unavailable" "" "bilinmeyen engine: $engine" null 0 0 ""
  die "dispatch: bilinmeyen engine '$engine'"
fi

ended="$(now_ms)"
[ -n "${model_verified:-}" ] || model_verified='unverified'
output_bytes=0; [ -f "$last" ] && output_bytes="$(wc -c < "$last" | tr -d ' ')"

if [ -n "${fail_msg:-}" ]; then
  status='failed'
elif [ "${completed:-0}" -gt 0 ] && [ "$output_bytes" -gt 0 ]; then
  status='ok'
elif [ "$exit_code" -ne 0 ]; then
  status='failed'; fail_msg="$engine exit $exit_code; stderr: $(tail -c 400 "$errlog" 2>/dev/null || true)"
else
  status='empty'; fail_msg='tamamlandi ama cikti bos'
fi

emit_result "$status" "$model_verified" "${fail_msg:-}" "$exit_code" "$((ended-started))" "$output_bytes" "${thread_id:-}"
log "$task_id [$worker/$model via $engine] -> $status ($(( (ended-started)/1000 ))s, ${output_bytes}B)"
[ "$status" = "ok" ] || exit 1
exit 0
