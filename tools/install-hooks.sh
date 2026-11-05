#!/bin/sh
# 把 tools/pre-commit、tools/commit-msg 装成 git 的提交检查。仓库建好（git init）后运行一次。
set -e
root=$(git rev-parse --show-toplevel)
cp "$root/tools/pre-commit" "$root/.git/hooks/pre-commit"
chmod +x "$root/.git/hooks/pre-commit"
cp "$root/tools/commit-msg" "$root/.git/hooks/commit-msg"
chmod +x "$root/.git/hooks/commit-msg"
echo "已安装：提交前会用 gitleaks 检查；提交说明会检查作者和署名"
