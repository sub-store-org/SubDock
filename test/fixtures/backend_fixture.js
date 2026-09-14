const http = require('node:http');

const mode = process.env.TEST_BACKEND_MODE || 'healthy';
const mergeEnabled = process.env.SUB_STORE_BACKEND_MERGE !== 'false';
const backendPrefixEnabled = Boolean(process.env.SUB_STORE_BACKEND_PREFIX);
const configuredPath = process.env.SUB_STORE_FRONTEND_BACKEND_PATH === '/'
  ? ''
  : process.env.SUB_STORE_FRONTEND_BACKEND_PATH || '';
const frontendBackendPath = mergeEnabled || backendPrefixEnabled
  ? configuredPath
  : '';

console.log('fixture stdout');
console.error('fixture stderr');
console.log(`data path:${process.env.SUB_STORE_DATA_BASE_PATH}`);

if (mode === 'crash') {
  process.exitCode = 1;
} else {
  let keepAlive;
  const server = http.createServer((request, response) => {
    if (request.url !== `${frontendBackendPath}/api/utils/env`) {
      response.statusCode = 404;
      response.end();
      return;
    }
    if (mode === 'stall') {
      response.writeHead(200, { 'content-type': 'application/json' });
      return;
    }
    response.setHeader('content-type', 'application/json');
    response.end(
      JSON.stringify({
        data: {
          version: 'fixture-backend',
          meta: { node: { version: process.version } },
        },
      }),
    );
  });

  server.listen(process.env.SUB_STORE_BACKEND_API_PORT, '127.0.0.1');
  process.on('SIGTERM', () => {
    clearInterval(keepAlive);
    if (!server.listening) {
      process.exit(0);
      return;
    }
    server.close(() => process.exit(0));
  });

  if (mode === 'unhealthy') {
    setTimeout(() => {
      server.close();
      keepAlive = setInterval(() => {}, 1000);
    }, 100);
  }
}
