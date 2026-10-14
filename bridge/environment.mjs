import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { fail } from "./errors.mjs";

export function localOrigin(value) {
  const url = new URL(value);
  if (
    !["http:", "https:"].includes(url.protocol) ||
    !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.pathname !== "/"
  ) {
    fail(
      "INVALID_ORIGIN",
      "Configure a loopback HTTP(S) T3 origin without credentials or a path.",
    );
  }

  return url.origin;
}

function localFetch(origin) {
  return async (input, init = {}) => {
    const url = new URL(
      typeof input === "string" || input instanceof URL ? input : input.url,
    );

    if (url.origin !== origin) {
      fail(
        "ENDPOINT_MISMATCH",
        "T3 advertised an endpoint on a different origin.",
      );
    }

    const signal = init.signal
      ? AbortSignal.any([init.signal, AbortSignal.timeout(15000)])
      : AbortSignal.timeout(15000);
    return fetch(input, { ...init, redirect: "error", signal });
  };
}

export async function environment(options = {}) {
  let origin = options.origin;
  const runtimeFile =
    options.runtime_file || join(homedir(), ".t3/userdata/server-runtime.json");

  if (!origin) {
    let runtime;
    try {
      runtime = JSON.parse(await readFile(runtimeFile, "utf8"));
    } catch {
      fail(
        "SERVER_UNAVAILABLE",
        "Open T3 Code, or configure connection.runtime_file / connection.origin.",
      );
    }

    if (runtime.version !== 1) {
      fail("RUNTIME_UNSUPPORTED", "Unknown T3 runtime discovery format.");
    }

    origin = runtime.origin;
  }

  origin = localOrigin(origin);
  const fetcher = localFetch(origin);
  let response;
  try {
    response = await fetcher(`${origin}/.well-known/t3/environment`);
  } catch {
    fail(
      "SERVER_UNAVAILABLE",
      "The T3 server is unavailable. Open T3 Code and try again.",
    );
  }

  if (!response.ok) {
    fail("SERVER_UNAVAILABLE", "T3 environment discovery failed.");
  }

  const descriptor = await response.json();
  if (descriptor.orchestrationProtocolVersion !== 2) {
    fail(
      "PROTOCOL_UNSUPPORTED",
      "This integration requires T3 Orchestrator protocol 2.",
    );
  }

  if (typeof descriptor.environmentId !== "string") {
    fail("INVALID_ENVIRONMENT", "T3 returned no environment identity.");
  }

  if (
    options.environment_id &&
    descriptor.environmentId !== options.environment_id
  ) {
    fail(
      "ENVIRONMENT_MISMATCH",
      "The saved review recipient belongs to another T3 environment. Choose a thread again.",
    );
  }

  return { ...descriptor, origin, fetcher, runtimeFile };
}
