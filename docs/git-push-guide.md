# mitv-helper · 提交与推送指南

> 面向所有参与 mitv-helper 的同学,以及所有接手这个仓库的 AI agent。
> 目标:**看完能自己把改动安全地送上 GitHub**,
> 不再出现「push 被拒 / 超时 / 分不清该推哪个分支 / 推完 CI 红」这类来回折腾。
>
> 项目:MiTV 批量上传助手(Swift:Core / Engine / App / mitvctl)
> 最后核对:2026-11-22(新增两条硬规则:提交标题必须带「工具/模型」前缀、推送必须用 `fengyong` 账号)。

---

## 0. 必读:两条硬规则

> 这两条没有例外。**违反其中任何一条,这次提交/推送就不算数。**

### 规则一 · 提交标题必须以「工具名 / 模型名」开头

格式:

```
<工具名>/<模型名> <类型>(<作用域>): <一句话摘要>
```

- **工具名**:你实际用的那个 agent / CLI / IDE 插件
- **模型名**:完整模型标识
- **类型**:`feat` / `fix` / `docs` / `chore` / `refactor` / `test` / `perf` / `build`
- **作用域**:不明显时可省

本机在用的前缀(照抄,或写你自己的):

| 前缀 | 工具 | 模型 |
|---|---|---|
| `mimocode/M31.1-flash` | MiniMax Code(mimocode) | MiniMax-M3.1-Flash |
| `zcode/GLM-5.3-Flash` | ZCode | GLM-5.3-Flash |
| `deepseek/DeepSeek-Flash` | DeepSeek | DeepSeek-Flash |
| `hy4/HY4-Flash` | HY4 | HY4-Flash |
| `qoder/<你在用的模型>` | Qoder | 按实际填 |

真实例子:

```
mimocode/M31.1-flash fix(ui): 比较视图认领先缓存后删除
zcode/GLM-5.3-Flash docs: 深度评审报告第 4 轮
deepseek/DeepSeek-Flash test: 补一轮契约用例
```

要点:

- 前缀必须在**标题行开头**。不能写成 `fix(ui): mimocode/M31.1-flash ...`(前缀跑到类型后面就失去意义了)。
- **换了工具或模型就换前缀。** 出问题时按前缀一筛,就能把「同一工具 / 同一模型引入的一批提交」全捞出来定位。
- 只有标题行受约束。正文(`git commit -m "标题" -m "正文"`)正常写,正文讲**为什么**,别复述 diff。
- 本仓库历史提交多数没带前缀,**从本指南生效后开始补**;新提交一律带上。

### 规则二 · 推送一律用 `fengyong` 账号

```
git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/<分支>
```

为什么是它(2026-11-22 实测):

- 这台机器上 `git@github.com` 的默认身份是 `drax-ola`,**不是**规范账号;
- 本机 `~/.gitconfig` 有一条 `url.git@github.com:.insteadOf = https://github.com/`,
  会把所有 HTTPS 地址改写成 SSH —— 所以**改 remote、换 HTTPS、加 `-u` 都解决不了问题**;
- HTTPS 到 `github.com` 在这条网络下不通(`curl -I https://github.com` 超时),SSH 通;
- `~/.ssh/config` 里已经配好专属别名 `Host github-fengyong` → `~/.ssh/id_ed25519_fengyong`。

实测记录:

| 检查 | 命令 | 期望输出 |
|---|---|---|
| 默认身份是谁 | `ssh -T git@github.com` | `Hi drax-ola!` ← **别用它推** |
| 规范身份是谁 | `ssh -T git@github-fengyong` | `Hi fengyong!` |
| 写权限 | `git push --dry-run git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/main` | `Everything up-to-date`(GitHub 只对有写权限的人开放 receive-pack,能出这个结果就说明有写权限) |

**不要改 `github-fengyong` 这条别名**,它是规范账号 `fengyong` 的身份,不是你个人的。
你自己的 key 另配一条 `Host github-<你的用户名>`,但项目推送到远端时仍以 `fengyong` 身份为准。

### 两条规则合起来的完整命令

```bash
git add <显式文件路径>                       # 别用 git add -A,会误吞别人在制品
git commit -m "mimocode/M31.1-flash feat: 一句话说清做了什么"
git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/<分支>
```

---

## 1. 分支模型:先搞清楚你的改动属于哪条线

| 分支 | 作用 | 谁能推 |
|---|---|---|
| `main` | 主线 | 维护者 |
| `fix/review-m1-l1` | 评审缺陷修复分支 | 维护者 |
| `feat/upload-target` | 上传目标目录方向 | 维护者 |
| 其它 `feat/*` `fix/*` | 短分支,做完整并快进合回 `main` | 各自负责人 |

两条硬规则:

1. **不要直接在主线分支上做需求开发**,从基线切短分支。
2. **不要跨分支 merge**。需要别人的改动时用 `rebase`,不要 `git merge <别的分支>`——
   历史上出过把无关分支 merge 进 feature 分支、导致 PR 里混进上百个无关提交的事故。

