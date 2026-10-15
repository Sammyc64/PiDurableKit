// Model access: pi-ai Models collections, credentials kept by Swift, OAuth sign-in, custom and faux providers.
import type { Context } from "@earendil-works/chord";
import {
	type AssistantMessage,
	type AuthEvent,
	type AuthPrompt,
	type Credential,
	type CredentialInfo,
	type CredentialStore,
	createModels,
	createProvider,
	envApiKeyAuth,
	fauxAssistantMessage,
	type FauxProviderHandle,
	fauxProvider,
	getSupportedThinkingLevels,
	type Model,
	type MutableModels,
	type OAuthAuth,
	type OAuthCredential,
	type ProviderStreams,
} from "@earendil-works/pi-ai";
import { anthropicMessagesApi } from "@earendil-works/pi-ai/api/anthropic-messages.lazy";
import { azureOpenAIResponsesApi } from "@earendil-works/pi-ai/api/azure-openai-responses.lazy";
import { googleGenerativeAIApi } from "@earendil-works/pi-ai/api/google-generative-ai.lazy";
import { googleVertexApi } from "@earendil-works/pi-ai/api/google-vertex.lazy";
import { mistralConversationsApi } from "@earendil-works/pi-ai/api/mistral-conversations.lazy";
import { openAICodexResponsesApi } from "@earendil-works/pi-ai/api/openai-codex-responses.lazy";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import { openAIResponsesApi } from "@earendil-works/pi-ai/api/openai-responses.lazy";
import { piMessagesApi } from "@earendil-works/pi-ai/api/pi-messages.lazy";
import { registerBunOAuthFlows } from "@earendil-works/pi-ai/bun-oauth";
import { builtinProviders } from "@earendil-works/pi-ai/providers/all";
import { HostModelsStore, withRemoteCatalogs } from "./catalog.ts";
import { type Args, emit, finish, host, openStream, register } from "./core.ts";
import type { Context as ChordContext } from "@earendil-works/chord";

// MARK: Models

type ModelsState = {
	models: MutableModels;
	credentials: HostCredentialStore;
	fauxes: Map<string, FauxProviderHandle>;
};

// pi-ai's OAuth flows load through a bundler-opaque `import()` by default; embed them statically instead.
// Their Node built-ins (`node:http` for the loopback redirect, `node:crypto`) are host-backed shims.
registerBunOAuthFlows();

/**
 * Credentials kept by the Swift `CredentialStore` (Keychain, memory, or the app's own). Read-modify-write is
 * serialized per provider, so concurrent requests never refresh one OAuth token twice.
 */
class HostCredentialStore implements CredentialStore {
	readonly #models: number;
	readonly #chains = new Map<string, Promise<unknown>>();

	constructor(models: number) {
		this.#models = models;
	}

