// Defaults for agent metadata when upstream does not supply them.
// Model id uses Ollama local instance.
export const DEFAULT_PROVIDER = "ollama";
export const DEFAULT_MODEL = "llama3.2:3b";
// Context window: Llama 3.2 3B supports ~128k tokens.
export const DEFAULT_CONTEXT_TOKENS = 128_000;
