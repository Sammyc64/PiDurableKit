// What pi-ai's OAuth errors may say about a provider's response (Quorum M0-90b): its HTTP status, a code from OAuth's
// closed set, a transport failure, or the names of fields it lacked. Never the response, its URL or a stack: a response
// can hold an access token or a device code, and a failed refresh's message is a transcript entry.
//
// build.mjs patches pi-ai's OAuth modules, `ModelsError` and its diagnostics to use these. Strict explicitly, as
// client.ts is, so the bundle is the same whichever module esbuild reaches first.
"use strict";

/** OAuth's error codes (RFC 6749 §5.2, RFC 8628 §3.5, RFC 6750 §3.1). A closed set, so one carries no provider text. */
const OAUTH_ERROR_CODES = [
	"invalid_request",
	"invalid_client",
	"invalid_grant",
	"unauthorized_client",
	"unsupported_grant_type",
	"invalid_scope",
	"access_denied",
	"expired_token",
	"authorization_pending",
	"slow_down",
	"server_error",
	"temporarily_unavailable",
	"invalid_token",
	"insufficient_scope",
];
const OAUTH_ERROR_CODE = new RegExp(`\\b(${OAUTH_ERROR_CODES.join("|")})\\b`);
/** An HTTP status as pi-ai's messages write one: `status 401`, `status=400`, `HTTP 400` or `(429)`, never `(503 bytes)`. */
const STATUS = /(?:\bstatus[ =:]?\s*|\bHTTP\s+)([1-5]\d\d)\b|\(([1-5]\d\d)\)/i;

/** `value` if it is one of OAuth's error codes. */
export function oauthErrorCode(value: unknown): string | undefined {
	return typeof value === "string" && OAUTH_ERROR_CODES.includes(value) ? value : undefined;
}

/** `: <code>` for one of OAuth's error codes, otherwise nothing. */
export function oauthErrorSuffix(value: unknown): string {
	const code = oauthErrorCode(value);
	return code === undefined ? "" : `: ${code}`;
}

/**
 * `ModelsError`'s detail for its cause, in place of the cause's text: the status, an OAuth error code, a transport
 * failure and an invalid token response, as tags, such as "HTTP error (429)" or "HTTP error (401), invalid_grant". So
 * pi-ai still retries a 429, a 5xx or a failed fetch, and doesn't retry a dead token.
 */
export function causeTag(cause: unknown): string {
	const text = describe(cause);
	const own = cause !== null && typeof cause === "object" ? (cause as { status?: unknown }).status : undefined;
	const match = STATUS.exec(text);
	const status = typeof own === "number" && own >= 100 && own <= 599 ? String(own) : (match?.[1] ?? match?.[2]);
	return [
		status === undefined ? undefined : `HTTP error (${status})`,
		OAUTH_ERROR_CODE.exec(text)?.[1],
		/fetch failed/i.test(text) ? "fetch failed" : /timed? ?out|TimeoutError/i.test(text) ? "timed out" : undefined,
		/missing fields|invalid JSON|isn't valid JSON|Invalid .* response/i.test(text) ? "invalid token response" : undefined,
	]
		.filter((tag) => tag !== undefined)
		.join(", ");
}

/** The names of the fields of `json` that fail their check in `checks`, such as "refresh_token, expires_in". */
export function invalidFields(json: unknown, checks: Record<string, (value: unknown) => unknown>): string {
	if (typeof json !== "object" || json === null) return "not a JSON object";
	const record = json as Record<string, unknown>;
	const names = Object.entries(checks)
		.filter(([name, check]) => !check(record[name]))
		.map(([name]) => name);
	return names.length > 0 ? names.join(", ") : "none";
}

function describe(value: unknown): string {
	try {
		return value instanceof Error ? `${value.name} ${value.message}` : String(value);
	} catch {
		return "";
	}
}
