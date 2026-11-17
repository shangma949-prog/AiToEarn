import { readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '../..')
const require = createRequire(resolve(root, 'project/aitoearn-backend/package.json'))
const YAML = require('yaml')

function readEnv(path) {
  const env = {}
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#'))
      continue
    const index = trimmed.indexOf('=')
    if (index === -1)
      continue
    env[trimmed.slice(0, index)] = trimmed.slice(index + 1)
  }
  return env
}

function required(env, key) {
  const value = env[key]
  if (!value)
    throw new Error(`Missing ${key} in secrets file`)
  return value
}

const runtimeDir = process.argv[2]
if (!runtimeDir)
  throw new Error('Usage: node render-config.mjs <runtime-dir>')

const env = readEnv(resolve(runtimeDir, 'secrets.env'))
const mongoUser = encodeURIComponent(required(env, 'MONGO_USERNAME'))
const mongoPassword = encodeURIComponent(required(env, 'MONGO_PASSWORD'))
const mongoUri = `mongodb://${mongoUser}:${mongoPassword}@127.0.0.1:27017/?authSource=admin&replicaSet=rs0`
const redisPassword = required(env, 'REDIS_PASSWORD')
const authSecret = required(env, 'AUTH_SECRET')
const internalToken = required(env, 'INTERNAL_TOKEN')
const rustfsKey = required(env, 'RUSTFS_ACCESS_KEY')
const rustfsSecret = required(env, 'RUSTFS_SECRET_KEY')

function applyStorage(config) {
  config.auth.secret = authSecret
  config.auth.internalToken = internalToken
  config.redis.host = '127.0.0.1'
  config.redis.password = redisPassword
  config.redlock.redis.host = '127.0.0.1'
  config.redlock.redis.password = redisPassword
  config.mongodb.uri = mongoUri
  config.assets.endpoint = 'http://127.0.0.1:9000'
  config.assets.publicEndpoint = 'http://rustfs.local:9000'
  config.assets.cdnEndpoint = 'http://rustfs.local:9000/aitoearn'
  config.assets.accessKeyId = rustfsKey
  config.assets.secretAccessKey = rustfsSecret
  config.assets.forcePathStyle = true
  config.assets.provider = 's3'
}

const backend = resolve(root, 'project/aitoearn-backend')
const server = YAML.parse(readFileSync(resolve(backend, 'apps/aitoearn-server/config/config.yaml'), 'utf8'))
applyStorage(server)
server.environment = 'development'
server.appDomain = 'localhost'
server.channel.channelDb.uri = mongoUri
server.channel.douyin.status = 'available'
server.aiClient.baseUrl = 'http://127.0.0.1:3010'
server.aiClient.token = internalToken
delete server.relay

const ai = YAML.parse(readFileSync(resolve(backend, 'apps/aitoearn-ai/config/config.yaml'), 'utf8'))
applyStorage(ai)
ai.appDomain = 'localhost'
ai.serverClient.baseUrl = 'http://127.0.0.1:3002'

writeFileSync(resolve(backend, 'apps/aitoearn-server/config/local.config.yaml'), YAML.stringify(server))
writeFileSync(resolve(backend, 'apps/aitoearn-ai/config/local.config.yaml'), YAML.stringify(ai))
writeFileSync(resolve(runtimeDir, 'server.local.config.yaml'), YAML.stringify(server))
writeFileSync(resolve(runtimeDir, 'ai.local.config.yaml'), YAML.stringify(ai))
console.log('rendered local configs without printing secrets')
