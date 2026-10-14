import { canonical, commonDir } from "./workspace.mjs";
import { BridgeError, fail } from "./errors.mjs";

async function threadDetails(api, row, projectId, workspace, root) {
  let thread;
  try {
    ({ thread } = await api.call("t3_thread_read", {
      threadId: row.threadId,
      limit: 1,
      runLimit: 1,
      maxCharsPerItem: 1,
    }));
  } catch (error) {
    // A thread can disappear between listing it and reading its details.
    if (["invalid_request", "thread_not_found"].includes(error.code)) {
      return null;
    }

    throw error;
  }

  const checkout = await canonical(thread.worktreePath || workspace);
  return {
    environment_id: api.env.environmentId,
    project_id: projectId,
    thread_id: row.threadId,
    name: row.title,
    root: checkout,
    branch: thread.branch,
    status: thread.status,
    settled: thread.settled,
    updated_at: thread.updatedAt,
    same_checkout: checkout === root,
  };
}

export async function threads(api, { project_id, root, settled = false }) {
  root = await canonical(root);
  const project = await api.call("t3_project_read", { projectId: project_id });
  const workspace = await canonical(project.workspaceRoot);

  const rows = await api.pages(
    "t3_thread_list",
    { projectId: project_id, settled, includeSubagents: false },
    "threads",
  );

  // Limit concurrent reads while enriching the paginated list with checkout details.
  const enriched = [];
  for (let index = 0; index < rows.length; index += 4) {
    const batch = rows.slice(index, index + 4);
    const details = await Promise.all(
      batch.map((row) => threadDetails(api, row, project_id, workspace, root)),
    );
    enriched.push(...details);
  }

  const available = enriched.filter(Boolean);
  available.sort(
    (a, b) =>
      Number(b.same_checkout) - Number(a.same_checkout) ||
      b.updated_at.localeCompare(a.updated_at),
  );

  return {
    ...api.summary(),
    project: {
      id: project.id,
      title: project.title,
      workspaceRoot: project.workspaceRoot,
    },
    threads: available,
  };
}

export async function validate(api, { target }) {
  if (target.environment_id !== api.env.environmentId) {
    fail(
      "ENVIRONMENT_MISMATCH",
      "Choose a review thread in the current T3 environment.",
    );
  }

  const { thread } = await api.call("t3_thread_read", {
    threadId: target.thread_id,
    limit: 1,
    runLimit: 1,
    maxCharsPerItem: 1,
  });

  if (thread.archived) {
    fail(
      "THREAD_UNAVAILABLE",
      "This thread is archived. Choose another review recipient.",
    );
  }

  if (target.project_id && thread.projectId !== target.project_id) {
    fail(
      "THREAD_MISMATCH",
      "The review thread's project changed. Choose a thread again.",
    );
  }

  const bound = {
    environment_id: api.env.environmentId,
    project_id: thread.projectId,
    thread_id: target.thread_id,
    name: thread.title,
  };
  return { ...api.summary(), target: bound, runtimeMode: thread.runtimeMode };
}

export async function sendReview(api, { target, text, request_id }) {
  if (!api.credentials.operates()) {
    fail(
      "OPERATION_ACCESS_REQUIRED",
      "Sending a review needs operation access.",
    );
  }

  if (target.environment_id !== api.env.environmentId) {
    fail(
      "ENVIRONMENT_MISMATCH",
      "Choose a review thread in the current T3 environment.",
    );
  }

  if (typeof text !== "string" || !text.trim() || text.length > 120000) {
    fail(
      "MESSAGE_INVALID",
      "Review messages must contain between 1 and 120,000 characters.",
    );
  }

  const result = await api.call("t3_thread_send", {
    threadId: target.thread_id,
    message: text,
    mode: "queue",
    clientRequestId: request_id,
  });

  if (
    result.threadId !== target.thread_id ||
    !result.messageId ||
    !result.runId ||
    !["started", "queued"].includes(result.delivery)
  ) {
    fail(
      "SEND_UNCERTAIN",
      "T3 did not confirm review delivery. Comments were retained; retrying this unchanged review uses the same request ID.",
    );
  }

  return result;
}

export async function createThread(
  api,
  { project_id, root, title, model_selection },
) {
  if (!api.credentials.operates()) {
    fail(
      "OPERATION_ACCESS_REQUIRED",
      "Creating a thread needs operation access. Reconnect and choose Approval required or broader in T3.",
    );
  }

  root = await canonical(root);
  const project = await api.call("t3_project_read", { projectId: project_id });
  const workspace = await canonical(project.workspaceRoot);
  const [common, projectCommon] = await Promise.all([
    commonDir(root),
    commonDir(workspace),
  ]);

  let strategy;
  if (root === workspace) {
    strategy = { type: "root" };
  } else if (common && common === projectCommon) {
    strategy = { type: "existing_worktree", worktreePath: root };
  } else {
    fail(
      "WORKSPACE_MISMATCH",
      "Choose the project that owns this checkout to create a review thread.",
    );
  }

  const selection = model_selection || project.defaultModelSelection;
  if (!selection) {
    fail("MODEL_REQUIRED", "Choose a provider and model for the new thread.");
  }

  const args = {
    projectId: project_id,
    title,
    modelSelection: selection,
    runtimeMode: "approval-required",
    interactionMode: "default",
    workspaceStrategy: strategy,
  };

  let result;
  try {
    result = await api.call("t3_thread_launch", args);
  } catch (error) {
    if (error instanceof BridgeError) {
      throw error;
    }

    fail(
      "LAUNCH_UNCERTAIN",
      "The launch could not be confirmed. Check T3's thread list before creating another thread.",
    );
  }

  if (!result.threadId || result.runId != null) {
    fail(
      "LAUNCH_UNCERTAIN",
      "T3 returned an unexpected launch result. Inspect the thread list before continuing.",
    );
  }

  return validate(api, {
    target: {
      environment_id: api.env.environmentId,
      project_id,
      thread_id: result.threadId,
    },
  });
}
