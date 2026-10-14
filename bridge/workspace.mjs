import { realpath } from "node:fs/promises";
import { join, resolve, sep, dirname, basename } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);

export async function canonical(path) {
  const absolute = resolve(path);
  try {
    return await realpath(absolute);
  } catch {
    const parent = dirname(absolute);
    return parent === absolute
      ? absolute
      : join(await canonical(parent), basename(absolute));
  }
}

export const contains = (parent, child) =>
  parent === child ||
  child.startsWith(parent.endsWith(sep) ? parent : parent + sep);

export async function git(path, args) {
  try {
    return (
      await exec("git", ["-C", path, ...args], {
        timeout: 5000,
        maxBuffer: 65536,
      })
    ).stdout.trim();
  } catch {
    return null;
  }
}

export async function commonDir(path) {
  const value = await git(path, [
    "rev-parse",
    "--path-format=absolute",
    "--git-common-dir",
  ]);
  return value && canonical(value);
}

export function repositoryKey(remote) {
  if (!remote) {
    return null;
  }

  const ssh = /^[^@/]+@([^:]+):(.+)$/.exec(remote);
  let host, path;
  if (ssh) {
    [, host, path] = ssh;
  } else {
    try {
      const url = new URL(remote);
      host = url.hostname;
      path = url.pathname;
    } catch {
      return null;
    }
  }

  return `${host.toLowerCase()}/${path.replace(/^\/+|\/+$/g, "").replace(/\.git$/i, "")}`.toLowerCase();
}
