# Hackathon -- Plug-In

本仓库是 **DSH 黑客松的插件方向**工作区（远程仓库
[kirahvi03/Hackathon--Plug-In](https://github.com/kirahvi03/Hackathon--Plug-In)）。
内容分两部分：

1. **本机开发环境**的配置与自检脚本（第 1–3 节）
2. **DSH 插件骨架** `plugins/hackathon-starter/`（第 4 节），可直接改造为参赛作品

游戏方向的仓库在另一处：[Hackathon--Game](https://github.com/kirahvi03/Hackathon--Game)
（本地路径 `..\hackathon-game`）。

插件体系的完整研究报告见 [`docs/dsh-plugin-development-report.md`](docs/dsh-plugin-development-report.md)
（58KB，含官方 API 导出名、slot key 目录、模板出处与未能确定事项清单）。

---

## 1. 环境总览

| 组件 | 版本 | 位置 / 说明 |
| --- | --- | --- |
| Node.js | v24.21.0 | `C:\Program Files\nodejs\node.exe`（系统安装，已在 PATH 中） |
| npm | 11.19.0 | 随 Node 提供 |
| pnpm | 11.7.0 | 由 `~\.dsh\bin\pnpm.cmd` 转发到 DSH 内置 pnpm 11.7.0 |
| Python | 3.12.14 | DSH 内置解释器，已通过 PATH 前置覆盖失效的商店别名 |
| pip | 26.2.1 | `~\.dsh\bin\pip.cmd` → `python -m pip` |
| Git | 2.55.0 | `C:\Program Files\Git\cmd\git.exe` |
| GitHub 凭据 | 已就绪 | Git Credential Manager 2.9.1，账号 `kirahvi03` |
| VS Code | 1.140.0 | 命令行入口 `code` 可用 |
| ffmpeg | 7.1.1 | 已在 PATH 中 |

未安装（按需再补）：`gh`（GitHub CLI）、`docker`、PowerShell 7（`pwsh`）。

Python 预装库：`numpy` 2.3.5、`pandas` 3.0.1、`openpyxl` 3.1.5、`XlsxWriter` 3.2.9、
`python-docx` 1.2.0、`python-pptx` 1.0.2、`Pillow` 12.3.0、`lxml` 6.1.3。

---

## 2. 本次为环境做的改动

1. **修复 Python**：PATH 上原本只有 Microsoft Store 的 `python.exe` 占位符（执行即失败）。
   现已把可用的 DSH 内置解释器目录前置到用户 PATH。
2. **补上 pnpm**：`pnpm` 之前不在 PATH 上。新增 `~\.dsh\bin\pnpm.cmd`、`pnpx.cmd` shim，
   指向 DSH 内置 pnpm，并把 `~\.dsh\bin` 加到用户 PATH 最前面。
3. **补上 pip 入口**：内置 Python 的 `Scripts` 目录没有可执行文件，新增 `pip.cmd` shim。
4. **PowerShell 执行策略**：当前用户范围设为 `RemoteSigned`，本地脚本可直接运行。
5. **初始化本仓库**：`main` 分支、`.gitignore`、`.gitattributes`。
6. **GitHub 凭据**：全局 `credential.helper = manager`，`git push` 无需再次登录。

> 以上 PATH 改动写入的是**用户级**环境变量。已打开的终端需要重开一次才能生效。

---

## 3. 快速开始

### 3.1 环境自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\env-check.ps1
```

全部通过时退出码为 0，并逐项打印各工具的实际版本与路径。缺少可选项（`gh`/`docker`）只告警。

### 3.2 Web / Node 项目

```powershell
pnpm init                 # 或 pnpm create vite my-app
pnpm add -D typescript    # 依赖安装
pnpm dev                  # 跑开发服务器
```

> 用 `npm` 也可以，但本工作区统一用 `pnpm` 以节省磁盘并避免依赖提升问题。

### 3.3 Python 项目

全局解释器可直接用；做正式项目建议建虚拟环境，避免污染内置环境：

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

> 若激活脚本被执行策略拦截，先运行
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`。

### 3.4 推送到 GitHub

远程仓库已接好并完成首次推送：

| 项 | 值 |
| --- | --- |
| 仓库 | <https://github.com/kirahvi03/Hackathon--Plug-In>（public） |
| remote | `origin` |
| 分支 | `main`，已设置上游跟踪 `origin/main` |

日常提交：

```powershell
git add -A
git commit -m "feat: ..."
git push
```

认证由 Git Credential Manager 自动完成（本机已存 `kirahvi03` 的 token，含 `repo` + `workflow` 权限），
正常情况不会再弹出登录。

---

## 4. DSH 插件骨架（`plugins/hackathon-starter/`）

本机 DSH 是 **0.2.0-rc.2**，插件框架为 **Cordis 4**。一个插件包 = 一个 bundle，
由 `package.json` 的 `dsh.bundle.patch` 指向 `cordis.patch.yml`，后者把插件行 insert 进 profile 的插件树。

骨架同时演示两个扩展点：

| 半边 | 文件 | 内容 |
| --- | --- | --- |
| Host | `index.js` | 具名导出 `{ Config, apply, inject, name }`，用 `ctx.tools.register(defineTool({...}))` 注册工具 `plugin_ping` |
| Client | `client.js` | `window.__ModuleLoader__.load` + `ctx.slots.register` 往 `conversation.composer.dock` 插一个徽标 |

每个 API 字段都对照官方实现 `@deepseek-ai/dsh-tool-todo` 抄写（不是猜测）：
`name` / `description` / `parameters` / `output.{schema,render}` / `execute(args, exec)` / `presentCall(args)`。

**语法自检**（无需安装任何依赖）：

```powershell
node --check .\plugins\hackathon-starter\index.js
node --check .\plugins\hackathon-starter\client.js
```

**安装到 profile**（转发给内置 pnpm，必须用绝对路径）：

```powershell
dsh plugin --profile desktop add "C:\Users\19371\Documents\deepseek-harness\default-workspace\plugins\hackathon-starter"
```

> ⚠️ 尚未替你执行安装：`desktop` 是当前运行中的这个应用独占管理的 profile，
> 安装后需重启才生效，可能打断正在进行的会话。要装的话说一声。

> ℹ️ 官方包（`@deepseek-ai/dsh-tools` 等）**不在 npm 上**，它们打包在 `app.asar` 内。
> 插件通过 `peerDependencies` 声明版本要求，由宿主提供实现，因此**不要自己 `pnpm add` 这些包**。

---

## 5. 注意事项

- **不要在 DSH 会话里直接 `.\script.ps1`**：DSH 托管的 shell 对脚本加载有额外限制，
  会报 “未对文件进行数字签名”。加上 `-ExecutionPolicy Bypass` 用子进程运行即可：
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\env-check.ps1`。
  你自己开的普通终端不受此限制。
- **不要 `pip install` 到内置 Python 之外**：`python` 已指向 DSH 内置解释器，
  装包会写进 DSH 的 `site-packages`。长期项目用 `.venv` 隔离。
- **密钥不入库**：`.gitignore` 已覆盖 `.env`、`*.pem`、`credentials.json` 等；
  需要提交样例时用 `.env.example`。
- **行尾符**：`.gitattributes` 统一仓库内为 LF，Windows 下工作区仍可用 CRLF。

---

## 6. 目录结构

```
.
├─ README.md                              本文件
├─ .gitignore                             忽略规则（Node / Python / 密钥 / 编辑器）
├─ .gitattributes                         行尾符与二进制文件规则
├─ docs/
│  └─ dsh-plugin-development-report.md    DSH 插件开发研究报告（58KB）
├─ plugins/
│  └─ hackathon-starter/                  ← 插件骨架，从这里改造
│     ├─ package.json                     bundle 清单（dsh.bundle.patch / dsh.client）
│     ├─ cordis.patch.yml                 把插件行 insert 进 profile
│     ├─ index.js                         Host 半边：注册 plugin_ping 工具
│     ├─ client.js                        Client 半边：输入框下方徽标
│     ├─ icon.svg                         插件卡片图标
│     ├─ locale/{zh,en}.json              显示名称与描述
│     └─ README.md                        骨架的改造指引
└─ scripts/
   └─ env-check.ps1                       环境自检脚本
```
