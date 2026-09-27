// st-tts-shim — StepFun TTS → OpenAI 兼容 /v1/audio/speech 薄适配层
// 零依赖。原版随 D:\orca\.scratch 一起被磁盘清理误删（2026-09-26/27），
// 本文件按留存的行为契约重建：启动横幅 / env 面 / /health / 退出文案逐字对齐原日志。
//   行为依据：D:\service-manager\logs\TTSShim.out.log（原启动横幅）
//             memory: st-tts-shim-hosting-and-sighup-2026-09-20
//                     st-tts-shim-chain-launch-and-task-selfheal-2026-09-21
//                     astrbot-stepfun-tts-2026-09-24（StepFun API 契约）
//
// env:
//   PORT              监听端口（默认 8001）
//   TTS_BASE          上游 base（默认 https://api.stepfun.com/step_plan/v1）
//   TTS_MODEL         缺省 model（默认 stepaudio-2.5-tts）
//   TTS_DEFAULT_VOICE 请求未带 voice 时的缺省音色（默认 lengyanyujie）
//   TTS_AUTH_STYLE    上游鉴权风格（默认 bearer）
//   TTS_API_KEY       上游密钥（或 STEPFUN_API_KEY），缺失拒绝启动
//
// nssm 服务 TTSShim：AppDirectory 指向本目录，AppEnvironmentExtra 注入 TTS_API_KEY。

import http from 'node:http';

const PORT = Number(process.env.PORT || 8001);
const HOST = process.env.HOST || '127.0.0.1';
const TTS_BASE = (process.env.TTS_BASE || 'https://api.stepfun.com/step_plan/v1').replace(/\/+$/, '');
const TTS_MODEL = process.env.TTS_MODEL || 'stepaudio-2.5-tts';
const TTS_DEFAULT_VOICE = process.env.TTS_DEFAULT_VOICE || 'lengyanyujie';
const TTS_AUTH_STYLE = (process.env.TTS_AUTH_STYLE || 'bearer').toLowerCase();
const API_KEY = process.env.TTS_API_KEY || process.env.STEPFUN_API_KEY || '';

const UPSTREAM_URL = `${TTS_BASE}/audio/speech`;
const UPSTREAM_TIMEOUT_MS = Number(process.env.TTS_TIMEOUT_MS || 120_000);

if (!API_KEY) {
  console.error('[shim] 缺少 TTS_API_KEY（或 STEPFUN_API_KEY）环境变量，拒绝启动。');
  process.exit(1);
}

function authHeader() {
  if (TTS_AUTH_STYLE === 'bearer') return `Bearer ${API_KEY}`;
  return API_KEY; // 其他风格：原样放 key（预留）
}

function logExit(reason) {
  const mem = process.memoryUsage();
  const rss = Math.round(mem.rss / 1024 / 1024);
  const heap = Math.round(mem.heapUsed / 1024 / 1024);
  console.log(`[shim] 进程退出 code=0 rss=${rss}MB heap=${heap}MB (${reason})`);
}

process.on('exit', () => {
  // exit 回调里只做同步输出；rss/heap 在这里取仍有效
  try { logExit('exit'); } catch { /* 忽略 */ }
});
process.on('SIGHUP', () => {
  console.log('[shim] 收到 SIGHUP，主动退出');
  process.exit(0);
});
process.on('SIGINT', () => {
  console.log('[shim] 收到 SIGINT，主动退出');
  process.exit(0);
});
process.on('uncaughtException', (err) => {
  console.error('[shim] 未捕获异常：', err?.stack || err);
  process.exit(1);
});

function readBody(req, limit = 1 << 20) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function handleSpeech(req, res) {
  const raw = await readBody(req);
  let body;
  try {
    body = JSON.parse(raw || '{}');
  } catch {
    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: 'request body is not valid JSON', type: 'invalid_request_error' } }));
    return;
  }
  // 缺省填充：model / voice 用本机默认（OpenAI 兼容调用方常省略其一）
  if (!body.model) body.model = TTS_MODEL;
  if (!body.voice) body.voice = TTS_DEFAULT_VOICE;

  const upstream = await fetch(UPSTREAM_URL, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'authorization': authHeader(),
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });

  // 上游错误原样透传（401/402/400 等让调用方看到真实原因）
  if (!upstream.ok) {
    const text = await upstream.text().catch(() => '');
    console.error(`[shim] 上游 ${upstream.status} ${body.model} voice=${body.voice} body=${text.slice(0, 200)}`);
    res.writeHead(upstream.status, { 'content-type': upstream.headers.get('content-type') || 'application/json' });
    res.end(text);
    return;
  }

  const headers = { 'content-type': upstream.headers.get('content-type') || 'audio/mpeg' };
  const cd = upstream.headers.get('content-disposition');
  if (cd) headers['content-disposition'] = cd;
  res.writeHead(upstream.status, headers);

  if (upstream.body) {
    for await (const chunk of upstream.body) res.write(Buffer.from(chunk));
  }
  res.end();
}

const server = http.createServer(async (req, res) => {
  const path = (req.url || '/').split('?')[0];
  try {
    if (req.method === 'GET' && (path === '/health' || path === '/')) {
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('ok');
      return;
    }
    if (req.method === 'POST' && (path === '/v1/audio/speech' || path === '/audio/speech')) {
      await handleSpeech(req, res);
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('not found');
  } catch (err) {
    const status = err?.message === 'body too large' ? 413 : 502;
    console.error(`[shim] ${req.method} ${path} 失败：`, err?.message || err);
    if (!res.headersSent) res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(String(err?.message || err));
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[shim] 就绪  http://${HOST}:${PORT}/v1/audio/speech`);
  console.log(`[shim] 上游  ${UPSTREAM_URL}   鉴权 ${TTS_AUTH_STYLE}   默认音色 ${TTS_DEFAULT_VOICE}`);
});
