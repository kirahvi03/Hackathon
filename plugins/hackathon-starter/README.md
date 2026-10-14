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

## 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 装完界面里看不到 | `desktop` profile **未开启 HMR**，新 bundle 要重启才生效 | 重启 DSH |
| 插件卡片出现但报 `error` | 该 bundle 已选中但加载失败 | 在插件页面取消选择即可回滚，不会卡住启动 |
| 报 `ERR_MODULE_NOT_FOUND: @deepseek-ai/dsh-tools` | 本插件以 `link:`（符号链接）方式安装，Node 默认按真实路径解析，可能找不到宿主内的官方包 | 见下方说明 |
| 报 `incompatible-version` | 插件的 DSH peer 版本与宿主不符 | 按提示用 `dsh plugin allow-version` 显式豁免，或改 peer 版本 |

**关于 peer 解析**：官方包（`@deepseek-ai/*`）不在 npm 上，它们在 `app.asar` 内由宿主提供。
安装前的版本门控会校验 `peerDependencies`（本插件的 `0.2.0-rc.2` 精确匹配已通过校验），
所以正常情况下宿主会满足这些 peer。若 `link:` 安装确实触发解析失败，改为常规安装方式：

```powershell
# 用 tarball 而非符号链接安装，使其落进 profile 的 node_modules
cd C:\Users\19371\Documents\deepseek-harness\default-workspace\plugins
pnpm pack hackathon-starter
dsh plugin --profile desktop add "<生成的 .tgz 绝对路径>"
```

## 已登记的宿主元数据

`package.json` 里除 `dsh.bundle.patch` 外，还按官方 `DshPackageManifest` 声明了：

- `dsh.manifestVersion: 1` —— 清单格式版本
- `engines.dsh: "0.2.0-rc.2"` —— 作者声明的兼容运行时（与 peer 门控互补）
- `dsh.client` —— 浏览器半的加载方式与依赖顺序
