import {
  canonical,
  contains,
  commonDir,
  git,
  repositoryKey,
} from "./workspace.mjs";

export async function projects(api, { root, path = root }) {
  root = await canonical(root);
  path = await canonical(path);

  const [rows, common, remote] = await Promise.all([
    api.pages("t3_project_list", {}, "projects"),
    commonDir(root),
    git(root, ["remote", "get-url", "origin"]),
  ]);

  const identity = repositoryKey(remote);
  const ranked = await Promise.all(
    rows.map(async (project) => {
      const workspace = await canonical(project.workspaceRoot);
      const projectCommon = common && (await commonDir(workspace));

      let match = "other project";
      let score = 0;

      if (
        contains(workspace, path) &&
        projectCommon &&
        projectCommon === common &&
        workspace !== root
      ) {
        match = "contains selected file";
        score = 11000 + workspace.length;
      } else if (workspace === root) {
        match = "same checkout";
        score = 10000;
      } else if (common && common === projectCommon) {
        match = "related worktree";
        score = 8000;
      } else if (contains(workspace, path)) {
        match = "contains selected file";
        score = 5000 + workspace.length;
      } else if (
        identity &&
        [
          project.repositoryIdentity?.canonicalKey,
          project.repositoryIdentity?.origin?.canonicalKey,
        ].includes(identity)
      ) {
        match = "same repository, different checkout";
        score = 1000;
      }

      return {
        id: project.id,
        title: project.title,
        workspaceRoot: project.workspaceRoot,
        defaultModelSelection: project.defaultModelSelection,
        match,
        score,
      };
    }),
  );

  ranked.sort((a, b) => b.score - a.score || a.title.localeCompare(b.title));

  return { ...api.summary(), projects: ranked };
}
