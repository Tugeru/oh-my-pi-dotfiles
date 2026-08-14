/**
 * Kie.ai native Gemini (google-generative-ai) compatibility for omp.
 *
 * Kie serves Gemini bodies at:
 *   POST https://api.kie.ai/gemini/v1/models/{id}:streamGenerateContent
 * with Authorization: Bearer <key> (not X-Goog-Api-Key alone).
 *
 * Two quirks vs Google's official API, fixed here at the fetch layer:
 * 1. The streamed candidate chunks carry no `finishReason` (the stream ends
 *    with usage + `[DONE]`), so omp's Google adapter throws "Google API stream
 *    ended without a finish reason". omp's readSseJson returns at `[DONE]`,
 *    so we drop that sentinel and inject a synthetic STOP candidate in its
 *    place — the adapter sees the finishReason and finalizes normally.
 * 2. omp routes native Gemini by the pi-facing model id, which uses a
 *    `-google` suffix to stay distinct from the OpenAI-body entries
 *    (e.g. `gemini-3-7-flash-google`). Kie only knows the API id
 *    (`gemini-3-7-flash`), so we rewrite the URL path segment.
 *
 * Thinking: omp's `google-level` mode maps minimal → `thinkingLevel: MINIMAL`,
 * which Kie's proxy rejects with HTTP 500. The models.yml google-body entries
 * therefore declare `efforts: [low, medium, high]` (minimal clamps to low);
 * no runtime override is needed here.
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const KIE_GEMINI_STREAM_RE = /\/api\.kie\.ai\/gemini\/v1\/models\/[^:]+:streamGenerateContent/i;
const DONE_LINE_RE = /^\s*(?:data:\s*)?\[DONE\]\s*$/i;
// Kie often omits finishReason on streamed candidates; omp requires one to finalize.
const SYNTHETIC_STOP_EVENT =
	'data: {"candidates":[{"finishReason":"STOP","content":{"role":"model","parts":[]}}]}\n\n';

let fetchPatched = false;

function urlOf(input: RequestInfo | URL): string {
	return typeof input === "string"
		? input
		: input instanceof URL
			? input.href
			: input.url;
}

function isKieGeminiSseUrl(input: RequestInfo | URL): boolean {
	return KIE_GEMINI_STREAM_RE.test(urlOf(input));
}

/** `models/gemini-3-7-flash-google:streamGenerateContent` → `models/gemini-3-7-flash:...`. */
function rewriteKieGeminiUrl(url: string): string {
	return url.replace(
		/\/models\/([^/:]+)-google(:streamGenerateContent)/i,
		"/models/$1$2",
	);
}

function lineHasFinishReason(line: string): boolean {
	if (!line.startsWith("data:")) return false;
	const payload = line.slice(5).trim();
	if (!payload || payload[0] !== "{") return false;
	try {
		const parsed = JSON.parse(payload) as {
			candidates?: Array<{ finishReason?: string }>;
		};
		return Boolean(parsed.candidates?.some((c) => c.finishReason));
	} catch {
		return false;
	}
}

/**
 * Wrap the response body for a Kie Gemini SSE stream: drop the `[DONE]`
 * sentinel (omp's readSseJson returns at it, so anything injected after is
 * never parsed) and inject a synthetic STOP candidate at close when Kie
 * never sent a finishReason.
 */
function installKieGeminiFetchFix(): void {
	if (fetchPatched) return;
	fetchPatched = true;

	const originalFetch = globalThis.fetch.bind(globalThis);
	globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
		const url = urlOf(input);
		const isKie = isKieGeminiSseUrl(input);
		const rewrittenUrl = isKie ? rewriteKieGeminiUrl(url) : url;
		const response = await originalFetch(rewrittenUrl, init);
		if (!isKie || !response.body) {
			return response;
		}

		const reader = response.body.getReader();
		const decoder = new TextDecoder();
		const encoder = new TextEncoder();
		let buffer = "";
		let sawFinishReason = false;

		const enqueueLines = (
			controller: ReadableStreamDefaultController<Uint8Array>,
			lines: string[],
		) => {
			let out = "";
			for (const line of lines) {
				if (DONE_LINE_RE.test(line)) continue; // replaced by synthetic STOP at close
				if (lineHasFinishReason(line)) {
					sawFinishReason = true;
				}
				out += `${line}\n`;
			}
			if (out.length > 0) {
				controller.enqueue(encoder.encode(out));
			}
		};

		const finalize = (controller: ReadableStreamDefaultController<Uint8Array>) => {
			if (buffer) {
				enqueueLines(controller, buffer.split(/\r?\n/));
				buffer = "";
			}
			if (!sawFinishReason) {
				controller.enqueue(encoder.encode(SYNTHETIC_STOP_EVENT));
			}
			controller.close();
		};

		const stream = new ReadableStream<Uint8Array>({
			async pull(controller) {
				const { done, value } = await reader.read();
				if (done) {
					finalize(controller);
					return;
				}

				buffer += decoder.decode(value, { stream: true });
				const lines = buffer.split(/\r?\n/);
				buffer = lines.pop() ?? "";
				enqueueLines(controller, lines);
			},
			cancel(reason) {
				return reader.cancel(reason);
			},
		});

		return new Response(stream, {
			status: response.status,
			statusText: response.statusText,
			headers: response.headers,
		});
	};
}

export default function (_pi: ExtensionAPI) {
	installKieGeminiFetchFix();
}
