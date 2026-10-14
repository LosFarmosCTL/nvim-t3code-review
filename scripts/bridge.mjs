import { T3Client } from "../bridge/client.mjs";
import { Credentials } from "../bridge/credentials.mjs";
import { environment } from "../bridge/environment.mjs";
import { localCli } from "../bridge/local-auth.mjs";
import { projects } from "../bridge/projects.mjs";
import {
  threads,
  validate,
  createThread,
  sendReview,
} from "../bridge/threads.mjs";
import { BridgeError } from "../bridge/errors.mjs";

const emit = (value) => process.stdout.write(JSON.stringify(value) + "\n");

async function doctor(options) {
  const env = await environment(options);
  const credentials = await new Credentials(env, options.storage_dir).load();
  const cli = await localCli(env, options);

  return {
    environmentId: env.environmentId,
    label: env.label,
    origin: env.origin,
    serverVersion: env.serverVersion,
    orchestrationProtocolVersion: env.orchestrationProtocolVersion,
    localCliAvailable: cli.available,
    localCliReason: cli.reason,
    cliPath: cli.path,
    ...credentials.summary(),
  };
}

function dispatch(api, operation, params) {
  switch (operation) {
    case "connect":
      return api.summary();
    case "projects":
      return projects(api, params);
    case "threads":
      return threads(api, params);
    case "validate":
      return validate(api, params);
    case "create":
      return createThread(api, params);
    case "send":
      return sendReview(api, params);
    case "models":
      return api.call("orchestrator_capabilities", {});
    default:
      throw new BridgeError("UNKNOWN_OPERATION", "Unknown bridge operation.");
  }
}

let api;

try {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
  }
  const { operation, options = {}, params = {} } = JSON.parse(input);

  let result;
  if (operation === "doctor") {
    result = await doctor(options);
  } else {
    api = await T3Client.open(
      {
        ...options,
        auth_method: params.method || options.auth_method,
        authorize: operation === "connect",
        force: params.force,
        access: params.access,
        runtime_mode: params.runtime_mode,
      },
      emit,
    );
    result = await dispatch(api, operation, params);
  }

  emit({ type: "result", result });
} catch (error) {
  // SDK errors can contain protocol details. Only deliberately safe errors cross into Lua.
  emit({
    type: "error",
    error: {
      code: error instanceof BridgeError ? error.code : "REQUEST_FAILED",
      message:
        error instanceof BridgeError
          ? error.message
          : "T3 request failed. Check that the server is running and retry discovery.",
    },
  });
  process.exitCode = 1;
} finally {
  await api?.close();
}
