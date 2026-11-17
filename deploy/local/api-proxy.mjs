import http from 'node:http'

const listenHost = '127.0.0.1'
const listenPort = Number(process.env.API_PROXY_PORT || 7080)
const serverPort = Number(process.env.AITOEARN_SERVER_PORT || 3002)
const aiPort = Number(process.env.AITOEARN_AI_PORT || 3010)

function targetPort(url) {
  if (url === '/ai' || url.startsWith('/ai/') || url === '/agent' || url.startsWith('/agent/'))
    return aiPort
  return serverPort
}

const server = http.createServer((req, res) => {
  const url = req.url || '/'
  const port = targetPort(url)
  const headers = { ...req.headers, host: `${listenHost}:${port}` }
  const proxyReq = http.request({
    hostname: listenHost,
    port,
    path: url,
    method: req.method,
    headers,
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode || 502, proxyRes.headers)
    proxyRes.pipe(res)
  })
  proxyReq.on('error', (error) => {
    if (!res.headersSent)
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' })
    res.end(error instanceof Error ? error.message : String(error))
  })
  req.pipe(proxyReq)
})

server.listen(listenPort, listenHost, () => {
  console.log(`api proxy http://${listenHost}:${listenPort} -> server:${serverPort} ai:${aiPort}`)
})
