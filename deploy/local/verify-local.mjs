import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '../..')
const require = createRequire(resolve(root, 'project/aitoearn-backend/package.json'))
const { MongoClient } = require('mongodb')
const jwt = require('jsonwebtoken')
const Redis = require('ioredis')

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

const runtimeDir = process.argv[2] || process.env.AITOEARN_RUNTIME
if (!runtimeDir)
  throw new Error('Usage: node verify-local.mjs <runtime-dir>')

const env = readEnv(resolve(runtimeDir, 'secrets.env'))
const apiBase = process.env.AITOEARN_API_BASE || 'http://127.0.0.1:3002'
const mongoUri = `mongodb://${encodeURIComponent(env.MONGO_USERNAME)}:${encodeURIComponent(env.MONGO_PASSWORD)}@127.0.0.1:27017/?authSource=admin&replicaSet=rs0`
const results = []

function record(name, ok, detail) {
  results.push({ name, ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`)
  if (!ok)
    console.log(JSON.stringify(detail))
}

async function api(path, { method = 'GET', token, body } = {}) {
  const response = await fetch(apiBase + path, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await response.text()
  let json
  try {
    json = JSON.parse(text)
  }
  catch {
    json = text
  }
  return { status: response.status, json }
}

function publishableUrl(url) {
  return url.replace('://127.0.0.1:', '://rustfs.local:').replace('://localhost:', '://rustfs.local:')
}

const health = await api('/health')
record('server.health', health.status === 200 && health.json === 'OK', { status: health.status })
const aiHealth = await fetch('http://127.0.0.1:3010/health').then(async response => ({
  status: response.status,
  body: await response.text(),
})).catch(error => ({ status: 0, body: String(error) }))
record('ai.health', aiHealth.status === 200 && aiHealth.body.trim() === 'OK', { status: aiHealth.status })

const mongo = new MongoClient(mongoUri)
await mongo.connect()
const db = mongo.db('aitoearn')
const now = new Date()
const mail = 'local-verify@aitoearn.local'
let user = await db.collection('user').findOne({ mail, isDelete: { $ne: true } })
if (!user) {
  const inserted = await db.collection('user').insertOne({
    name: 'Local Verify',
    mail,
    status: 1,
    userType: 'CREATOR',
    isDelete: false,
    score: 0,
    usedStorage: 0,
    storage: { total: 524288000 },
    locale: 'zh-CN',
    createdAt: now,
    updatedAt: now,
  })
  user = { _id: inserted.insertedId }
}
const token = jwt.sign(
  { id: user._id.toString(), mail, name: 'Local Verify' },
  env.AUTH_SECRET,
  { expiresIn: '2h' },
)

const mine = await api('/user/mine', { token })
record('user.mine', mine.json?.code === 0 && mine.json?.data?.mail === mail, { code: mine.json?.code })

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64')
const sign = await api('/assets/uploadSign', {
  method: 'POST',
  token,
  body: { filename: 'verify.png', type: 'userMedia', size: png.length },
})
const uploadUrl = sign.json?.data?.uploadUrl
const assetUrl = sign.json?.data?.url
const assetId = sign.json?.data?.id
record('asset.sign', Boolean(uploadUrl && assetId), { code: sign.json?.code })
if (uploadUrl) {
  const put = await fetch(uploadUrl, {
    method: 'PUT',
    headers: { 'Content-Type': 'image/png', 'Content-Length': String(png.length) },
    body: png,
  })
  record('asset.put', put.status >= 200 && put.status < 300, { status: put.status })
}
if (assetId) {
  const confirmed = await api(`/assets/${assetId}/confirm`, { method: 'POST', token, body: {} })
  record('asset.confirm', confirmed.json?.code === 0, { code: confirmed.json?.code, assetStatus: confirmed.json?.data?.status })
}

const draftGroup = await api('/material/group', {
  method: 'POST',
  token,
  body: { type: 'article', name: '验证草稿箱', desc: '本地验证', platforms: ['douyin'] },
})
const draftGroupId = draftGroup.json?.data?.id || draftGroup.json?.data?._id
const draft = draftGroupId
  ? await api('/material', {
      method: 'POST',
      token,
      body: {
        groupId: draftGroupId,
        title: '验证草稿',
        desc: '脚本创建的本地草稿',
        type: 'article',
        accountTypes: ['douyin'],
        mediaList: [{ url: assetUrl, type: 'img' }],
      },
    })
  : null
const draftId = draft?.json?.data?.id || draft?.json?.data?._id
record('draft.create', Boolean(draftId), { code: draft?.json?.code })
const listed = draftGroupId
  ? await api(`/material/list/1/10?groupId=${draftGroupId}`, { token })
  : null
record('draft.list', (listed?.json?.data?.total ?? 0) >= 1, { total: listed?.json?.data?.total, code: listed?.json?.code })

const accountGroup = await api('/v2/channels/account-groups', {
  method: 'POST',
  token,
  body: { name: '验证分组' },
})
const groupId = accountGroup.json?.data?.id || accountGroup.json?.data?._id
record('accountGroup.create', Boolean(groupId), { code: accountGroup.json?.code })

const douyinAccountId = `verify-douyin-${user._id.toString()}`
const biliAccountId = `verify-bilibili-${user._id.toString()}`
if (groupId) {
  await db.collection('account').deleteMany({ _id: { $in: [douyinAccountId, biliAccountId] } })
  await db.collection('account').insertMany([
    { _id: douyinAccountId, userId: user._id.toString(), type: 'douyin', uid: 'verify-douyin-uid', nickname: '验证抖音', status: 1, groupId, createdAt: now, updatedAt: now },
    { _id: biliAccountId, userId: user._id.toString(), type: 'bilibili', uid: 'verify-bilibili-uid', nickname: '验证B站', status: 1, groupId, createdAt: now, updatedAt: now },
  ])
}
const accounts = await api('/v2/channels/accounts', { token })
record('accounts.list', accounts.json?.code === 0, { code: accounts.json?.code, message: accounts.json?.message })

const publishAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString()
const mediaUrl = assetUrl ? publishableUrl(assetUrl) : ''
const flow = mediaUrl
  ? await api('/v2/channels/publish/flows', {
      method: 'POST',
      token,
      body: {
        publishAt,
        content: { title: '验证排期', body: '只落库，不进入发布队列', media: [{ url: mediaUrl }] },
        items: [{ platform: 'douyin', accountId: douyinAccountId, option: { private_status: 1 } }],
      },
    })
  : null
const task = flow?.json?.data?.tasks?.[0]
record('schedule.record', flow?.json?.code === 0 && task?.status === 0 && !task?.platformWorkId, {
  code: flow?.json?.code,
  message: flow?.json?.message,
  status: task?.status,
  hasWorkId: Boolean(task?.platformWorkId),
})

const redis = new Redis({
  host: '127.0.0.1',
  port: 6379,
  password: env.REDIS_PASSWORD,
})
let queueKeys = []
if (task?.id) {
  let cursor = '0'
  do {
    const [next, batch] = await redis.scan(cursor, 'MATCH', `*publish-${task.id}*`, 'COUNT', 100)
    cursor = next
    queueKeys = queueKeys.concat(batch)
  } while (cursor !== '0')
}
record('schedule.notQueued', Boolean(task?.id) && queueKeys.length === 0, {
  taskIdPresent: Boolean(task?.id),
  queueKeyCount: queueKeys.length,
})
const queued = await api('/v2/channels/publish/records/queued', { token })
const queuedRows = Array.isArray(queued.json?.data) ? queued.json.data : (queued.json?.data?.list || [])
const queuedRow = queuedRows.find(item => item?.id === task?.id)
record('schedule.recordIsNotBullJob', queued.json?.code === 0 && queuedRow?.status === 0 && queueKeys.length === 0, {
  code: queued.json?.code,
  recordStatus: queuedRow?.status,
  queueKeyCount: queueKeys.length,
})

const bili = mediaUrl
  ? await api('/v2/channels/publish/flows', {
      method: 'POST',
      token,
      body: {
        publishAt,
        content: { title: '验证B站', body: '图片 #验证', media: [{ url: mediaUrl }] },
        items: [{ platform: 'bilibili', accountId: biliAccountId, option: { tid: 21, copyright: 1 } }],
      },
    })
  : null
record('bilibili.imageRejectedLocally', bili?.json?.code === 15051, { code: bili?.json?.code })

await redis.quit()
await mongo.close()
const failed = results.filter(item => !item.ok)
console.log(`SUMMARY ${results.length - failed.length}/${results.length}`)
if (failed.length)
  process.exitCode = 1
