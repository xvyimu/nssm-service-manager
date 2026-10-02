// tests/shim.test.mjs — server.mjs 的 node:test 回归（无网络）
// 覆盖：413 body 上限、缺 key 拒启、TTS_API_KEY_FILE 读不出时拒启不回落、上游错误透传。
// 每个测试用独立端口与独立 env，避免 node:test 默认并发撞端口；
// 「无 key」测试显式删除继承来的 TTS_API_KEY/STEPFUN_API_KEY，防止 test runner 自身环境带 key。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';

const SHIM = path.resolve('st-tts-shim/server.mjs');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'shim-test-'));

// 端口分配：从 18001 起，每个测试 +1，避免并发撞端口
let nextPort = 18001;
const port = () => nextPort++;
// 上游 mock 端口：从 19001 起
let nextUpstream = 19001;
const upstreamPort = () => nextUpstream++;

function startUpstream(port, status, body) {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(body);
    });
    srv.listen(port, '127.0.0.1', () => resolve(srv));
  });
}

// startShim：env 为要传给 shim 的环境；默认从 process.env 继承，但显式删除
// 可能泄漏的密钥变量——由调用方按需重新设。
function startShim(env) {
  const clean = { ...process.env };
  delete clean.TTS_API_KEY;
  delete clean.STEPFUN_API_KEY;
  delete clean.TTS_API_KEY_FILE;
  return spawn(process.execPath, [SHIM], {
    env: { ...clean, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function waitExit(shim) {
  let stderr = '';
  let stdout = '';
  shim.stderr.on('data', (c) => { stderr += c.toString(); });
  shim.stdout.on('data', (c) => { stdout += c.toString(); });
  return new Promise((resolve) => shim.on('exit', (code) => resolve({ code, stderr, stdout })));
}

test('TTS_API_KEY_FILE 设置但文件不存在 → 拒启，不回落 TTS_API_KEY', async () => {
  const p = port();
  // 同时提供 TTS_API_KEY：若回落，shim 会拿到 key 去 listen（不会 exit 1）。
  // 期望：忽略 TTS_API_KEY，因文件读不出而 exit 1。
  const shim = startShim({
    TTS_API_KEY_FILE: path.join(tmp, 'no-such-file'),
    TTS_API_KEY: 'fake-would-leak',
    PORT: String(p),
  });
  const { code, stderr } = await waitExit(shim);
  assert.equal(code, 1, `expected exit 1, got ${code}; stderr=${stderr}`);
  assert.match(stderr, /TTS_API_KEY_FILE 已设置但读取失败/);
  // 关键契约：不回落——日志里不应出现「回落到环境变量」这类回落动作。
  // 「不回落 TTS_API_KEY」是说明性文字，不算回落动作；只断言没有「回落到」字样。
  assert.doesNotMatch(stderr, /回落到/);
});

test('TTS_API_KEY_FILE 指向空文件 → 拒启', async () => {
  const p = port();
  const empty = path.join(tmp, 'empty-key');
  fs.writeFileSync(empty, '');
  const shim = startShim({
    TTS_API_KEY_FILE: empty,
    TTS_API_KEY: 'fake-would-leak',
    PORT: String(p),
  });
  const { code, stderr } = await waitExit(shim);
  assert.equal(code, 1);
  assert.match(stderr, /文件为空/);
  assert.doesNotMatch(stderr, /回落到/);
});

test('缺 key 拒启（无 TTS_API_KEY_FILE/TTS_API_KEY）', async () => {
  const p = port();
  const shim = startShim({ PORT: String(p) });
  const { code, stderr } = await waitExit(shim);
  assert.equal(code, 1, `expected exit 1, got ${code}; stderr=${stderr}`);
  assert.match(stderr, /缺少 TTS_API_KEY/);
});

test('TTS_API_KEY_FILE 有效 → 启动，/health 返回 ok，上游 401 透传', async (t) => {
  const p = port();
  const up = upstreamPort();
  const keyFile = path.join(tmp, 'good-key');
  fs.writeFileSync(keyFile, 'sk-test-1234');
  const upstream = await startUpstream(up, 401, JSON.stringify({ error: 'bad key' }));
  const shim = startShim({
    TTS_API_KEY_FILE: keyFile,
    TTS_BASE: `http://127.0.0.1:${up}`,
    PORT: String(p),
  });
  // 等就绪
  await new Promise((resolve, reject) => {
    let stdout = '';
    const to = setTimeout(() => reject(new Error('shim did not start in time')), 5000);
    shim.stdout.on('data', (c) => {
      stdout += c.toString();
      if (stdout.includes('就绪')) { clearTimeout(to); resolve(); }
    });
    shim.stderr.on('data', () => {}); // 不要让 stderr 触发异常
  });

  await t.test('health', async () => {
    const r = await fetch(`http://127.0.0.1:${p}/health`);
    assert.equal(r.status, 200);
    assert.equal(await r.text(), 'ok');
  });
  await t.test('upstream 401 passthrough', async () => {
    const r = await fetch(`http://127.0.0.1:${p}/v1/audio/speech`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'x', input: 'hello' }),
    });
    assert.equal(r.status, 401);
    const text = await r.text();
    assert.match(text, /bad key/);
  });
  shim.kill('SIGINT');
  await new Promise((r) => shim.on('exit', r));
  upstream.close();
});

test('body 超 1MB → 413', async () => {
  const p = port();
  const up = upstreamPort();
  const keyFile = path.join(tmp, 'big-key');
  fs.writeFileSync(keyFile, 'sk-big');
  const upstream = await startUpstream(up, 200, 'ok');
  const shim = startShim({
    TTS_API_KEY_FILE: keyFile,
    TTS_BASE: `http://127.0.0.1:${up}`,
    PORT: String(p),
  });
  await new Promise((resolve, reject) => {
    let stdout = '';
    const to = setTimeout(() => reject(new Error('shim did not start in time')), 5000);
    shim.stdout.on('data', (c) => {
      stdout += c.toString();
      if (stdout.includes('就绪')) { clearTimeout(to); resolve(); }
    });
    shim.stderr.on('data', () => {});
  });
  const big = 'x'.repeat(2 * 1024 * 1024);
  const r = await fetch(`http://127.0.0.1:${p}/v1/audio/speech`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ input: big }),
  });
  assert.equal(r.status, 413);
  shim.kill('SIGINT');
  await new Promise((r) => shim.on('exit', r));
  upstream.close();
});

test('cleanup', () => { try { fs.rmSync(tmp, { recursive: true, force: true }) } catch {} });
