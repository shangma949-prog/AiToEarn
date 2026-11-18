#!/usr/bin/env bash
# 单一入口：start | stop | restart | status | check
# 日志、pid、口令只放在 deploy/local/.runtime，该目录已 gitignore。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME="${AITOEARN_RUNTIME:-$ROOT/deploy/local/.runtime}"
LOG_DIR="$RUNTIME/logs"
PID_DIR="$RUNTIME/pids"
COMPOSE_FILE="$ROOT/deploy/local/docker-compose.infra.yml"
BACKEND="$ROOT/project/aitoearn-backend"
WEB="$ROOT/project/aitoearn-web"
CMD="${1:-status}"
shift || true

mkdir -p "$LOG_DIR" "$PID_DIR"
umask 077

random_token() {
  openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-48
}

ensure_secrets() {
  if [[ ! -f "$RUNTIME/secrets.env" ]]; then
    cat > "$RUNTIME/secrets.env" <<EOF
AUTH_SECRET=$(random_token)
INTERNAL_TOKEN=$(random_token)
MONGO_USERNAME=aitoearn
MONGO_PASSWORD=$(random_token)
REDIS_PASSWORD=$(random_token)
RUSTFS_ACCESS_KEY=aitoearn$(random_token | cut -c1-8)
RUSTFS_SECRET_KEY=$(random_token)
EOF
    echo "created runtime secrets"
  fi
  set -a
  # shellcheck disable=SC1090
  source "$RUNTIME/secrets.env"
  set +a
}

require_hosts() {
  if ! getent hosts rustfs.local >/dev/null; then
    echo "把这一行写入 /etc/hosts 后再启动: 127.0.0.1 rustfs.local"
    exit 1
  fi
}

port_open() {
  local port="$1"
  ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
}

wait_http() {
  local url="$1"
  local name="$2"
  local i
  for i in $(seq 1 90); do
    if curl -fsS -m 2 "$url" >/dev/null 2>&1; then
      echo "$name ready"
      return 0
    fi
    sleep 2
  done
  echo "$name 未在限时内就绪，查看 $LOG_DIR"
  return 1
}

restrict_port() {
  local port="$1"
  if command -v iptables >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo iptables -C INPUT -p tcp --dport "$port" ! -s 127.0.0.1 -j DROP 2>/dev/null \
      || sudo iptables -I INPUT -p tcp --dport "$port" ! -s 127.0.0.1 -j DROP
    if command -v ip6tables >/dev/null 2>&1; then
      sudo ip6tables -C INPUT -p tcp --dport "$port" ! -s ::1 -j DROP 2>/dev/null \
        || sudo ip6tables -I INPUT -p tcp --dport "$port" ! -s ::1 -j DROP || true
    fi
  fi
}

start_infra() {
  if sudo docker ps --format '{{.Names}}' | grep -qx 'aitoearn-mongodb'; then
    echo "infra containers already running"
  else
    sudo docker compose --env-file "$RUNTIME/secrets.env" -f "$COMPOSE_FILE" up -d
  fi
  local i
  for i in $(seq 1 40); do
    if sudo docker exec aitoearn-mongodb mongosh "mongodb://${MONGO_USERNAME}:${MONGO_PASSWORD}@127.0.0.1:27017/?authSource=admin" --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  sudo docker exec aitoearn-mongodb mongosh "mongodb://${MONGO_USERNAME}:${MONGO_PASSWORD}@127.0.0.1:27017/?authSource=admin" --quiet --eval "try { rs.initiate({_id:'rs0', members:[{_id:0, host:'127.0.0.1:27017'}]}) } catch(e) { if (e.codeName!=='AlreadyInitialized') throw e }" >/dev/null
  (
    cd "$BACKEND"
    node --input-type=module <<'JS'
import { CreateBucketCommand, HeadBucketCommand, PutBucketCorsCommand, PutBucketPolicyCommand, S3Client } from '@aws-sdk/client-s3'
const client = new S3Client({
  region: 'us-east-1',
  endpoint: 'http://127.0.0.1:9000',
  forcePathStyle: true,
  credentials: {
    accessKeyId: process.env.RUSTFS_ACCESS_KEY,
    secretAccessKey: process.env.RUSTFS_SECRET_KEY,
  },
})
try {
  await client.send(new HeadBucketCommand({ Bucket: 'aitoearn' }))
} catch {
  await client.send(new CreateBucketCommand({ Bucket: 'aitoearn' }))
}
await client.send(new PutBucketPolicyCommand({
  Bucket: 'aitoearn',
  Policy: JSON.stringify({
    Version: '2012-10-17',
    Statement: [{ Effect: 'Allow', Principal: '*', Action: ['s3:GetObject'], Resource: ['arn:aws:s3:::aitoearn/*'] }],
  }),
}))
await client.send(new PutBucketCorsCommand({
  Bucket: 'aitoearn',
  CORSConfiguration: {
    CORSRules: [{
      AllowedOrigins: ['http://127.0.0.1:6061', 'http://localhost:6061'],
      AllowedMethods: ['GET', 'PUT', 'POST', 'HEAD', 'DELETE'],
      AllowedHeaders: ['*'],
      ExposeHeaders: ['ETag'],
      MaxAgeSeconds: 3000,
    }],
  },
}))
JS
  )
}

