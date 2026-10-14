import {
  Client,
  StreamableHTTPClientTransport,
  UnauthorizedError,
} from "@modelcontextprotocol/client";

import { createServer } from "node:http";
import { randomBytes } from "node:crypto";
import { BridgeError, fail } from "./errors.mjs";

import {
  localCli,
  approveLocally,
  requestedAccess,
  scopes,
} from "./local-auth.mjs";

async function callbackServer({ state, timeoutMs = 300000 }) {
  let resolveCallback, rejectCallback;
  const callback = new Promise((res, rej) => {
    resolveCallback = res;
    rejectCallback = rej;
  });

  // Attach immediately, including if the user denies before the caller starts waiting.
  callback.catch(() => {});

  const server = createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");

    if (request.method !== "GET" || url.pathname !== "/callback") {
      response.writeHead(404).end();
      return;
    }

    if (url.searchParams.get("state") !== state) {
      response.writeHead(400).end("Invalid OAuth state.");
      return;
    }

    response.writeHead(200, {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
    });

    if (url.searchParams.has("error")) {
      response.end("T3 connection was not approved. Return to Neovim.");
      rejectCallback(
        new BridgeError("AUTH_DENIED", "T3 connection was not approved."),
      );
    } else if (!url.searchParams.get("code")) {
      response.end("Missing authorization code.");
      rejectCallback(
        new BridgeError("AUTH_INVALID", "T3 returned no authorization code."),
      );
    } else {
      response.end(
        "T3 approval received. Return to Neovim to finish connecting.",
      );
      resolveCallback(url.searchParams);
    }
  });

  await new Promise((res, rej) => {
    server.once("error", rej);
    server.listen(0, "127.0.0.1", res);
  });

  const timer = setTimeout(
    () =>
      rejectCallback(
        new BridgeError(
          "AUTH_TIMEOUT",
          "T3 authorization timed out. Run :T3Connect again.",
        ),
      ),
    timeoutMs,
  );

  return {
    url: `http://127.0.0.1:${server.address().port}/callback`,
    callback,
    close: async () => {
      clearTimeout(timer);
      server.closeAllConnections();
      await new Promise((res) => server.close(res));
    },
  };
}

export async function authorize(env, credentials, options, progress) {
  const access = requestedAccess(options);
  const cli = await localCli(env, options);

  if (options.auth_method === "cli" && !cli.available) {
    fail(
      "CLI_UNAVAILABLE",
      cli.reason + " Open the app or configure connection.cli_path.",
    );
  }

  const state = randomBytes(32).toString("base64url");
  const listener = await callbackServer({
    state,
    timeoutMs: options.auth_timeout_ms,
  });

  const issuer = env.origin;
  let verifier, discovery, registration, localResponse;
  const provider = {
    redirectUrl: listener.url,
    clientMetadata: {
      client_name: "Neovim T3 review",
      redirect_uris: [listener.url],
      response_types: ["code"],
      grant_types: ["authorization_code"],
      token_endpoint_auth_method: "none",
      scope: scopes(access).join(" "),
    },
    state: () => state,
    clientInformation: () => registration,
    saveClientInformation: (value, ctx) => {
      if (ctx?.issuer && ctx.issuer !== issuer) {
        fail("ISSUER_MISMATCH", "T3 OAuth issuer changed.");
      }

      registration = value;
    },
    tokens: () => undefined, // An explicit connection creates a fresh independent grant.
    saveTokens: async (tokens, ctx) => {
      if (ctx?.issuer && ctx.issuer !== issuer) {
        fail("ISSUER_MISMATCH", "T3 OAuth issuer changed.");
      }

      if (tokens.token_type.toLowerCase() !== "bearer") {
        fail("TOKEN_UNSUPPORTED", "T3 returned an unsupported token type.");
      }

      credentials.value.tokens = tokens;
      credentials.value.expiresAt =
        Date.now() + (tokens.expires_in || 0) * 1000;
      credentials.value.authMethod = cli.available ? "cli" : "browser";
      await credentials.save();
    },
    saveCodeVerifier: (value) => {
      verifier = value;
    },
    codeVerifier: () => verifier,
    saveDiscoveryState: (value) => {
      discovery = value;
    },
    discoveryState: () => discovery,
    validateResourceURL: async (serverUrl, resource) => {
      const url = new URL(resource || serverUrl);
      if (url.href !== `${env.origin}/mcp`) {
        fail(
          "RESOURCE_MISMATCH",
          "The OAuth resource does not match this T3 MCP endpoint.",
        );
      }

      return url;
    },
    redirectToAuthorization: async (url) => {
      if (url.origin !== issuer) {
        fail("ISSUER_MISMATCH", "T3 authorization points to another origin.");
      }

      url.searchParams.set("scope", provider.clientMetadata.scope);

      if (cli.available) {
        progress({
          type: "local_authorization",
          access: options.access || "read-only",
          runtimeMode: access,
        });

        localResponse = await approveLocally(
          env,
          cli,
          url,
          listener.url,
          state,
          options,
        );
      } else {
        progress({
          type: "authorization",
          url: url.toString(),
          access: options.access || "read-only",
          runtimeMode: access,
          reason: cli.reason,
        });
      }
    },
  };

  const transport = new StreamableHTTPClientTransport(
    new URL(`${env.origin}/mcp`),
    { authProvider: provider, fetch: env.fetcher },
  );
  const client = new Client(
    { name: "nvim-t3code-review", version: "0.1.0" },
    { versionNegotiation: { mode: "legacy" } },
  );

  try {
    try {
      await client.connect(transport);
    } catch (error) {
      if (!(error instanceof UnauthorizedError)) {
        throw error;
      }
    }

    const params = localResponse || (await listener.callback);
    // SDK verifies RFC 9207 iss against the discovery recorded before redirect.
    await transport.finishAuth(params);
  } finally {
    await client.close().catch(() => {});
    await listener.close();
  }
}
