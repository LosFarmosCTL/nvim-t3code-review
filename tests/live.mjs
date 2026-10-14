// Optional check against the running app. Only reads projects and threads.
import assert from "node:assert/strict";
import { T3Client } from "../bridge/client.mjs";
import { projects } from "../bridge/projects.mjs";
import { threads, validate } from "../bridge/threads.mjs";

const api = await T3Client.open({ authorize: true });
try {
  assert(api.summary().authenticated);

  const result = await projects(api, { root: process.cwd() });
  assert(result.projects.length, "Register a project in T3 Code first");

  const project = result.projects[0];
  const listing = await threads(api, {
    project_id: project.id,
    root: process.cwd(),
  });

  if (listing.threads.length) {
    const recipient = await validate(api, { target: listing.threads[0] });
    assert(recipient.target.thread_id === listing.threads[0].thread_id);
  }

  console.log(
    "Live connection passed:",
    api.summary().authMethod,
    "·",
    project.title,
    "·",
    listing.threads.length,
    "active threads",
  );
} finally {
  await api.close();
}