render_config_if_needed() {
  local server_cfg="$BACKEND/apps/aitoearn-server/config/local.config.yaml"
  local ai_cfg="$BACKEND/apps/aitoearn-ai/config/local.config.yaml"
  if [[ ! -f "$server_cfg" || ! -f "$ai_cfg" || "${FORCE_RENDER:-0}" == 1 ]]; then
    node "$ROOT/deploy/local/render-config.mjs" "$RUNTIME"
  fi
}

ensure_web_token() {
  local user_id
  user_id="$(
    cd "$BACKEND"
    node --input-type=module -e '
      import { createRequire } from "node:module"
      const { MongoClient } = createRequire(process.cwd() + "/package.json")("mongodb")
      const user = encodeURIComponent(process.env.MONGO_USERNAME)
      const pass = encodeURIComponent(process.env.MONGO_PASSWORD)
      const client = new MongoClient(`mongodb://${user}:${pass}@127.0.0.1:27017/?authSource=admin&replicaSet=rs0`)
      await client.connect()
      const db = client.db("aitoearn")
      const mail = "local-web@aitoearn.local"
      let row = await db.collection("user").findOne({ mail, isDelete: { $ne: true } })
      if (!row) {
        const inserted = await db.collection("user").insertOne({
          name: "Local Web",
          mail,
          status: 1,
          userType: "CREATOR",
          isDelete: false,
          score: 0,
          usedStorage: 0,
          storage: { total: 524288000 },
          locale: "zh-CN",
          createdAt: new Date(),
          updatedAt: new Date(),
        })
        row = { _id: inserted.insertedId }
      }
      await client.close()
      process.stdout.write(row._id.toString())
    '
  )"
  local token
  token="$(
    cd "$BACKEND"
    node --input-type=module -e '
      import { createRequire } from "node:module"
      const jwt = createRequire(process.cwd() + "/package.json")("jsonwebtoken")
      process.stdout.write(jwt.sign({ id: process.argv[1], mail: "local-web@aitoearn.local", name: "Local Web" }, process.env.AUTH_SECRET, { expiresIn: "12h" }))
    ' "$user_id"
  )"
  cat > "$RUNTIME/web.env" <<EOF
AUTO_LOGIN_TOKEN=${token}
NEXT_PUBLIC_API_URL=http://127.0.0.1:7080
NEXT_PUBLIC_EVN=dev
BIND_HOST=127.0.0.1
EOF
  chmod 600 "$RUNTIME/web.env"
}

start_bg() {
  local name="$1"
  local dir="$2"
  shift 2
  if [[ -f "$PID_DIR/$name.pid" ]] && kill -0 "$(cat "$PID_DIR/$name.pid")" 2>/dev/null; then
    echo "$name already running"
    return 0
  fi
  (
    cd "$dir"
    if [[ -f "$RUNTIME/web.env" ]]; then
      set -a
      # shellcheck disable=SC1090
      source "$RUNTIME/web.env"
      set +a
    fi
    export BIND_HOST="${BIND_HOST:-127.0.0.1}"
    export CI=1 NX_DAEMON=false NX_TUI=false NX_NO_CLOUD=true NX_ISOLATE_PLUGINS=false
    nohup "$@" >> "$LOG_DIR/$name.log" 2>&1 &
    echo $! > "$PID_DIR/$name.pid"
  )
  echo "started $name pid $(cat "$PID_DIR/$name.pid") log $LOG_DIR/$name.log"
}

