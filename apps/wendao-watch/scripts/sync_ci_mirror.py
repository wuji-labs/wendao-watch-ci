# Copyright (c) 2026 Qianyuan Wuji Group (WUJILabs)
"""把闻道手表端推到 GitHub 私有 CI 镜像仓，在托管 macOS runner 上真编译。

本仓母体不在 GitHub 上（remote `github` 指向的仓库不存在），而本机没有 Mac，
所以只把 `apps/wendao-watch/` 与它的工作流按原路径放进镜像仓 `wuji-labs/wendao-watch-ci`。
内容取自 git 已提交的 HEAD（不含未提交改动），镜像分支与本地分支同名、强制覆盖。

    python apps/wendao-watch/scripts/sync_ci_mirror.py [--branch 分支名] [--repo owner/name]
"""

import argparse
import io
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

PATHS = ["apps/wendao-watch", ".github/workflows/wendao-watch-ci.yml"]


def run(*args: str, cwd: Path | None = None, capture: bool = False) -> str:
    r = subprocess.run(list(args), cwd=cwd, check=True, capture_output=capture, text=capture)
    return r.stdout.strip() if capture else ""


def main() -> int:
    root = Path(run("git", "rev-parse", "--show-toplevel", capture=True))
    default_branch = run("git", "rev-parse", "--abbrev-ref", "HEAD", capture=True)
    p = argparse.ArgumentParser()
    p.add_argument("--branch", default=default_branch)
    p.add_argument("--repo", default="wuji-labs/wendao-watch-ci")
    a = p.parse_args()

    sha = run("git", "rev-parse", "--short", "HEAD", capture=True)
    archive = subprocess.run(["git", "archive", "HEAD", *PATHS], cwd=root, check=True, capture_output=True).stdout
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(dest, filter="data")
        run("git", "init", "-q", "-b", a.branch, cwd=dest)
        run("git", "add", "-A", cwd=dest)
        run(
            "git", "-c", "user.name=WUJILabs", "-c", "user.email=wujilabs@users.noreply.github.com",
            "commit", "-q", "-m", f"sync {sha}", cwd=dest,
        )
        url = f"ssh://git@ssh.github.com:443/{a.repo}.git"
        run("git", "push", "-q", "-f", url, f"{a.branch}:{a.branch}", cwd=dest)
    print(f"已推送 {sha} → {a.repo}@{a.branch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
