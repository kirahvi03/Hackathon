# Hackathon Starter —— DSH 插件骨架

一个可直接安装、可验证的 DSH 插件起步包。它同时演示了**两个扩展点**：

| 半边 | 文件 | 作用 |
| --- | --- | --- |
| Host | `index.js` | 用 `ctx.tools.register(defineTool({...}))` 注册模型可调用的工具 `plugin_ping` |
| Client | `client.js` | 用 `window.__ModuleLoader__.load` + `ctx.slots.register` 往输入框下方插一个徽标 |

包本身是一个 **bundle**：`package.json` 里的 `dsh.bundle.patch` 指向 `cordis.patch.yml`，
后者把一个插件行 insert 进 profile 的插件树。

## 全部字段都有官方出处

骨架里的 API 不是猜的，逐条对照官方实现 `@deepseek-ai/dsh-tool-todo`：

- 模块用**具名导出** `{ Config, apply, inject, name }`（不是 default export）
- `Config` 用 `@deepseek-ai/schemastery` 定义，插件激活时校验该行的 `config`
- `inject: ['tools']` 声明依赖的服务，拿不到就不激活
- `defineTool` 的字段：`name` / `description` / `parameters` /
  `output.{schema,render}` / `execute(args, exec)` / `presentCall(args)`

## 安装到 profile

官方入口是 `dsh plugin`（它直接转发给内置 pnpm）：

```powershell
# 用绝对路径安装本 bundle（相对路径会被拒绝）
dsh plugin --profile desktop add "C:\Users\19371\Documents\deepseek-harness\default-workspace\plugins\hackathon-starter"
```

> ⚠️ 本次没有替你执行安装：`desktop` 是当前正在运行的这个应用独占管理的 profile，
> 装进去需要重启才生效，可能打断你正在进行的会话。要装的话告诉我，或你自己在
> DSH 里的插件管理界面安装（`install_bundle` + 绝对路径）。

## 验证

1. **纯语法检查**（不需要装任何依赖）：

   ```powershell
   node --check .\plugins\hackathon-starter\index.js
   node --check .\plugins\hackathon-starter\client.js
   ```

2. 安装后在设置 → 插件里应看到卡片标题「黑客松起步插件」（来自 `locale/zh.json` 与 `icon.svg`）。
3. 让模型调用 `plugin_ping`，应当返回你配置的 `greeting` 与 Node 版本、工作目录、时间。
4. 界面输入框下方应出现蓝色 `plugin ok` 徽标；改 `client.js` 后客户端 HMR 会自动重载。

## 改造指引

| 想做的事 | 改哪里 |
| --- | --- |
| 换工具名 / 描述 / 参数 | `index.js` 的 `defineTool({...})` |
| 加可配置项 | `index.js` 的 `Config`，并在 `cordis.patch.yml` 的 `config` 里给值 |
| 换界面插入位置 | `client.js` 的 `ctx.slots.register` 的 `name`（槽位 key） |
| 改显示名称 | `locale/zh.json`、`locale/en.json` 的 `meta.title` |

槽位 key 的完整目录见研究报告第 3 节（`docs/dsh-plugin-development-report.md`），
例如 `conversation.composer.dock`、`conversation.chat.node`、`shell.overlay`、
`tool.call.toolview`、`settings.section`、`plugins.detail.section`。