	async read(providerId: string): Promise<Credential | undefined> {
		return (await host<Credential | null>("credentials.read", { models: this.#models, provider: providerId })) ?? undefined;
	}

	async list(): Promise<readonly CredentialInfo[]> {
		return host<CredentialInfo[]>("credentials.list", { models: this.#models });
	}

	modify(
		providerId: string,
		fn: (current: Credential | undefined) => Promise<Credential | undefined>,
	): Promise<Credential | undefined> {
		return this.#serialized(providerId, async () => {
			const current = await this.read(providerId);
			const next = await fn(current);
			if (JSON.stringify(next) !== JSON.stringify(current)) await this.#write(providerId, next);
			return next;
		});
	}

	delete(providerId: string): Promise<void> {
		return this.#serialized(providerId, () => this.#write(providerId, undefined));
	}

	#write(providerId: string, credential: Credential | undefined): Promise<void> {
		return host("credentials.write", { models: this.#models, provider: providerId, credential: credential ?? null });
	}

	#serialized<T>(providerId: string, operation: () => Promise<T>): Promise<T> {
		const previous = this.#chains.get(providerId) ?? Promise.resolve();
		const result = previous.then(operation, operation);
		const tail = result.then(
			() => undefined,
			() => undefined,
		);
		this.#chains.set(providerId, tail);
		void tail.then(() => {
			if (this.#chains.get(providerId) === tail) this.#chains.delete(providerId);
		});
		return result;
	}
}

export const modelSets = new Map<number, ModelsState>();

export function modelsState(id: number): ModelsState {
	const state = modelSets.get(id);
	if (state === undefined) throw new Error(`Unknown models collection ${id}`);
	return state;
}

function describeModel(model: Model<string>) {
	return {
		provider: model.provider,
		id: model.id,
		name: model.name,
		api: model.api,
		baseUrl: model.baseUrl,
		reasoning: model.reasoning,
		input: model.input,
		contextWindow: model.contextWindow,
		maxTokens: model.maxTokens,
		cost: model.cost,
		// pi-ai's own answer, from the model's reasoning flag and thinking level map.
		thinkingLevels: getSupportedThinkingLevels(model),
	};
}

/** pi-ai's chat API implementations a custom provider can use, by `model.api`. */
/** How a custom provider's tokens refresh (`CustomProvider.TokenRefresh`): an OAuth 2 refresh-token grant. */
interface TokenRefresh {
	tokenUrl: string;
	clientId: string | null;
	scope: string | null;
	/** How the grant is sent: `form` (`application/x-www-form-urlencoded`, as OAuth 2 has it) or `json`. */
	format: "form" | "json";
}

/**
 * OAuth auth for a custom provider whose tokens were stored with `Models.setCredential` (there's no sign-in flow):
 * pi-ai's `Models` refreshes them through `tokenUrl` before they expire, and requests send the access token as the
 * API key.
 */
function tokenRefreshAuth(name: string, refresh: TokenRefresh): OAuthAuth {
	return {
		name,
		login: async () => {
			throw new Error(`${name} has no sign-in; store its tokens instead`);
		},
		refresh: async (credential, signal) => {
			const grant: Record<string, string> = { grant_type: "refresh_token", refresh_token: credential.refresh };
			if (refresh.clientId) grant.client_id = refresh.clientId;
			if (refresh.scope) grant.scope = refresh.scope;
			const json = refresh.format === "json";
			const response = await fetch(refresh.tokenUrl, {
				method: "POST",
				headers: { "content-type": json ? "application/json" : "application/x-www-form-urlencoded", accept: "application/json" },
				body: json ? JSON.stringify(grant) : new URLSearchParams(grant).toString(),
				signal,
			});
			const text = await response.text();
			if (!response.ok) throw new Error(`Token refresh failed (${response.status}): ${text.slice(0, 500)}`);
			const body = JSON.parse(text) as { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown };
			if (typeof body.access_token !== "string") throw new Error("Token refresh returned no access_token");
			const expiresIn = typeof body.expires_in === "number" ? body.expires_in : 3600;
			return {
				...credential,
				type: "oauth",
				access: body.access_token,
				// Servers that don't rotate refresh tokens leave it out: keep the one there is.
				refresh: typeof body.refresh_token === "string" ? body.refresh_token : credential.refresh,
				// A minute early, so a request never goes out with a token about to lapse.
				expires: Date.now() + Math.max(expiresIn - 60, 0) * 1000,
			} satisfies OAuthCredential;
		},
		toAuth: async (credential) => ({ apiKey: credential.access }),
	};
}

const apis: Record<string, () => ProviderStreams> = {
	"anthropic-messages": anthropicMessagesApi,
	"azure-openai-responses": azureOpenAIResponsesApi,
	"google-generative-ai": googleGenerativeAIApi,
	"google-vertex": googleVertexApi,
	"mistral-conversations": mistralConversationsApi,
	"openai-codex-responses": openAICodexResponsesApi,
	"openai-completions": openAICompletionsApi,
	"openai-responses": openAIResponsesApi,
	"pi-messages": piMessagesApi,
};

function fauxStep(step: Args) {
	return fauxMessage(step);
}

/** A response step that asks Swift for the response, and queues itself again for the next request. */
function fauxResponder(models: number, provider: string, faux: FauxProviderHandle) {
	const step = async (context: { messages: unknown[] }, _options: unknown, state: { callCount: number }) => {
		faux.appendResponses([step as never]);
		return fauxMessage(await host<Args>("faux.respond", { models, provider, messages: context.messages, callCount: state.callCount }));
	};
	return step;
}

function fauxMessage(step: Args): AssistantMessage {
	return fauxAssistantMessage(step.content ?? [], {
		stopReason: step.stopReason,
		errorMessage: step.errorMessage,
	});
}

function requestOf(args: Args, signal: AbortSignal | undefined) {
	const { models } = modelsState(args.id);
	const model = models.getModel(args.model.provider, args.model.modelId);
	if (model === undefined) {
		throw Object.assign(new Error(`Unknown model ${args.model.provider}/${args.model.modelId}`), { name: "NotFound" });
	}
	const context = {
		...(args.context.systemPrompt == null ? {} : { systemPrompt: args.context.systemPrompt }),
		messages: args.context.messages,
		...(args.context.tools == null ? {} : { tools: args.context.tools }),
	};
	return { models, model, context, options: { ...(args.options ?? {}), signal } };
}

register({
	// pi-ai `models.completeSimple` / `models.streamSimple`, for tools and tasks that call a model themselves.
	"models.complete": (args, context: ChordContext) => {
		const request = requestOf(args, context.abortSignal);
		return request.models.completeSimple(request.model, request.context as never, request.options as never);
	},
	"models.stream": (args) => {
		const controller = new AbortController();
		const request = requestOf(args, controller.signal);
		const stream = args.stream as number;
		openStream(stream, () => controller.abort());
		void (async () => {
			try {
				for await (const event of request.models.streamSimple(request.model, request.context as never, request.options as never)) {
					// `partial` repeats the whole message on every event; Swift rebuilds it from the deltas.
					const { partial: _partial, ...rest } = event as Args;
					emit(stream, rest);
				}
				finish(stream);
			} catch (error) {
				finish(stream, error);
			}
		})();
	},

	// With a `catalog` URL, the built-in providers get its newer catalogs, as pi does; those kept from before are
	// restored straight away (offline), and `models.refresh` checks for newer ones.
	"models.create": async (args) => {
		const credentials = new HostCredentialStore(args.id);
		const catalog = (args.catalog as string | null | undefined) ?? undefined;
		const models = createModels({ credentials, ...(catalog ? { modelsStore: new HostModelsStore(args.id) } : {}) });
		if (args.builtin !== false) {
			const providers = builtinProviders();
			for (const provider of catalog ? withRemoteCatalogs(providers, catalog) : providers) models.setProvider(provider);
		}
		modelSets.set(args.id, { models, credentials, fauxes: new Map() });
		if (catalog && args.builtin !== false) await models.refresh({ allowNetwork: false });
	},
	"models.dispose": (args) => {
		modelSets.delete(args.id);
	},
	"models.setAPIKey": async (args) => {
		const { credentials } = modelsState(args.id);
		if (args.key === null) await credentials.delete(args.provider);
		else await credentials.modify(args.provider, async () => ({ type: "api_key", key: args.key }) as never);
	},
	"models.setCredential": async (args) => {
		const { credentials } = modelsState(args.id);
		if (args.credential === null) await credentials.delete(args.provider);
		else await credentials.modify(args.provider, async () => args.credential as never);
	},
	"models.list": (args) => {
		const { models } = modelsState(args.id);
		return models.getModels(args.provider ?? undefined).map(describeModel);
	},
	"models.providers": (args) =>
		modelsState(args.id)
			.models.getProviders()
			.map((provider) => ({
				id: provider.id,
				name: provider.name ?? provider.id,
				acceptsAPIKey: provider.auth.apiKey !== undefined,
				oauth:
					provider.auth.oauth === undefined
						? null
						: {
								name: provider.auth.oauth.name,
								label: provider.auth.oauth.loginLabel ?? null,
								isSubscription: provider.auth.oauth.isSubscription === true,
							},
			})),
	"models.login": async (args, context) => {
		const { models } = modelsState(args.id);
		const login = args.login as number;
		const overall = context.abortSignal!;
		const credential = await models.login(args.provider, "oauth", {
			signal: overall,
			prompt: (prompt: AuthPrompt) => {
				const { signal, ...rest } = prompt;
				const abortSignal = signal === undefined ? overall : AbortSignal.any([signal, overall]);
				return host<string>("login.prompt", { login, prompt: rest }, { abortSignal } as Context);
			},
			notify: (event: AuthEvent) => {
				void host("login.notify", { login, event }).catch(() => undefined);
			},
		}, { getDeviceId: () => args.deviceId as string, agentName: (args.agentName as string | null) ?? undefined });
		return { type: credential.type };
	},
	"models.logout": (args) => modelsState(args.id).models.logout(args.provider),
	"models.isConfigured": async (args) => {
		const auth = await modelsState(args.id).models.getAuth(args.provider);
		return auth !== undefined;
	},
	// pi-ai `createProvider`: `args.provider` carries its options, and `models` are pi-ai `Model` objects whose omitted
	// fields default like models.json custom providers (provider, baseUrl, and headers inherited from the provider).
	"models.addProvider": async (args) => {
		const state = modelsState(args.id);
		const spec = args.provider as Args;
		const models = (spec.models as Args[]).map((model) => ({
			name: model.id,
			reasoning: false,
			input: ["text"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			contextWindow: 128000,
			maxTokens: 16384,
			...model,
			api: model.api ?? spec.api,
			provider: spec.id,
			baseUrl: model.baseUrl ?? spec.baseUrl,
			...(spec.headers || model.headers ? { headers: { ...(spec.headers ?? {}), ...(model.headers ?? {}) } } : {}),
		}));
		const api: Record<string, ProviderStreams> = {};
		for (const model of models) {
			const implementation = apis[model.api];
			if (implementation === undefined) throw new Error(`Unsupported API "${model.api}"`);
			api[model.api] ??= implementation();
		}
		// Keyless servers (Ollama, LM Studio) still get a placeholder key: the SDKs refuse to send without one.
		const keyless = spec.apiKey === undefined || spec.apiKey === null;
		state.models.setProvider(
			createProvider({
				id: spec.id,
				name: spec.name ?? spec.id,
				baseUrl: spec.baseUrl,
				...(spec.headers ? { headers: spec.headers } : {}),
				auth: {
					apiKey: keyless
						? { name: spec.name ?? spec.id, resolve: async () => ({ auth: { apiKey: "unused" } }) }
						: envApiKeyAuth(spec.name ?? spec.id, []),
					...(spec.tokenRefresh ? { oauth: tokenRefreshAuth(spec.name ?? spec.id, spec.tokenRefresh as TokenRefresh) } : {}),
				},
				models: models as never,
				api: api as never,
			}) as never,
		);
		if (!keyless) await state.credentials.modify(spec.id, async () => ({ type: "api_key", key: spec.apiKey }) as never);
	},
	// pi-ai `deleteProvider`: a custom, faux, or Foundation Models provider, or a built-in one. Its stored credential stays.
	"models.removeProvider": (args) => {
		const state = modelsState(args.id);
		state.models.deleteProvider(args.provider);
		state.fauxes.delete(args.provider);
	},
	"models.addFaux": (args) => {
		const state = modelsState(args.id);
		const faux = fauxProvider({
			provider: args.provider,
			models: args.models,
			tokensPerSecond: args.tokensPerSecond ?? undefined,
		});
		state.models.setProvider(faux.provider);
		state.fauxes.set(args.provider, faux);
	},
	"faux.append": (args) => {
		const faux = modelsState(args.id).fauxes.get(args.provider);
		if (faux === undefined) throw new Error(`Unknown faux provider ${args.provider}`);
		faux.appendResponses((args.responses as Args[]).map(fauxStep));
	},
	"faux.set": (args) => {
		const faux = modelsState(args.id).fauxes.get(args.provider);
		if (faux === undefined) throw new Error(`Unknown faux provider ${args.provider}`);
		faux.setResponses((args.responses as Args[]).map(fauxStep));
	},
	"faux.respond": (args) => {
		const faux = modelsState(args.id).fauxes.get(args.provider);
		if (faux === undefined) throw new Error(`Unknown faux provider ${args.provider}`);
		faux.setResponses([fauxResponder(args.id, args.provider, faux) as never]);
	},
	"faux.pending": (args) => modelsState(args.id).fauxes.get(args.provider)?.getPendingResponseCount() ?? 0,
	"models.refresh": async (args, context) => {
		const result = await modelsState(args.id).models.refresh({
			providers: args.providers ?? undefined,
			allowNetwork: args.allowNetwork ?? undefined,
			force: args.force ?? undefined,
			signal: context.abortSignal,
		});
		return {
			aborted: result.aborted === true,
			errors: Object.fromEntries([...result.errors].map(([provider, error]) => [provider, error instanceof Error ? error.message : String(error)])),
		};
	},
});
