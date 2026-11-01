import readonly from "../readonly-tools.json";

/**
 * Tool names allowed through the filter. The single source of truth is
 * readonly-tools.json (a Go test checks the server's own list against it).
 */
export const ALLOWED_TOOLS: ReadonlySet<string> = new Set(readonly.tools);

/** JSON-RPC methods a client may send. Anything else is refused (fail closed). */
export const ALLOWED_METHODS: ReadonlySet<string> = new Set(["initialize", "ping", "tools/list", "tools/call"]);

export function isMethodAllowed(method: string): boolean {
  return ALLOWED_METHODS.has(method) || method.startsWith("notifications/");
}
