import { createHash, randomBytes } from "node:crypto";
import { readFile, writeFile, mkdir, rename, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const hash = (text) => createHash("sha256").update(text).digest("hex");

export class Credentials {
  constructor(
    env,
    directory = join(homedir(), ".local/state/nvim/t3/connections"),
  ) {
    this.file = join(
      directory,
      hash(`${env.environmentId}\n${env.origin}`) + ".json",
    );

    this.value = {};
  }

  async load() {
    try {
      this.value = JSON.parse(await readFile(this.file, "utf8"));
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw error;
      }
    }

    return this;
  }

  async save() {
    await mkdir(resolve(this.file, ".."), { recursive: true, mode: 0o700 });

    const temp = this.file + "." + randomBytes(8).toString("hex");

    try {
      await writeFile(temp, JSON.stringify(this.value) + "\n", {
        mode: 0o600,
        flag: "wx",
      });
      await rename(temp, this.file);
    } finally {
      await unlink(temp).catch(() => {});
    }
  }

  valid() {
    return (
      this.value.tokens?.access_token &&
      this.value.expiresAt > Date.now() + 15000
    );
  }

  operates() {
    return (this.value.tokens?.scope || "")
      .split(" ")
      .includes("orchestration:operate");
  }

  summary() {
    return {
      authenticated: Boolean(this.valid()),
      canCreateThreads: Boolean(this.valid() && this.operates()),
      expiresAt: this.value.expiresAt || null,
      authMethod: this.value.authMethod || null,
    };
  }
}
