import { describe, expect, it } from 'vitest';
import { assertModelIsOffered } from '../src/setup/verifySteps.js';

// Ollama lists "josi-qwen3.5-9b:latest" and the setup page suggests "josi-qwen3.5-9b".
// They are the same model, and setup must not refuse the one it suggested itself.
const ollamaList = async () =>
  new Response(JSON.stringify({ object: 'list', data: [{ id: 'josi-qwen3.5-9b:latest', object: 'model', owned_by: 'library' }] }), {
    status: 200, headers: { 'content-type': 'application/json' },
  });

describe('a model Ollama lists with :latest', () => {
  const base = { provider: 'openai_compatible', baseUrl: 'http://127.0.0.1:11434/v1', fetchImpl: ollamaList as unknown as typeof fetch, resolve: async () => ['127.0.0.1'] };

  it('is offered under the bare name', async () => {
    expect(await assertModelIsOffered({ ...base, model: 'josi-qwen3.5-9b' })).toEqual({ ok: true });
  });
  it('is offered under the full name', async () => {
    expect(await assertModelIsOffered({ ...base, model: 'josi-qwen3.5-9b:latest' })).toEqual({ ok: true });
  });
  it('still refuses a model that is not listed', async () => {
    const res = await assertModelIsOffered({ ...base, model: 'something-else' });
    expect(res.ok).toBe(false);
  });
});
