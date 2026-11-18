const fs = require('node:fs')
const path = require('node:path')
const Module = require('node:module')

const backendRoot = path.resolve(__dirname, '../../project/aitoearn-backend')
const distLibs = path.join(backendRoot, 'dist/libs')
const originalResolve = Module._resolveFilename

function distEntry(request) {
  if (!request.startsWith('@yikart/'))
    return null
  const rest = request.slice('@yikart/'.length)
  const slash = rest.indexOf('/')
  const name = slash === -1 ? rest : rest.slice(0, slash)
  const sub = slash === -1 ? '' : rest.slice(slash + 1)
  const base = path.join(distLibs, name, 'src', sub)
  const candidates = sub
    ? [base + '.js', path.join(base, 'index.js')]
    : [path.join(base, 'index.js')]
  return candidates.find(candidate => fs.existsSync(candidate)) || null
}

Module._resolveFilename = function resolveYikartDist(request, parent, isMain, options) {
  const mapped = distEntry(request)
  if (mapped)
    return mapped
  return originalResolve.call(this, request, parent, isMain, options)
}
