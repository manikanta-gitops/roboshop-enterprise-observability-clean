import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const port = 18082;
let child;

async function waitForHealth() {
  for (let i = 0; i < 30; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/health`);
      if (response.status === 200) return response.json();
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('cart service did not become healthy');
}

test.before(async () => {
  child = spawn(process.execPath, ['server.js'], {
    cwd: new URL('..', import.meta.url).pathname,
    env: { ...process.env, USER_SERVER_PORT: String(port), MONGO_URL: 'mongodb://127.0.0.1:27099/users', REDIS_URL: 'redis://127.0.0.1:6399', JWT_SECRET: 'test-access-secret', JWT_REFRESH_SECRET: 'test-refresh-secret' },
    stdio: 'ignore'
  });
});

test('health endpoint responds while dependency is unavailable', async () => {
  const body = await waitForHealth();
  assert.equal(body.app, 'OK');
  assert.equal(body.mongo, false);
});

test.after(() => child?.kill('SIGTERM'));
