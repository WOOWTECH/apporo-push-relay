'use strict';

const { Writable } = require('stream');
const { loggerConfig } = require('../fastify-logger');

test('request logs do not record the client IP address or User-Agent', async () => {
  const lines = [];
  const stream = new Writable({
    write(chunk, encoding, callback) {
      lines.push(chunk.toString());
      callback();
    },
  });
  const fastify = require('fastify')({ logger: { ...loggerConfig, stream }, trustProxy: true });
  fastify.get('/api/checkRateLimits', async () => ({ ok: true }));

  await fastify.inject({
    method: 'GET',
    url: '/api/checkRateLimits',
    remoteAddress: '203.0.113.9',
    headers: { 'user-agent': 'UA-SENTINEL', 'x-forwarded-for': '198.51.100.7' },
  });
  await fastify.close();

  const output = lines.join('');
  expect(output).toContain('/api/checkRateLimits');
  expect(output).not.toContain('203.0.113.9');
  expect(output).not.toContain('198.51.100.7');
  expect(output).not.toContain('UA-SENTINEL');
});
