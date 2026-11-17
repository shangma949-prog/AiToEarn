#!/usr/bin/env bash
# 在本机回环启动 AiToEarn 依赖，并生成不含入口令的本地配置。
# 口令和登录令牌只写到运行时目录，不进入 git。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME="${AITOEARN_RUNTIME:-$ROOT/deploy/local/.runtime}"
mkdir -p "$RUNTIME"
umask 077

random_token() {
  openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-48
}

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
  echo "created $RUNTIME/secrets.env"
fi

set -a
# shellcheck disable=SC1091
source "$RUNTIME/secrets.env"
set +a

if ! getent hosts rustfs.local >/dev/null; then
  echo "需要 root 把 127.0.0.1 rustfs.local 写入 /etc/hosts，发布流不接受 127.0.0.1 这种 URL。"
  exit 1
fi

docker compose --env-file "$RUNTIME/secrets.env" -f "$ROOT/deploy/local/docker-compose.infra.yml" up -d

for _ in $(seq 1 40); do
  if docker exec aitoearn-mongodb mongosh "mongodb://${MONGO_USERNAME}:${MONGO_PASSWORD}@127.0.0.1:27017/?authSource=admin" --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker exec aitoearn-mongodb mongosh "mongodb://${MONGO_USERNAME}:${MONGO_PASSWORD}@127.0.0.1:27017/?authSource=admin" --quiet --eval "try { rs.initiate({_id:'rs0', members:[{_id:0, host:'127.0.0.1:27017'}]}) } catch(e) { if (e.codeName!=='AlreadyInitialized') throw e }" >/dev/null

cd "$ROOT/project/aitoearn-backend"
if [[ ! -d node_modules ]]; then
  pnpm install --frozen-lockfile
fi
node "$ROOT/deploy/local/render-config.mjs" "$RUNTIME"

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
}
catch {
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

echo "基础设施和本地配置已就绪。接下来在两个终端执行："
echo "  cd $ROOT/project/aitoearn-backend"
echo "  CI=1 NX_DAEMON=false NX_TUI=false NX_NO_CLOUD=true pnpm exec nx serve aitoearn-server --configuration=local"
echo "  CI=1 NX_DAEMON=false NX_TUI=false NX_NO_CLOUD=true pnpm exec nx serve aitoearn-ai --configuration=local"
echo "然后运行: node $ROOT/deploy/local/verify-local.mjs $RUNTIME"

if [[ "${1:-}" == "--web" ]]; then
  node "$ROOT/deploy/local/api-proxy.mjs" > "$RUNTIME/api-proxy.log" 2>&1 &
  echo $! > "$RUNTIME/api-proxy.pid"
  cd "$ROOT/project/aitoearn-web"
  if [[ ! -d node_modules ]]; then
    pnpm install --frozen-lockfile
  fi
  USER_ID="$(node --input-type=module -e '
    import { createRequire } from "node:module"
    const { MongoClient } = createRequire(process.cwd() + "/../aitoearn-backend/package.json")("mongodb")
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
  ')"
  AUTO_LOGIN_TOKEN="$(node --input-type=module -e '
    import { createRequire } from "node:module"
    const jwt = createRequire(process.cwd() + "/../aitoearn-backend/package.json")("jsonwebtoken")
    process.stdout.write(jwt.sign({ id: process.argv[1], mail: "local-web@aitoearn.local", name: "Local Web" }, process.env.AUTH_SECRET, { expiresIn: "12h" }))
  ' "$USER_ID")"
  export AUTO_LOGIN_TOKEN
  export NEXT_PUBLIC_API_URL="http://127.0.0.1:7080"
  export NEXT_PUBLIC_EVN=dev
  echo "网页: http://127.0.0.1:6061/zh-CN  登录令牌只存在于当前进程环境。"
  exec pnpm exec next dev -H 127.0.0.1 -p 6061
fi