> 本仓库有 worktree `mitv-helper-fix` 并行开发。它是**同一个仓库的不同分支**,
> 不是两个项目;本指南只维护在主检出目录(`mitv-helper/`)这一份,在 worktree 里干活时以这份为准。

---

## 2. 首次配置

### 2.1 确认仓库与写权限

`origin` 已经指向规范账号:

```bash
git remote -v
# origin  git@github-fengyong:fengyong/mitv-helper.git (fetch/push)
```

写权限挂在 `fengyong` 账号上。需要用自己的身份推别的分支时,让维护者把你加成
`fengyong/mitv-helper` 的 collaborator —— 但**规则二**决定你「该用谁的身份推」,
项目规范是后者:统一用 `fengyong`。

### 2.2 `fengyong` 账号的 SSH key

这台机器上已经配好了(2026-11-22 已验证):

| 东西 | 位置 |
|---|---|
| 私钥 | `~/.ssh/id_ed25519_fengyong` |
| 公钥 | `~/.ssh/id_ed25519_fengyong.pub`(已加到 `fengyong` 账号) |
| 别名 | `~/.ssh/config` 里的 `Host github-fengyong` |

换一台新机器时,从零配置:

```bash
ssh-keygen -t ed25519 -C "you@example.com" -f ~/.ssh/id_ed25519_fengyong
# 把公钥贴到 GitHub → fengyong 账号 → Settings → SSH and GPG keys → New SSH key
cat ~/.ssh/id_ed25519_fengyong.pub
```

### 2.3 配一个专属 Host 别名

编辑 `~/.ssh/config`:

```
Host github-fengyong
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_fengyong
    IdentitiesOnly yes
```

`IdentitiesOnly yes` 是关键:不加的话 SSH 可能先拿默认 key 去试,身份就串回 `drax-ola` 了。

### 2.4 验证身份(关键一步)

```bash
ssh -T git@github-fengyong     # 必须回 Hi fengyong!
ssh -T git@github.com          # 这台机器上会回 Hi drax-ola!(默认身份,别用它推)
```

如果第二条显示的账号不是你、而你又用 `git push` 直接推,就会得到
`ERROR: Permission to fengyong/<repo>.git denied to <那个人>`。

---

## 3. 标准提交流程

```bash
# 1. 从最新基线切分支
git fetch git@github-fengyong:fengyong/mitv-helper.git main:refs/remotes/origin/main
git switch -c feat/my-change origin/main

# 2. 改代码 → 本地验证(见第 4 节)→ 提交
#    前缀规则见第 0 节;用显式路径 add,别用 git add -A
git add <显式文件路径>
git commit -m "mimocode/M31.1-flash feat: 一句话说清做了什么"

# 3. 推送(首次推新分支)
git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/feat/my-change

# 4. 后续提交继续推同一个分支
git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/feat/my-change
```

需要把别人的新提交接进来时:

```bash
git fetch git@github-fengyong:fengyong/mitv-helper.git main:refs/remotes/origin/main
git rebase origin/main      # 不要 merge
# 有冲突就解决后 git add + git rebase --continue
git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/feat/my-change
```

> **为什么不加 `-u`**:`git push -u <URL>` 会把 `branch.<名字>.remote` 写成那个 URL。
> 会让 `git status` 看起来有 upstream,但配置里多出一条指向别名地址的 remote,
> 后续 `git pull` / 换身份时容易互相打架。统一走显式命令更可控。

---

## 4. 提交前必须跑的检查

### 4.1 必跑(全绿才算能提交)

```bash
make test        # 单元 + 集成,项数以实际输出为准
make typecheck   # 收集编译器告警当客观证据
make all         # cli + test + app 三件套
```

### 4.2 改到这些文件时的额外动作

| 你改了什么 | 必须额外执行 | 为什么 |
|---|---|---|
| `Sources/MiTVCore` / `MiTVEngine` | `make test` + 协议层对照文档 | 协议/状态机改动 mock 测不出来 |
| `Sources/MiTVApp` | 用快照钩子(`MITV_DATA_DIR` / `MITV_AUTO_ENQUEUE` / `MITV_SNAPSHOT`)起 App 看界面 | UI 改动要有截图证据,别只贴代码 |
| `docs/DELETE_PENDING*.md` | 逐条确认该删的已删 | 这些是待清理清单,别让它们长期留在仓库里 |

> 未经同意**不对真实电视做实测**;需要时用离线 / Mock 证据替代。

---

## 5. 提交信息规范

格式(**前缀不可省**,见第 0 节规则一):

```
<工具名>/<模型名> <类型>(<作用域>): <一句话摘要>
```

- **前缀**:工具名 / 模型名,必填,`工具/模型` 斜杠分隔
- **类型**:`feat` / `fix` / `docs` / `chore` / `refactor` / `test` / `perf` / `build`
- **作用域**:不明显时可省

真实示例:

```
mimocode/M31.1-flash feat: 上传目标目录合并后队列状态机调整
mimocode/M31.1-flash fix: beginUpload 定名现算 inflight,消除同名竞态
mimocode/M31.1-flash docs: 深度评审报告第 4 轮
```

