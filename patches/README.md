这个目录存放相对原作者仓库的本地二开补丁备份。

- 初始化或手动执行 `.\sync-upstream.cmd -SavePatch` 时，会生成 `local-customizations.patch`
- 合并原作者更新前的备份在 `.local-fork/backups/`（不进 git）
