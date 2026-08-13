#!/usr/bin/env bash
set -Eeuo pipefail

# QUANT NOVA G8.1 — Intraday Live Validation (READ-ONLY)
# - Does NOT restart, stop, modify, delete, chmod app data, or write into the container data directory.
# - Reads HTTP health/signal endpoints, Docker/host metrics, and SQLite state in read-only mode.
# - Default: one snapshot. For repeated sampling:
#     WATCH_MINUTES=60 INTERVAL_SEC=300 ./nova-g8-live-session-audit.sh

CONTAINER="${CONTAINER:-quant-nova}"
PORT="${PORT:-3200}"
WATCH_MINUTES="${WATCH_MINUTES:-0}"
INTERVAL_SEC="${INTERVAL_SEC:-300}"
BASE_OUT="${BASE_OUT:-/home/ubuntu/nova-live-audit}"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${BASE_OUT}/${RUN_ID}"
mkdir -p "$OUT_DIR"

log() { printf '%s\n' "$*" | tee -a "$OUT_DIR/audit.log"; }

if ! sudo docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "ERROR: container '$CONTAINER' not found"
  exit 2
fi

TOKEN="$(sudo docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^APP_ACCESS_TOKEN=//p' | head -n1 || true)"

AUTH_ARGS=()
if [ -n "${TOKEN:-}" ]; then
  AUTH_ARGS=(-H "X-App-Token: ${TOKEN}")
fi

http_get() {
  local path="$1"
  local outfile="$2"
  local code
  code="$(curl -sS -m 8 -o "$outfile.tmp" -w '%{http_code}' "${AUTH_ARGS[@]}" "http://127.0.0.1:${PORT}${path}" || true)"
  if [ -f "$outfile.tmp" ]; then mv "$outfile.tmp" "$outfile"; else : > "$outfile"; fi
  printf '%s' "$code"
}

json_summary() {
  local file="$1"
  python3 - "$file" <<'PY'
import json,sys
p=sys.argv[1]
try:
    d=json.load(open(p,encoding="utf-8"))
except Exception as e:
    print(f"JSON_PARSE_ERROR={e}")
    raise SystemExit
keys = [
    "ok","version","feed_state","state","connected","logged_in",
    "registered","registered_codes","trade_registered","last_trade_code",
    "last_trade_venue","last_error","restore_wal_error"
]
for k in keys:
    if isinstance(d,dict) and k in d:
        print(f"{k}={d[k]}")
mem=d.get("memory") if isinstance(d,dict) else None
if isinstance(mem,dict):
    for k in ("rss_mb","swap_mb","vm_mb","memory_percent"):
        if k in mem: print(f"memory.{k}={mem[k]}")
j=d.get("journal") if isinstance(d,dict) else None
if isinstance(j,dict):
    for k in ("critical_committed","critical_failed","important_committed",
              "important_enqueue_fail","db_queue_depth","db_write_latency_p95_ms",
              "db_queue_wait_p95_ms","important_write_latency_p95_ms"):
        if k in j: print(f"journal.{k}={j[k]}")
PY
}

sqlite_audit() {
  sudo docker exec -i "$CONTAINER" python - <<'PY'
import os, glob, sqlite3, json, datetime

base=os.environ.get("NOVA_DATA_DIR","/app/data")
print("DATA_DIR", base)
dbs=sorted(set(glob.glob(base+"/*.db")+glob.glob(base+"/*.sqlite")+glob.glob(base+"/*.sqlite3")))
print("DB_FILES", json.dumps(dbs, ensure_ascii=False))

def qident(s):
    return '"' + s.replace('"','""') + '"'

preferred = [
    "id","seq","trade_day","event_type","kind","state","symbol","code","name","venue",
    "provider_time","server_receive_time","created_at","ts","time","signal_time",
    "signal_price","price","current_price","score","reasons","signal_reasons",
    "repeat_count","top5_enter_count","top5_reentry_count",
    "max_return","min_return","current_return","mfe","mae","status"
]

for db in dbs:
    print("\n=== DB", db, "===")
    try:
        con=sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        con.row_factory=sqlite3.Row
        tables=[r[0] for r in con.execute("select name from sqlite_master where type='table' order by name")]
        print("TABLES", ",".join(tables))
        for t in tables:
            try:
                cnt=con.execute(f"select count(*) from {qident(t)}").fetchone()[0]
            except Exception as e:
                print("TABLE_COUNT_ERROR", t, repr(e)); continue
            if t=="formal_wal" or any(x in t.lower() for x in ("signal","performance","outcome","position","candidate","track")):
                print(f"TABLE {t} ROWS {cnt}")
                cols=[r[1] for r in con.execute(f"pragma table_info({qident(t)})")]
                chosen=[c for c in preferred if c in cols]
                if not chosen:
                    chosen=cols[:12]
                order=None
                for c in ("seq","id","created_at","ts","provider_time","signal_time"):
                    if c in cols:
                        order=c; break
                sql=f"select {','.join(qident(c) for c in chosen)} from {qident(t)}"
                if order:
                    sql+=f" order by {qident(order)} desc"
                sql+=" limit 50"
                try:
                    rows=[dict(r) for r in con.execute(sql)]
                    print("COLUMNS", ",".join(chosen))
                    for row in rows:
                        print("ROW", json.dumps(row, ensure_ascii=False, default=str))
                except Exception as e:
                    print("RECENT_ROWS_ERROR", t, repr(e))
        con.close()
    except Exception as e:
        print("DB_ERROR", db, repr(e))
PY
}

