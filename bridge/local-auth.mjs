import { readFile, stat, access } from "node:fs/promises";
import { constants } from "node:fs";
import { join, dirname } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { canonical } from "./workspace.mjs";
import { localOrigin } from "./environment.mjs";
import { fail } from "./errors.mjs";

const exec = promisify(execFile);

export function requestedAccess(options) {
  if (options.access !== "operate") {
    return "read-only";
  }

  const mode = options.runtime_mode || "approval-required";
  if (
    !["approval-required", "auto-accept-edits", "auto", "full-access"].includes(
      mode,
    )
  ) {
    fail(
      "ACCESS_INVALID",
      "The selected thread uses an unsupported runtime mode.",
    );
  }

  return mode;
}

export function scopes(access) {
  return [
    "orchestration:read",
    ...(access !== "read-only" ? ["orchestration:operate"] : []),
    ...(access === "full-access"
      ? ["settings:write", "source-control:write"]
      : []),
  ];
}

/** Discover only a launcher belonging to the local runtime's data directory. */
export async function localCli(env, options = {}) {
  const method = options.auth_method || "auto";
  if (!["auto", "cli", "browser"].includes(method)) {
    fail(
      "AUTH_METHOD_INVALID",
      "Use connection.auth_method = auto, cli, or browser.",
    );
  }

  if (method === "browser") {
    return { available: false, reason: "Browser authorization was selected." };
  }

  let runtime;
  try {
    runtime = JSON.parse(await readFile(env.runtimeFile, "utf8"));
  } catch {
    return {
      available: false,
      reason: "No local T3 runtime file is available.",
    };
  }

  if (
    runtime.version !== 1 ||
    runtime.devUrl ||
    localOrigin(runtime.origin) !== env.origin
  ) {
    return {
      available: false,
      reason: "The local runtime file does not identify this T3 server.",
    };
  }

  const home = dirname(dirname(await canonical(env.runtimeFile)));
  const path =
    options.cli_path ||
    join(home, "bin", process.platform === "win32" ? "t3.cmd" : "t3");

  // Windows batch launchers need a dedicated adapter; use the browser there for now.
  if (process.platform === "win32") {
    return {
      available: false,
      reason: "Local CLI authorization currently requires macOS or Linux.",
    };
  }

  try {
    if (!(await stat(path)).isFile()) {
      throw new Error("not a file");
    }

    await access(path, constants.X_OK);
  } catch {
    return {
      available: false,
      reason: "The app-managed T3 CLI is missing or is not executable.",
      path,
    };
  }

  return { available: true, path, home };
}

export async function approveLocally(
  env,
  cli,
  authorizationUrl,
  callbackUrl,
  state,
  options,
) {
  const scope = scopes(requestedAccess(options));
  const args = [
    "auth",
    "pairing",
    "create",
    "--base-dir",
    cli.home,
    "--ttl",
    "5m",
    "--label",
    "Neovim T3 review",
    "--json",
  ];
  for (const value of scope) {
    args.push("--scope", value);
  }

  const processEnv = { ...process.env, T3CODE_HOME: cli.home };
  delete processEnv.VITE_DEV_SERVER_URL;

  let issued;
  try {
    const { stdout } = await exec(cli.path, args, {
      env: processEnv,
      timeout: 20000,
      maxBuffer: 65536,
    });
    issued = JSON.parse(stdout);
  } catch {
    // Child-process errors contain stdout/stderr, which may include credentials.
    fail(
      "CLI_AUTH_FAILED",
      "T3's local CLI could not create a pairing credential. Check the launcher, or use connection.auth_method = browser.",
    );
  }

  if (
    typeof issued.credential !== "string" ||
    !issued.credential ||
    !Array.isArray(issued.scopes) ||
    scope.some((value) => !issued.scopes.includes(value)) ||
    !(Date.parse(issued.expiresAt) > Date.now())
  ) {
    fail(
      "CLI_AUTH_FAILED",
      "T3's CLI returned an invalid or insufficient pairing credential. Use a compatible CLI or browser authorization.",
    );
  }

  const authorization = Object.fromEntries(
    [...authorizationUrl.searchParams].filter(([key]) =>
      [
        "response_type",
        "client_id",
        "redirect_uri",
        "code_challenge",
        "code_challenge_method",
        "state",
        "resource",
      ].includes(key),
    ),
  );

  let response, result;
  try {
    response = await env.fetcher(`${env.origin}/oauth/mcp/decision`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        authorization,
        decision: {
          _tag: "pairing-code",
          access: requestedAccess(options),
          code: issued.credential,
        },
      }),
    });
    result = await response.json();
  } catch {
    fail(
      "LOCAL_APPROVAL_FAILED",
      "T3's local pairing approval failed. Retry :T3Connect or use browser authorization.",
    );
  }

  if (!response.ok || typeof result.redirectTo !== "string") {
    fail(
      "LOCAL_APPROVAL_FAILED",
      "T3 rejected local pairing approval. Check T3 Code compatibility or use browser authorization.",
    );
  }

  let redirect;
  try {
    redirect = new URL(result.redirectTo);
  } catch {
    fail("AUTH_INVALID", "T3 returned an invalid authorization callback.");
  }

  const expected = new URL(callbackUrl);
  if (
    redirect.origin !== expected.origin ||
    redirect.pathname !== expected.pathname ||
    redirect.hash ||
    redirect.username ||
    redirect.password ||
    redirect.searchParams.get("state") !== state
  ) {
    fail(
      "AUTH_INVALID",
      "T3 returned an authorization callback that does not match this connection.",
    );
  }

  if (redirect.searchParams.has("error")) {
    fail("AUTH_DENIED", "T3 did not approve the local connection.");
  }

  if (
    !redirect.searchParams.get("code") ||
    redirect.searchParams.get("iss") !== env.origin
  ) {
    fail(
      "ISSUER_MISMATCH",
      "T3's local authorization response has an invalid code or issuer.",
    );
  }

  // No HTTP navigation or browser is needed; the SDK still validates issuer and PKCE.
  return redirect.searchParams;
}
