#!/usr/bin/env bash
# Orchestra - Claude orkestre eder; codex (GPT-5.6) ve agy (Gemini) worker calisir.
# Alt komutlar: preflight | workers | run | loop
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

ROOT="$(orc_root)"

usage() {
  cat <<'USAGE'
Kullanim:
  orchestra.sh preflight [--workspace DIR]
  orchestra.sh workers
  orchestra.sh doctor [--worker W]
  orchestra.sh run   --tasks FILE [--workspace DIR] [--max-iter N] [--accept CMD] [--force]
  orchestra.sh loop  --worker W --prompt TEXT --until CMD [--workspace DIR] [--max-iter N] [--force]

  doctor         her worker'a GERCEK bir ping atar. 'workers' yalnizca config
                 kontrolu yapar; doctor calisan yolu kanitlar. Ucret harcar.

  --tasks FILE   gorev grafigi JSON: {"objective":"...","tasks":[{"id","worker","prompt","cd"?}]}
  --accept CMD   kabul kriteri. Cikis 0 ise is bitti; degilse dongu bir tur daha doner.
  --max-iter N   ust sinir (varsayilan 3). Sinirsiz dongu yok.
  --force        kirli/versiyonsuz workspace'te tam yetkiyi zorla.
USAGE
}

# --- git korumasi: tam yetki modunda kaza onleme (--force ile gecersiz) ---
guard_workspace() {
  local ws="$1" force="$2" sandbox
  sandbox="$(dcfg sandbox)"
  [ "$sandbox" = "danger-full-access" ] || return 0
  [ "$force" = "1" ] && { warn "--force: git korumasi atlandi."; return 0; }

  if ! git -C "$ws" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "'$ws' bir git deposu degil. Tam yetkili worker'lar geri alinamaz yazma yapar.
     Coz: (cd '$ws' && git init && git add -A && git commit -m baseline)  ya da  --force"
  fi
  # Orchestra'nin kendi kosu dizini workspace'i kirletmemeli, yoksa ikinci run
  # daima "kirli" diye reddedilir. .git/info/exclude repo-yerel; kullanicinin
  # .gitignore dosyasina dokunmaz ve commit edilmez.
  local gitdir excl
  gitdir="$(git -C "$ws" rev-parse --git-dir 2>/dev/null)"
  case "$gitdir" in /*) ;; *) gitdir="$ws/$gitdir" ;; esac
  excl="$gitdir/info/exclude"
  if [ -d "$gitdir/info" ] || mkdir -p "$gitdir/info" 2>/dev/null; then
    grep -qxF '.orchestra/' "$excl" 2>/dev/null || echo '.orchestra/' >> "$excl"
  fi
  if [ -n "$(git -C "$ws" status --porcelain 2>/dev/null)" ]; then
    die "'$ws' kirli. Worker ciktisi kendi degisikliklerinle karisir ve geri alamazsin.
     Coz: commit/stash et, ya da  --force"
  fi
  log "git korumasi gecti: $(git -C "$ws" rev-parse --abbrev-ref HEAD) @ $(git -C "$ws" rev-parse --short HEAD)"
}

cmd_workers() {
  printf '%-14s %-6s %-10s %-24s %-8s %s\n' WORKER ACIK ROL MODEL CLI 'CAGRILABILIR'
  local w r
  for w in $(jq -r '.workers|keys[]' "$(workers_file)"); do
    r="$(wcfg "$w" route)"; [ -n "$r" ] || r="$(dcfg route)"
    printf '%-14s %-6s %-10s %-24s %-8s %s\n' \
      "$w" "$(wcfg "$w" enabled)" "$(wcfg "$w" role)" "$(wcfg "$w" model)" \
      "$(rcfg "$r" engine)" "$(worker_callable "$w" || true)"
  done
}

cmd_preflight() {
  local ws="${1:-$PWD}" ok=0
  echo "== Orchestra preflight =="
  for c in codex agy jq git python3; do
    if command -v "$c" >/dev/null 2>&1; then printf '  [OK]  %s\n' "$c"
    else printf '  [--]  %s eksik\n' "$c"; ok=1; fi
  done
  printf '  [%s]  codex-cli %s\n' "$( [ -n "$(command -v codex)" ] && echo OK || echo -- )" "$(codex --version 2>/dev/null | awk '{print $2}')"
  if [ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ]; then printf '  [OK]  codex girisi var\n'
  else printf '  [--]  codex girisi YOK -> codex login\n'; ok=1; fi
  if command -v agy >/dev/null 2>&1 && [ -d "$HOME/.antigravity" ]; then
    printf '  [OK]  agy %s\n' "$(agy --version 2>/dev/null | head -1)"
  else printf '  [--]  agy yok/yapilandirilmamis -> gemini worker'"'"'lari calismaz\n'; ok=1; fi
  echo "-- workspace: $ws"
  if git -C "$ws" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -z "$(git -C "$ws" status --porcelain)" ]; then echo "  [OK]  git deposu, temiz"
    else echo "  [--]  git deposu ama KIRLI (tam yetki modunda run reddedilir)"; fi
  else echo "  [--]  git deposu DEGIL (tam yetki modunda run reddedilir)"; fi
  echo "-- worker'lar"; cmd_workers
  return $ok
}

# --- paralel fan-out: bash 3.2'de "wait -n" yok, tum PID'ler beklenir ---
run_round() {
  local tasks_file="$1" round_dir="$2" ws="$3"
  local n i tid worker prompt tcd pids=() tids=()
  n="$(jq -r '.tasks|length' "$tasks_file")"
  local maxp; maxp="$(dcfg max_parallel)"; [ -n "$maxp" ] || maxp=4

  i=0
  while [ "$i" -lt "$n" ]; do
    tid="$(jq -r --argjson i "$i" '.tasks[$i].id' "$tasks_file")"
    worker="$(jq -r --argjson i "$i" '.tasks[$i].worker' "$tasks_file")"
    tcd="$(jq -r --argjson i "$i" '.tasks[$i].cd // empty' "$tasks_file")"
    [ -n "$tcd" ] || tcd="$ws"
    mkdir -p "$round_dir/$tid"
    jq -r --argjson i "$i" '.tasks[$i].prompt' "$tasks_file" > "$round_dir/$tid/prompt.txt"

    "$ROOT/scripts/dispatch.sh" --worker "$worker" --task-id "$tid" \
      --prompt-file "$round_dir/$tid/prompt.txt" --out-dir "$round_dir/$tid" --cd "$tcd" &
    pids+=($!); tids+=("$tid")

    # throttle
    while [ "${#pids[@]}" -ge "$maxp" ]; do
      wait "${pids[0]}" 2>/dev/null || true
      pids=(${pids[@]:1})
    done
    i=$((i+1))
  done
  if ((${#pids[@]})); then for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done; fi

  jq -s '{results:.}' $(find "$round_dir" -name result.json | sort) > "$round_dir/round.json" 2>/dev/null || echo '{"results":[]}' > "$round_dir/round.json"
}

# workers yalnizca config'e bakar. doctor gercekten cagirir: "ok" iddiasi degil kanit.
cmd_doctor() {
  local only=''
  while (($#)); do
    case "$1" in
      --worker) only="${2:-}"; shift 2 ;;
      *) die "doctor: bilinmeyen secenek: $1" ;;
    esac
  done
  local tmp; tmp="$(mktemp -d -t orchestra-doctor)"
  printf '%s' 'Reply with exactly one word: PONG' > "$tmp/p.txt"
  printf '%-14s %-8s %-10s %s\n' WORKER SONUC SURE DETAY
  local w rc st dur err
  for w in $(enabled_workers); do
    [ -z "$only" ] || [ "$only" = "$w" ] || continue
    local why; why="$(worker_callable "$w" 2>/dev/null || true)"
    if [ "$why" != "ok" ]; then
      printf '%-14s %-8s %-10s %s\n' "$w" "ATLANDI" "-" "$why"
      continue
    fi
    mkdir -p "$tmp/$w"
    set +e
    "$ROOT/scripts/dispatch.sh" --worker "$w" --task-id "$w" \
      --prompt-file "$tmp/p.txt" --out-dir "$tmp/$w" >/dev/null 2>&1
    rc=$?
    set -e
    st="$(jq -r .status "$tmp/$w/result.json" 2>/dev/null || echo '?')"
    dur="$(jq -r '(.duration_ms/1000|floor|tostring)+"s"' "$tmp/$w/result.json" 2>/dev/null || echo '?')"
    err="$(jq -r '.error // ""' "$tmp/$w/result.json" 2>/dev/null | head -c 70)"
    if [ "$st" = "ok" ]; then
      printf '%-14s %-8s %-10s %s\n' "$w" "CALISIR" "$dur" "$(head -c 30 "$tmp/$w/last.txt" 2>/dev/null | tr -d '\n')"
    else
      printf '%-14s %-8s %-10s %s\n' "$w" "KIRIK" "$dur" "$err"
    fi
  done
  rm -rf "$tmp"
}

cmd_run() {
  local tasks_file='' ws="$PWD" max_iter=3 accept='' force=0
  while (($#)); do
    case "$1" in
      --tasks)     tasks_file="${2:-}"; shift 2 ;;
      --workspace) ws="${2:-}"; shift 2 ;;
      --max-iter)  max_iter="${2:-}"; shift 2 ;;
      --accept)    accept="${2:-}"; shift 2 ;;
      --force)     force=1; shift ;;
      *) die "run: bilinmeyen secenek: $1" ;;
    esac
  done
  [ -n "$tasks_file" ] || die "run: --tasks zorunlu"
  [ -f "$tasks_file" ] || die "run: gorev dosyasi yok: $tasks_file"
  jq empty "$tasks_file" 2>/dev/null || die "run: --tasks gecerli JSON degil"
  ws="$(cd -- "$ws" && pwd -P)"
  guard_workspace "$ws" "$force"

  local run_id; run_id="$(date +%Y%m%d-%H%M%S)-$$"
  local run_dir="$ws/.orchestra/runs/$run_id"
  mkdir -p "$run_dir"
  cp "$tasks_file" "$run_dir/tasks.json"
  log "run $run_id -> $run_dir"

  local iter=1 cur="$run_dir/tasks.json"
  while [ "$iter" -le "$max_iter" ]; do
    log "--- iterasyon $iter/$max_iter ---"
    local rd="$run_dir/iter-$iter"; mkdir -p "$rd"
    run_round "$cur" "$rd" "$ws"

    local failed; failed="$(jq -r '[.results[]|select(.status!="ok")]|length' "$rd/round.json")"
    log "iterasyon $iter: $(jq -r '.results|length' "$rd/round.json") gorev, $failed basarisiz"

    local accept_ok=1
    if [ -n "$accept" ]; then
      log "kabul kriteri calisiyor: $accept"
      if ( cd "$ws" && eval "$accept" ) > "$rd/accept.log" 2>&1; then
        accept_ok=0; log "kabul kriteri GECTI"
      else
        log "kabul kriteri KALDI (bkz $rd/accept.log)"
      fi
    else
      [ "$failed" -eq 0 ] && accept_ok=0
    fi

    if [ "$accept_ok" -eq 0 ] && [ "$failed" -eq 0 ]; then
      jq -n --arg r "$run_id" --argjson i "$iter" \
        '{run_id:$r,status:"success",iterations:$i}' > "$run_dir/summary.json"
      log "BASARILI ($iter iterasyon). Ozet: $run_dir/summary.json"
      cat "$run_dir/summary.json"; return 0
    fi

    [ "$iter" -lt "$max_iter" ] || break

    # --- geri besleme turu: sadece basarisiz gorevler, hata kaniti eklenerek ---
    local nxt="$rd/retry-tasks.json"
    jq -s --slurpfile rr "$rd/round.json" '
      .[0] as $orig
      | ($rr[0].results | map(select(.status!="ok")) | map(.task_id)) as $bad
      | $orig
      | .tasks |= map(select(.id as $i | $bad|index($i)))
      | .tasks |= map(. + {prompt: (.prompt + "\n\n--- ONCEKI DENEME BASARISIZ ---\nBu gorev bir kez denendi ve basarisiz oldu. Hata kanitini oku, kok nedeni bul, tekrar deneme.\n")})
    ' "$cur" > "$nxt"
    local remaining; remaining="$(jq -r '.tasks|length' "$nxt")"
    if [ "$remaining" -eq 0 ]; then
      # gorevler gecti ama kabul kriteri kaldi -> hepsini yeniden calistir
      jq --arg a "$accept" '.tasks |= map(. + {prompt:(.prompt+"\n\n--- KABUL KRITERI KALDI ---\nSu komut hala basarisiz: "+$a+"\nCiktisini incele ve duzelt.\n")})' "$run_dir/tasks.json" > "$nxt"
    fi
    cur="$nxt"
    iter=$((iter+1))
  done

  jq -n --arg r "$run_id" --argjson i "$max_iter" \
    '{run_id:$r,status:"exhausted",iterations:$i}' > "$run_dir/summary.json"
  warn "iterasyon siniri doldu ($max_iter). Kanit: $run_dir"
  cat "$run_dir/summary.json"; return 1
}

cmd_loop() {
  local worker='' prompt='' until_cmd='' ws="$PWD" max_iter=5 force=0
  while (($#)); do
    case "$1" in
      --worker)    worker="${2:-}"; shift 2 ;;
      --prompt)    prompt="${2:-}"; shift 2 ;;
      --until)     until_cmd="${2:-}"; shift 2 ;;
      --workspace) ws="${2:-}"; shift 2 ;;
      --max-iter)  max_iter="${2:-}"; shift 2 ;;
      --force)     force=1; shift ;;
      *) die "loop: bilinmeyen secenek: $1" ;;
    esac
  done
  [ -n "$worker" ] || die "loop: --worker zorunlu"
  [ -n "$prompt" ] || die "loop: --prompt zorunlu"
  [ -n "$until_cmd" ] || die "loop: --until zorunlu (sinirsiz dongu yok)"
  local tmp; tmp="$(mktemp -t orchestra-loop)"
  jq -n --arg w "$worker" --arg p "$prompt" \
    '{objective:$p,tasks:[{id:"loop-1",worker:$w,prompt:$p}]}' > "$tmp"
  local args=(--tasks "$tmp" --workspace "$ws" --max-iter "$max_iter" --accept "$until_cmd")
  [ "$force" = "1" ] && args+=(--force)
  cmd_run "${args[@]}"
}

sub="${1:-}"; [ $# -gt 0 ] && shift || true
case "$sub" in
  preflight) cmd_preflight "${1:-$PWD}" ;;
  workers)   cmd_workers ;;
  doctor)    cmd_doctor "$@" ;;
  run)       cmd_run "$@" ;;
  loop)      cmd_loop "$@" ;;
  ''|--help|-h) usage ;;
  *) usage >&2; exit 64 ;;
esac