写不下的细节放正文(`git commit -m "标题" -m "正文"`),正文讲**为什么**,别复述 diff。
正文不受前缀约束。

---

## 6. PR 与 CI

### 6.1 开 PR

推完分支后 GitHub 会打印链接,直接点;或手动:

```
https://github.com/fengyong/mitv-helper/pull/new/<你的分支>
```

**base 必须选对**:改动 → `main`

### 6.2 CI

本仓库**没有配置 GitHub Actions**,推出去不会有 CI 反馈。第 4 节的命令必须自己跑过。

评审类文档已有一套命名习惯(`docs/2026MMDD_review_<模型>.md`,模型名用
`deepseekflash` / `glm53flash` / `hy4flash` / `minimax-m3.1-flash` / `qoder` 这类小写写法);
**提交前缀则统一用 `工具/模型` 斜杠写法**,两者别混。

---

## 7. 故障排查:push 失败的四种典型情况

### 7.1 `Permission to fengyong/mitv-helper.git denied to <某人>`

说明你用的是**那个人的 SSH 身份**(这台机器默认 `git@github.com` 是 `drax-ola`)。

```bash
ssh -T git@github-fengyong              # 看它回显的是谁,应该是 fengyong
git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/<分支>
```

不要去改 remote、不要换 HTTPS、不要动 `~/.gitconfig` —— 用别名地址即可。

### 7.2 `Recv failure: Operation timed out` / `Failed to connect to github.com port 443`

HTTPS 到 `github.com` 在这类网络下不通(`curl -I https://github.com` 会超时,
但 `ssh -T git@github.com` 是通的)。

```bash
# 判断:SSH 通、HTTPS 不通 → 一律走 SSH,别折腾 HTTP/1.1 或代理
ssh -T git@github-fengyong
```

换成 SSH 别名地址即可,不需要设置代理。

### 7.3 `HTTP2 framing layer` 之类

同 7.2,本质是 HTTPS 链路问题。改为 SSH 别名地址。不要靠
`-c http.version=HTTP/1.1` 硬顶,那只是偶尔能绕过,不稳定。

### 7.4 `! [rejected] ... (non-fast-forward)`

远程有你没有的提交。

```bash
git fetch git@github-fengyong:fengyong/mitv-helper.git <分支>:refs/remotes/origin/<分支>
git rebase origin/<分支>
git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/<分支>
```

**永远不要用 `--force` 去碾压**(见第 8 节)。

---

## 8. 禁止事项

- ❌ **提交标题不带工具/模型前缀**(第 0 节规则一)。这是硬要求,不是建议。
- ❌ **用 `drax-ola` 或其他身份推送**(第 0 节规则二)。规范身份只有 `fengyong`。
- ❌ `git push --force` / `--force-with-lease` 到任何共享分支。
  force push 会改写别人已拉取的历史,还会让依赖提交事件触发的 CI 彻底失效。
- ❌ `git commit --amend` 一个**已经推送过**的提交(等于改写历史)。
  要修正就新开一个提交。
- ❌ `git merge <其他分支>` 合入别人的代码,用 `rebase`。
- ❌ 修改 `~/.gitconfig`(尤其是 `insteadOf` 那类全局改写)来解决单人 push 问题。
  别名地址是标准解法。
- ❌ `git add -A` 在多人 / 多 agent 共享的 worktree 里一把梭 —— 会把别人的在制品文件吞进提交。
  用显式路径。
- ❌ 把本机绝对路径、私有备份、真实业务数据提交进仓库。

---

## 9. 快速对照表

| 我想…… | 命令 |
|---|---|
| 提交(带工具/模型前缀) | `git commit -m "mimocode/M31.1-flash feat: 一句话说清做了什么"` |
| 推当前分支 | `git push git@github-fengyong:fengyong/mitv-helper.git HEAD:refs/heads/<分支>` |
| 拉最新基线 | `git fetch git@github-fengyong:fengyong/mitv-helper.git main:refs/remotes/origin/main` |
| 把基线接进来 | `git rebase origin/main` |
| 提交前自检 | make test && make typecheck |
| 开 PR | `https://github.com/fengyong/mitv-helper/pull/new/<分支>`(base 选对) |
| 确认推送身份 | `ssh -T git@github-fengyong` → 期望 `Hi fengyong!` |

---

## 10. 项目必读文档

| 文档 | 什么时候读 |
|---|---|
| [`README.md`](../README.md) | 项目入口 |
| [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) | 分层与依赖方向 |
| [`docs/PRODUCT_DESIGN.md`](../docs/PRODUCT_DESIGN.md) | 产品设计 |
| [`docs/ENGINE_NOTES.md`](../docs/ENGINE_NOTES.md) | 引擎实现笔记 |
| [`docs/REVIEW_2026-11-19.md`](../docs/REVIEW_2026-11-19.md) | 首轮评审结论与修复项 |
| `docs/DELETE_PENDING*.md` | 待清理清单 |

> 本指南**只维护这一份,在主检出目录**。worktree 里干活时以这份为准 ——
> 同一个仓库、同一套规则,不要在 worktree 里另写一份。
