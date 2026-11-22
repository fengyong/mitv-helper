# mitv-helper

## 提交与推送（必读）

**两条硬规则**,任何一次提交和推送都必须满足,完整版见
[`docs/git-push-guide.md`](docs/git-push-guide.md):

1. **提交标题必须以「工具名 / 模型名」开头**

   ```bash
   git commit -m "mimocode/M31.1-flash feat: 一句话说清做了什么"
   ```

   格式:`<工具名>/<模型名> <类型>(<作用域>): <一句话摘要>`。前缀取值 `mimocode/M31.1-flash`
   (MiniMax Code / MiniMax-M3.1-Flash)、`zcode/GLM-5.3-Flash`、`deepseek/DeepSeek-Flash` 等,
   换工具或换模型就写当次实际用的那个。前缀必须在标题行**开头**。

2. **推送一律用 `fengyong` 账号**

   ```bash
   git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/<分支>
   ```

   这台机器上 `git@github.com` 的默认身份是 `drax-ola`、对本仓库无写权限;
   `~/.gitconfig` 的 `insteadOf` 全局改写让「改 remote / 换 HTTPS / 加 `-u`」全部无效。
   `~/.ssh/config` 里已配好 `Host github-fengyong` 别名,用 `ssh -T git@github-fengyong`
   校验应回 `Hi fengyong!`。