start_apps() {
  render_config_if_needed
  restrict_port 3002
  restrict_port 3010
  restrict_port 6061
  restrict_port 7080
  if ! port_open 3002; then
    if [[ -f "$BACKEND/dist/apps/aitoearn-server/src/main.js" && "${AITOEARN_DEV:-0}" != 1 ]]; then
      start_bg server "$BACKEND" node -r "$ROOT/deploy/local/register-dist.cjs" dist/apps/aitoearn-server/src/main.js -c apps/aitoearn-server/config/local.config.yaml
    else
      start_bg server "$BACKEND" pnpm exec nx serve aitoearn-server --configuration=local
    fi
  else
    echo "server port already open"
  fi
  if ! port_open 3010; then
    if [[ -f "$BACKEND/dist/apps/aitoearn-ai/src/main.js" && "${AITOEARN_DEV:-0}" != 1 ]]; then
      start_bg ai "$BACKEND" node -r "$ROOT/deploy/local/register-dist.cjs" dist/apps/aitoearn-ai/src/main.js -c apps/aitoearn-ai/config/local.config.yaml
    else
      start_bg ai "$BACKEND" pnpm exec nx serve aitoearn-ai --configuration=local
    fi
  else
    echo "ai port already open"
  fi
  wait_http http://127.0.0.1:3002/health server
  wait_http http://127.0.0.1:3010/health ai
  if ! port_open 7080; then
    start_bg proxy "$ROOT" node "$ROOT/deploy/local/api-proxy.mjs"
  fi
  wait_http http://127.0.0.1:7080/health proxy
  ensure_web_token
  if ! port_open 6061; then
    if [[ -f "$WEB/.next/standalone/server.js" && "${AITOEARN_DEV:-0}" != 1 ]]; then
      start_bg web "$WEB/.next/standalone" env PORT=6061 HOSTNAME=127.0.0.1 node server.js
    else
      start_bg web "$WEB" pnpm exec next dev -H 127.0.0.1 -p 6061
    fi
  fi
  wait_http http://127.0.0.1:6061/zh-CN web
}

