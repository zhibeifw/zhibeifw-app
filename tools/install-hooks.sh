#!/bin/sh
# 把 tools/pre-commit 装成 git 的提交前检查。仓库建好（git init）后运行一次。
set -e
root=$(git rev-parse --show-toplevel)
cp "$root/tools/pre-commit" "$root/.git/hooks/pre-commit"
chmod +x "$root/.git/hooks/pre-commit"
echo "已安装：提交前会用 gitleaks 检查"