sample_once() {
  local n="$1"
  local stamp
  stamp="$(date +%Y%m%d_%H%M%S)"
  local dir="$OUT_DIR/sample_${n}_${stamp}"
  mkdir -p "$dir"

  log "===== SAMPLE $n @ $(date '+%F %T %Z') ====="

  {
    echo "DATE=$(date --iso-8601=seconds)"
    uptime
    echo
    free -h
    echo
    sudo docker inspect "$CONTAINER" \
      --format 'IMAGE={{.Config.Image}} STATUS={{.State.Status}} RUNNING={{.State.Running}} HEALTH={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} RESTARTS={{.RestartCount}} STARTED={{.State.StartedAt}}'
    echo
    sudo docker stats --no-stream "$CONTAINER"
  } > "$dir/host_and_container.txt" 2>&1

  declare -a endpoints=(
    "/api/livez"
    "/api/readyz"
    "/api/realtime-health"
    "/api/live-dashboard"
    "/api/prebuy-recommendations"
    "/api/buy-signals"
    "/api/nxt-alerts"
    "/api/nxt-signal-table"
    "/api/position-manager"
  )

  : > "$dir/http_status.txt"
  for ep in "${endpoints[@]}"; do
    fn="$(echo "$ep" | sed 's#^/##; s#[/?=&]#_#g').json"
    code="$(http_get "$ep" "$dir/$fn")"
    printf '%-32s HTTP %s\n' "$ep" "$code" | tee -a "$dir/http_status.txt" >> "$OUT_DIR/audit.log"
  done

  {
    echo "=== LIVEZ ==="
    json_summary "$dir/api_livez.json"
    echo "=== READYZ ==="
    json_summary "$dir/api_readyz.json"
    echo "=== REALTIME HEALTH ==="
    json_summary "$dir/api_realtime-health.json"
    echo "=== LIVE DASHBOARD ==="
    json_summary "$dir/api_live-dashboard.json"
  } > "$dir/key_metrics.txt" 2>&1 || true

  sqlite_audit > "$dir/sqlite_audit.txt" 2>&1 || true

  # Compact signal counts from HTTP payloads without assuming one fixed schema.
  python3 - "$dir" > "$dir/http_signal_summary.txt" <<'PY'
import json,sys,glob,os
d=sys.argv[1]
for p in sorted(glob.glob(os.path.join(d,"api_*.json"))):
    name=os.path.basename(p)
    try:
        x=json.load(open(p,encoding="utf-8"))
    except Exception:
        continue
    print(f"=== {name} ===")
    if isinstance(x,list):
        print("top_level_list_count",len(x))
    elif isinstance(x,dict):
        for k,v in x.items():
            if isinstance(v,list):
                print(f"{k}_count",len(v))
            elif isinstance(v,dict) and k in ("summary","counts","metrics"):
                print(k,json.dumps(v,ensure_ascii=False,default=str)[:2000])
PY

  log "--- KEY METRICS ---"
  cat "$dir/key_metrics.txt" | tee -a "$OUT_DIR/audit.log"
  log "--- HTTP STATUS ---"
  cat "$dir/http_status.txt" | tee -a "$OUT_DIR/audit.log"
  log "--- DOCKER STATS ---"
  tail -n 5 "$dir/host_and_container.txt" | tee -a "$OUT_DIR/audit.log"

  # Alarm-only checks; no mutation.
  if grep -Eq 'HTTP (000|4[0-9][0-9]|5[0-9][0-9])' "$dir/http_status.txt"; then
    log "ALERT=HTTP_ENDPOINT_FAILURE"
  fi
  if grep -Eq 'critical_failed=[1-9]|important_enqueue_fail=[1-9]' "$dir/key_metrics.txt"; then
    log "ALERT=JOURNAL_FAILURE"
  fi
  if grep -Eq 'memory.swap_mb=[1-9]' "$dir/key_metrics.txt"; then
    log "ALERT=CONTAINER_SWAP_NONZERO"
  fi
  if grep -q 'FORMAL_WAL=NOT_FOUND' "$dir/sqlite_audit.txt"; then
    log "ALERT=FORMAL_WAL_NOT_FOUND"
  fi
}

log "QUANT NOVA G8.1 INTRADAY AUDIT START"
log "OUT_DIR=$OUT_DIR"
log "MODE=$([ "$WATCH_MINUTES" -gt 0 ] && echo WATCH || echo ONESHOT)"
log "WATCH_MINUTES=$WATCH_MINUTES INTERVAL_SEC=$INTERVAL_SEC"

if [ "$WATCH_MINUTES" -le 0 ]; then
  sample_once 1
else
  end=$(( $(date +%s) + WATCH_MINUTES*60 ))
  i=1
  while [ "$(date +%s)" -lt "$end" ]; do
    sample_once "$i"
    i=$((i+1))
    now="$(date +%s)"
    [ "$now" -ge "$end" ] && break
    sleep "$INTERVAL_SEC"
  done
fi

log "QUANT NOVA G8.1 INTRADAY AUDIT COMPLETE"
log "RESULT_DIR=$OUT_DIR"

# Convenience latest symlink on host only.
ln -sfn "$OUT_DIR" "${BASE_OUT}/latest"
echo
echo "===== COMPLETE ====="
echo "Result: $OUT_DIR"
echo "Latest: ${BASE_OUT}/latest"
