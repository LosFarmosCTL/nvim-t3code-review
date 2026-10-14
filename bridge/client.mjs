import {
  Client,
  StreamableHTTPClientTransport,
  UnauthorizedError,
} from "@modelcontextprotocol/client";

import { environment } from "./environment.mjs";
import { Credentials } from "./credentials.mjs";
import { authorize } from "./authorization.mjs";
import { fail } from "./errors.mjs";

export class T3Client {
  constructor(env, credentials) {
    this.env = env;
    this.credentials = credentials;
  }

  static async open(options = {}, progress = () => {}) {
    const env = await environment(options);
    const store = await new Credentials(env, options.storage_dir).load();

    if (
      options.authorize &&
      (options.force ||
        !store.valid() ||
        (options.access === "operate" && !store.operates()))
    ) {
      await authorize(env, store, options, progress);
    }

    const api = new T3Client(env, store);
    if (!store.valid()) {
      fail("AUTH_REQUIRED", "Connect Neovim to T3 Code with :T3Connect.");
    }

    api.client = new Client(
      { name: "nvim-t3code-review", version: "0.1.0" },
      { versionNegotiation: { mode: "legacy" } },
    );

    try {
      await api.client.connect(
        new StreamableHTTPClientTransport(new URL(`${env.origin}/mcp`), {
          authProvider: { token: () => store.value.tokens?.access_token },
          fetch: env.fetcher,
        }),
      );

      api.tools = new Set(
        (await api.client.listTools()).tools.map((tool) => tool.name),
      );

      for (const name of [
        "t3_project_list",
        "t3_thread_list",
        "t3_thread_read",
      ]) {
        if (!api.tools.has(name)) {
          fail("CAPABILITY_MISSING", `This T3 build does not expose ${name}.`);
        }
      }

      return api;
    } catch (error) {
      await api.close();

      if (error instanceof UnauthorizedError) {
        delete store.value.tokens;
        await store.save();

        if (options.authorize && !options.reauthorized) {
          return T3Client.open(
            { ...options, force: true, reauthorized: true },
            progress,
          );
        }

        fail(
          "AUTH_REQUIRED",
          "T3 access expired or was revoked. Run :T3Connect again.",
        );
      }

      throw error;
    }
  }

  summary() {
    return {
      environmentId: this.env.environmentId,
      label: this.env.label,
      origin: this.env.origin,
      serverVersion: this.env.serverVersion,
      orchestrationProtocolVersion: this.env.orchestrationProtocolVersion,
      ...this.credentials.summary(),
    };
  }

  async close() {
    await this.client?.close().catch(() => {});
  }

  async call(name, args) {
    if (!this.tools.has(name)) {
      fail("CAPABILITY_MISSING", `This T3 build does not expose ${name}.`);
    }

    let result;
    try {
      result = await this.client.callTool(
        { name, arguments: args },
        { timeout: 30000 },
      );
    } catch (error) {
      if (error instanceof UnauthorizedError) {
        delete this.credentials.value.tokens;
        await this.credentials.save();

        fail(
          "AUTH_REQUIRED",
          "T3 access expired or was revoked. Run :T3Connect again.",
        );
      }

      throw error;
    }

    let data = result.structuredContent;
    if (!data) {
      const text = result.content?.find((item) => item.type === "text")?.text;

      try {
        data = JSON.parse(text);
      } catch {
        fail("INVALID_RESPONSE", `${name} returned no JSON result.`);
      }
    }

    if (result.isError || (data.code && data.message)) {
      fail(data.code || "TOOL_FAILED", data.message || `${name} failed.`);
    }

    return data;
  }

  async pages(name, args, field) {
    const rows = [];
    const seen = new Set();
    let cursor;

    do {
      const result = await this.call(name, { ...args, limit: 100, cursor });
      rows.push(...result[field]);

      if (result.nextCursor == null) {
        return rows;
      }

      if (seen.has(result.nextCursor)) {
        fail("PAGINATION_FAILED", `${name} repeated a pagination cursor.`);
      }

      seen.add(result.nextCursor);
      cursor = result.nextCursor;
    } while (cursor != null);
  }
}
