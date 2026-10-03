// The language model behind the agents.
//
//   ANTHROPIC_API_KEY set  -> Claude through the official SDK
//   AI_PROVIDER=fake       -> deterministic answers for tests and demos
//   neither                -> agents are unavailable (the CRM works as before)
//
// Every call asks for JSON that matches a schema (structured outputs), so the
// agents never parse free text. Cost is computed from token use with the
// prices below (USD per million tokens) and charged to the company's budget.
import Anthropic from '@anthropic-ai/sdk';

export const MODEL = process.env.AI_MODEL || 'claude-opus-5-5';
const PRICE_IN = Number(process.env.AI_PRICE_INPUT_PER_MTOK || 4);
const PRICE_OUT = Number(process.env.AI_PRICE_OUTPUT_PER_MTOK || 20);

export class AgentError extends Error {}

export function costUsd(usage) {
    return ((usage.input_tokens || 0) * PRICE_IN + (usage.output_tokens || 0) * PRICE_OUT) / 1e6;
}

let client;
const anthropic = {
    name: 'anthropic',
    model: MODEL,
    // { system, user, schema, maxTokens, effort } -> { data, usage, model }
    async complete({ system, user, schema, maxTokens = 8000, effort = 'medium' }) {
        client ||= new Anthropic();
        let res;
        try {
            res = await client.beta.messages.create({
                model: MODEL,
                max_tokens: maxTokens,
                // If the model declines, the API retries on Anthropic's recommended fallback model.
                betas: ['server-side-fallback-2026-07-01'],
                fallbacks: 'default',
                thinking: { type: 'adaptive' },
                output_config: { effort, format: { type: 'json_schema', schema } },
                system,
                messages: [{ role: 'user', content: user }],
            });
        } catch (err) {
            if (err instanceof Anthropic.APIError) throw new AgentError(`AI service error (${err.status ?? 'network'}): ${err.message}`);
            throw err;
        }
        const usage = {
            input_tokens: (res.usage.input_tokens || 0) + (res.usage.cache_creation_input_tokens || 0)
                + (res.usage.cache_read_input_tokens || 0),
            output_tokens: res.usage.output_tokens || 0,
        };
        if (res.stop_reason === 'refusal') throw Object.assign(new AgentError('The AI declined this request.'), { usage });
        if (res.stop_reason === 'max_tokens') throw Object.assign(new AgentError('The AI answer was cut off.'), { usage });
        const text = res.content.filter((b) => b.type === 'text').map((b) => b.text).join('');
        try {
            return { data: JSON.parse(text), usage, model: res.model };
        } catch {
            throw Object.assign(new AgentError('The AI returned an unreadable answer.'), { usage });
        }
    },
};

// Deterministic stand-in: each agent supplies `fake(input)` that builds an
// answer from the same facts the model would see.
const fake = {
    name: 'fake',
    model: 'fake-model',
    async complete({ fake: make, input }) {
        if (!make) throw new AgentError('No fake answer for this agent.');
        return { data: make(input), usage: { input_tokens: 1000, output_tokens: 200 }, model: 'fake-model' };
    },
};

export function getLlm() {
    if (process.env.AI_PROVIDER === 'fake') return fake;
    if (process.env.ANTHROPIC_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN) return anthropic;
    return null;
}