stop_pid() {
  local name="$1"
  local pidfile="$PID_DIR/$name.pid"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

stop_port() {
  local port="$1"
  local pids
  pids="$(ss -ltnp | awk -v p=":$port" '$4 ~ p {print}' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | sort -u)"
  local pid
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
}

cmd_stop() {
  local keep_infra=1
  if [[ "${1:-}" == "--all" ]]; then
    keep_infra=0
  fi
  stop_port 6061
  stop_port 7080
  stop_port 3010
  stop_port 3002
  stop_pid web
  stop_pid proxy
  stop_pid ai
  stop_pid server
  pkill -f 'nx serve aitoearn-server' 2>/dev/null || true
  pkill -f 'nx serve aitoearn-ai' 2>/dev/null || true
  pkill -f 'next dev -H 127.0.0.1 -p 6061' 2>/dev/null || true
  pkill -f 'api-proxy.mjs' 2>/dev/null || true
  sleep 1
  stop_port 6061
  stop_port 7080
  stop_port 3010
  stop_port 3002
  if [[ "$keep_infra" == 0 ]]; then
    sudo docker compose --env-file "$RUNTIME/secrets.env" -f "$COMPOSE_FILE" stop || true
  fi
  echo "stopped"
}

cmd_status() {
  echo "runtime $RUNTIME"
  echo "logs $LOG_DIR"
  curl -fsS -m 2 -o /dev/null -w 'server %{http_code}\n' http://127.0.0.1:3002/health || echo 'server down'
  curl -fsS -m 2 -o /dev/null -w 'ai %{http_code}\n' http://127.0.0.1:3010/health || echo 'ai down'
  curl -fsS -m 2 -o /dev/null -w 'proxy %{http_code}\n' http://127.0.0.1:7080/health || echo 'proxy down'
  curl -fsS -m 3 -o /dev/null -w 'web %{http_code}\n' http://127.0.0.1:6061/zh-CN || echo 'web down'
  sudo docker ps --format '{{.Names}} {{.Status}}' | grep aitoearn || echo 'no infra containers'
  ss -ltn | awk 'NR==1 || /3002|3010|6061|7080|27017|6379|9000/'
}

cmd_check() {
  cd "$BACKEND"
  node --input-type=module <<'JS'
import { createRequire } from 'node:module'
const require = createRequire(process.cwd() + '/package.json')
const { MongoClient } = require('mongodb')
const user = encodeURIComponent(process.env.MONGO_USERNAME)
const pass = encodeURIComponent(process.env.MONGO_PASSWORD)
const client = new MongoClient(`mongodb://${user}:${pass}@127.0.0.1:27017/?authSource=admin&replicaSet=rs0`)
await client.connect()
const db = client.db('aitoearn')
const draft = await db.collection('material').findOne({ title: '页面合成草稿', isDelete: { $ne: true } })
const mediaCount = await db.collection('media').countDocuments({})
const materialCount = await db.collection('material').countDocuments({})
let coverStatus = 0
let coverBytes = 0
if (draft?.coverUrl) {
  const coverUrl = String(draft.coverUrl).startsWith('http')
    ? draft.coverUrl
    : `http://127.0.0.1:9000/aitoearn/${String(draft.coverUrl).replace(/^\/+/, '')}`
  const response = await fetch(coverUrl)
  coverStatus = response.status
  coverBytes = (await response.arrayBuffer()).byteLength
}
const jwt = require('jsonwebtoken')
const token = jwt.sign(
  { id: String(draft?.userId || ''), mail: 'synthetic-admin@aitoearn.local', name: 'Synthetic Admin' },
  process.env.AUTH_SECRET,
  { expiresIn: '10m' },
)
let apiListed = false
if (draft?.groupId) {
  const listed = await fetch(`http://127.0.0.1:3002/material/list/1/10?groupId=${draft.groupId}`, {
    headers: { Authorization: `Bearer ${token}` },
  }).then(response => response.json())
  apiListed = listed?.code === 0 && (listed.data?.list || []).some(item => item.title === '页面合成草稿')
}
console.log(JSON.stringify({
  materialCount,
  mediaCount,
  draftFound: Boolean(draft),
  draftTitle: draft?.title || null,
  coverStatus,
  coverBytes,
  apiListed,
}))
await client.close()
if (!draft || coverStatus !== 200 || coverBytes < 1 || !apiListed) process.exit(1)
JS
}

sample_loop() {
  local out="$1"
  : > "$out"
  while [[ -f "$RUNTIME/sampling" ]]; do
    awk -v ts="$(date +%s)" '/MemAvailable/ {printf "%s mem_available_kb %s\n", ts, $2}' /proc/meminfo >> "$out"
    sleep 2
  done
}

cmd_start() {
  require_hosts
  ensure_secrets
  if [[ ! -d "$BACKEND/node_modules" ]]; then
    (cd "$BACKEND" && pnpm install --frozen-lockfile)
  fi
  if [[ ! -d "$WEB/node_modules" ]]; then
    (cd "$WEB" && pnpm install --frozen-lockfile)
  fi
  touch "$RUNTIME/sampling"
  sample_loop "$LOG_DIR/mem-sample.log" &
  local sampler=$!
  start_infra
  start_apps
  rm -f "$RUNTIME/sampling"
  wait "$sampler" || true
  echo "open http://127.0.0.1:6061/zh-CN"
}

case "$CMD" in
  start) cmd_start ;;
  stop) cmd_stop "$@" ;;
  restart)
    cmd_stop "$@"
    cmd_start
    ;;
  status) cmd_status ;;
  check) ensure_secrets; cmd_check ;;
  *)
    echo "usage: $0 start|stop|restart|status|check"
    exit 2
    ;;
esac
