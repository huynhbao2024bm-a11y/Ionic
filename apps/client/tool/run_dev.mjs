import { spawn } from 'node:child_process';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const clientRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const flutterHost = '127.0.0.1';
const flutterPort = Number(process.env.IONIC_FLUTTER_WEB_PORT ?? 4201);
const proxyHost = '127.0.0.1';
const proxyPort = Number(process.env.IONIC_WEB_PORT ?? 4200);
const apiPort = Number(process.env.IONIC_API_PORT ?? 3001);
for (const [name, port] of [
  ['IONIC_FLUTTER_WEB_PORT', flutterPort],
  ['IONIC_WEB_PORT', proxyPort],
  ['IONIC_API_PORT', apiPort],
]) {
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`${name} must be an integer between 1 and 65535.`);
  }
}
if (flutterPort === proxyPort) {
  throw new Error('IONIC_FLUTTER_WEB_PORT and IONIC_WEB_PORT must be different.');
}

const flutterCommand = process.env.FLUTTER_BIN ?? 'flutter';
const flutterArgs = [
  'run',
  '-d', 'web-server',
  '--web-hostname', flutterHost,
  '--web-port', String(flutterPort),
];
const spawnOptions = {
  cwd: clientRoot,
  stdio: 'inherit',
  windowsHide: true,
  windowsVerbatimArguments: process.platform === 'win32',
};

// Flutter is a .bat launcher on Windows, so start it through cmd.exe without
// enabling Node's shell option for all arguments.
const flutter = process.platform === 'win32'
  ? spawn(
      process.env.ComSpec ?? 'cmd.exe',
      ['/d', '/s', '/c', `""${flutterCommand}" ${flutterArgs.join(' ')}"`],
      spawnOptions,
    )
  : spawn(flutterCommand, flutterArgs, spawnOptions);

let shuttingDown = false;
const server = http.createServer((request, response) => {
  const targetPort = request.url?.startsWith('/api/') || request.url === '/api' ? apiPort : flutterPort;
  const upstream = http.request({
    hostname: '127.0.0.1',
    port: targetPort,
    method: request.method,
    path: request.url,
    headers: { ...request.headers, host: `127.0.0.1:${targetPort}` },
  }, (upstreamResponse) => {
    response.writeHead(upstreamResponse.statusCode ?? 502, upstreamResponse.headers);
    upstreamResponse.pipe(response);
  });

  upstream.on('error', () => {
    if (response.headersSent) {
      response.destroy();
      return;
    }
    response.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end(targetPort === apiPort
      ? `Ionic API chưa chạy trên cổng ${apiPort}.`
      : 'Flutter Web chưa sẵn sàng. Kiểm tra log của Flutter.');
  });
  request.pipe(upstream);
});

function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  server.close();
  if (flutter.exitCode === null) flutter.kill();
}

flutter.on('error', (error) => {
  console.error(`Không chạy được Flutter SDK: ${error.message}`);
  shutdown();
  process.exitCode = 1;
});
flutter.on('exit', (code) => {
  if (!shuttingDown && code !== 0) process.exitCode = code ?? 1;
  shutdown();
});
server.on('error', (error) => {
  console.error(`Không mở được cổng ${proxyPort}: ${error.message}`);
  shutdown();
  process.exitCode = 1;
});

server.listen(proxyPort, proxyHost, () => {
  console.log(`Ionic Flutter: http://${proxyHost}:${proxyPort}`);
  console.log(`API proxy:     http://${proxyHost}:${proxyPort}/api -> http://127.0.0.1:${apiPort}/api`);
});

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
