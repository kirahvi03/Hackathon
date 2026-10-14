# DSH (DeepSeek Harness) 插件开发研究报告

> 版本基线：**DSH `0.2.0-rc.2`**（`dsh --version` 实测输出）、**Cordis `4.0.4`**、内置 **Node 24.18.1 / pnpm 11.7.0**
> 上游仓库：`https://github.com/deepseek-ai/deepseek-harness`，CLI 包 `@deepseek-ai/dsh`（`apps/cli`）
> 调查时间：2026-10-14

---

## 0. 路径更正：真正能读的东西在哪里

任务描述里给的 `...\resources\app.asar\dsh\` **在本机不存在**。实测结论：

| 路径 | 实际是什么 | 证据 |
|---|---|---|
| `C:\Users\19371\AppData\Local\Programs\DeepSeek Harness\resources\app.asar` | **115.7 MB 的 asar 归档文件**，不是目录 | `Get-ChildItem resources` → `-a---- 121348951 app.asar`；`Test-Path "...\resources\app.asar\dsh"` → `False` |
| `...\resources\app.asar.unpacked\dsh\node_modules\` | 真实目录，但**只解包了原生/预编译模块** | 只有 `node-pty`、`sherpa-onnx-win-x64`、`koffi`、`fontkit`、`@swc`、`@img`、`@vscode` 等；其 `@deepseek-ai\` 子目录**只有 4 个包**：`dsh-desktop-host`、`dsh-session-log-export`、`libreoffice-kit`、`libreoffice-kit-win32-x64` |
| `app.asar` 内部路径 `dsh/node_modules/@deepseek-ai/...` | **全部 `@deepseek-ai/dsh-*` 实现代码真正所在** | `resources\runtime\cli\bin\dsh.cmd` 第 4 行直接引用 `..\..\..\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js`（Electron 能读 asar，普通 shell / ripgrep / glob 不能） |

**我做了什么**：自己写了一个最小 asar 解析器（`C:\Users\19371\AppData\Local\Temp\dsh-asar-research\asar.mjs`），把 `@deepseek-ai/` 全部 2911 个文件（52.2 MB）解到

```
C:\Users\19371\AppData\Local\Temp\dsh-asar-research\ex\dsh\node_modules\@deepseek-ai\
```

**后续任何人可以直接用 read/grep 工具读这个目录**，无需再解包。安装目录本身**未被修改**。

两个重要的负面事实（已验证）：

- **asar 内不存在任何 `.d.ts` 文件**（`list "\.d\.ts$"` → 0 条）。类型声明只存在于 npm 发布包中（`package.json` 的 `types` 字段指向 `./lib/types/index.d.ts`，`files` 也声明包含），Desktop 的打包流程把它剥掉了。
- asar 根 `dsh/` 下只有两个文件：`package.json`（一个 `private: true` 的元包 `@deepseek-ai/dsh-desktop-runtime`，把 300+ 个 `@deepseek-ai/dsh-*` 钉在 `0.2.0-rc.2`）和 `desktop-runtime.json`（release 元数据 + `sharedPackages` 清单）。

---

## 1. 插件类型（Plugin types）

DSH 的插件体系完全建立在 **Cordis**（`@deepseek-ai/cordis`）之上。Cordis 官方 README 的定义：

> `C:\Users\19371\AppData\Local\Temp\dsh-asar-research\ex\dsh\node_modules\@deepseek-ai\cordis\README.md:3`
> "Cordis is a TypeScript plugin framework for applications that need explicit dependency injection, scoped services, lifecycle-managed cleanup, and optional configuration-driven loading."

「所有东西都是插件」——DSH 自己就是一个 Cordis 插件树。区分维度是 **运行进程（Host vs Client）** 和 **分发单元（bundle / preset / skill）**。

### 1.1 Host 插件（Node / Electron 主进程侧）

运行在 Host 进程，提供 Service、注册工具、监听事件。入口导出形态（`references/host-plugin.md:47-53`）：

> "`index.js` exports one of these forms; do not mix them:
> - `export function apply(ctx, config) {}` with optional `export const inject = ['tools']` and `export const Config`.
> - A service class as the default export."

真实样例 `dsh-tool-todo` 的导出行（`...\dsh-tool-todo\lib\index.js` 末行）：

```js
export { Config, apply, inject, name };
```

### 1.2 Client / UI 插件（浏览器侧，渲染进 Web 页面）

在 `package.json` 里声明 `dsh.client`，并提供 `./client` 导出。由 `dsh-client-modules` 扫描、打包成浏览器 bundle、通过 `/plugins` 路由下发。

`...\dsh-client-modules\README.md:34`：
> "A browser plugin package declares `dsh.client` in its `package.json` with `platform: 'web'`, exports a `./client` bundle, and lists any non-baseline module requests under `dsh.client.external`."

### 1.3 Bundle（分发单元）

Bundle **不是一种代码形态，而是一种分发形态**：一个带 `dsh.bundle.patch` 的 npm 包，其 YAML patch 往 profile 里插入插件行。

`references/host-plugin.md:3`：
> "A bundle is a package whose `package.json` declares `dsh.bundle.patch`; the YAML patch inserts plugin entries."

**一个 bundle 可以包含 0 个代码文件**（纯配置 bundle，例如 MCP 接入）。它也可能同时带 Host 半和 Client 半。

### 1.4 Agent Preset（预设声明）

一个 bundle 的 patch 里可以插入 `@deepseek-ai/dsh-agent-preset` 行，声明一个「agent 预设」（一组 per-agent 插件）。见 `editing-cordis-compositions\SKILL.md`。已发布的预设 id：`standard`、`ptc`、`minimal`、`cordis`。

### 1.5 Skill（技能）

`SKILL.md` + frontmatter（`name` / `description`），由 `@deepseek-ai/dsh-skill` 注册表统一收集。有两种来源：

- 文件系统目录（`dsh-skill-filesystem` 发现）
- **插件内嵌**：`...\dsh-skill\README.md:52` — "Plugins register an in-memory skill with `ctx.skills.register(...)`"

本机已装的两个官方 skill（就是本报告的一手资料源）：
`cordis-plugin-development`、`cordis-composition-reference`、`editing-cordis-compositions`。

### 1.6 MCP Server（配置型 bundle）

没有一行 JS。patch 里插入已安装的 `@deepseek-ai/dsh-mcp-client`，配置 `serverName` / `transport` / `url`。见 `references\mcp-bundle.md` 与 `templates\mcp\`。

### 1.7 Theme（主题 = 一种特殊的 Client 插件）

不是独立机制。`@deepseek-ai/dsh-client-ui-theme` 暴露 `ctx.theme` 服务，第三方主题就是一个调用 `ctx.theme.register({ id, colorScheme, tokens })` 的 client 插件：

`...\dsh-client-ui-theme\lib\client.js:1447`
```js
if (definition.id === "system") throw new Error("\"system\" is a preference, not a registrable theme id");
if (this.themes.some((t) => t.id === definition.id)) throw new Error(`theme "${definition.id}" is already registered`);
```

同文件还有 `overrideTokens(source, tokens)`（token 级叠加层）与 `theme/change` 事件。

### 1.8 Tool（工具 = Host 插件的一种能力，不是独立类型）

工具由 Host 插件通过 `ctx.tools.register(defineTool({...}))` 注册。内置工具本身就是一个个 `@deepseek-ai/dsh-tool-*` 包（`dsh-tool-todo`、`dsh-tool-web`、`dsh-tool-bash` …）。

### 类型对照表

| 类型 | 运行位置 | 是否含代码 | 关键声明 |
|---|---|---|---|
| Host 插件 | Host 进程 | 是 (JS/TS) | `apply(ctx, config)` / Service class |
| Client/UI 插件 | 浏览器 | 是 (React) | `dsh.client` + `exports["./client"]` |
| Bundle | 两者皆可 | 可 0 | `dsh.bundle.patch` |
| Agent Preset | Host | 否 | patch 里插入 `dsh-agent-preset` 行 |
| Skill | 模型上下文 | 是 (MD) | `SKILL.md` frontmatter |
| MCP Server | Host | 否 | patch 插入 `dsh-mcp-client` |
| Theme | 浏览器 | 是 | client 插件 + `ctx.theme.register` |

---

## 2. Manifest / 入口格式

**`package.json` 是唯一的 manifest 文件**，没有单独的 `dsh-plugin.json` / `plugin.yaml`。类型定义在 `@deepseek-ai/dsh-package-manifest`。

`...\dsh-package-manifest\README.md`：
> "Use `DshPackageManifest` for package metadata, `DshManifest` for the public fields under `dsh`, and member types such as `DshClientManifest` for one domain."

```ts
import type { DshClientManifest, DshPackageManifest } from '@deepseek-ai/dsh-package-manifest'

const manifest: DshPackageManifest = {
  name: 'example-dsh-plugin',
  version: '1.0.0',
  engines: { node: '>=24', dsh: '0.1.5-alpha.1' },
  dsh: {
    manifestVersion: 1,
    bundle: { patch: './cordis.patch.yml' },
    client,
  },
}
```

### 2.1 字段清单（全部来自真实文件）

| 字段 | 必填 | 含义 / 证据 |
|---|---|---|
| `name` / `version` | ✅ | `DshPackageManifest` 的 required 字段 |
| `type` | 建议 | `"module"`（全部 DSH 包都是 ESM） |
| `private` | 本地插件建议 | 模板里为 `true` |
| `exports` | Client 插件必须 | 见下 |
| `dsh.bundle.patch` | Bundle 必须 | **字符串或字符串数组**，相对包根 |
| `dsh.client` | Client 插件必须 | `{ platform, immediately?, inject?, external? }` |
| `dsh.profile.bundles` | 仅 profile 的 `package.json` | bundle 名数组 |
| `dsh.manifestVersion` | 可选 | "the declared format is `1`"（**声明性，安装器不强制**） |
| `engines.dsh` | 可选 | 作者声明的兼容范围（**声明性，不强制**，真正的门控走 `peerDependencies`） |
| `icon` | 可选 | 相对 manifest 目录；"SVG, PNG, JPEG, and WebP up to 256 KiB are accepted"；绝对路径/URL/越界路径/符号链接会被拒绝 |
| `locale/<lang>.json` | 可选（显示用） | `{ "meta": { "title": ..., "description": ... } }` |

**`exports` 的真实样例**（`...\dsh-experimental-schedule-bundle\package.json`）：

```json
"exports": {
  ".": { "types": "./lib/types/index.d.ts", "default": "./lib/index.js" },
  "./src/*": "./src/*",
  "./package.json": "./package.json",
  "./cordis.patch.yml": "./cordis.patch.yml",
  "./locale/*.json": "./locale/*.json"
}
```

Client 插件额外要有 `"./client"`（见 §5.1 模板）。

**`dsh.bundle.patch` 的两种形态**（实测）：

```jsonc
// 单文件 —— @deepseek-ai/dsh-base
"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }

// 有序数组 —— @deepseek-ai/dsh-web-app
"dsh": { "bundle": { "patch": [
  "./cordis.patch.yml",
  "./presets/standard.patch.yml",
  "./presets/ptc.patch.yml",
  "./presets/minimal.patch.yml",
  "./presets/cordis.patch.yml"
] } }
```

**`dsh.client` 的真实样例**（`...\dsh-client-ui-conversation\package.json`）：

```json
"dsh": {
  "client": {
    "inject": [
      "@deepseek-ai/dsh-api-session-controller",
      "@deepseek-ai/dsh-client-file-upload",
      "@deepseek-ai/dsh-client-locale",
      "@deepseek-ai/dsh-client-ui-layout",
      "@deepseek-ai/dsh-client-ui-renderer",
      "@deepseek-ai/dsh-client-ui-session",
      "@deepseek-ai/dsh-client-ui-settings",
      "@deepseek-ai/dsh-client-ui-workspace"
    ],
    "platform": "web"
  }
}
```

`dsh.client` 的校验器（`...\dsh-client-modules\lib\index.js:61-75`）：

```js
function parseDshClient(pkgName, value) {
	if (value === void 0) return void 0;
	if (typeof value !== "object" || value === null) throw new Error(`client-modules: ${pkgName} has a non-object dsh.client declaration`);
	const decl = value;
	if (typeof decl.platform !== "string") throw new Error(`client-modules: ${pkgName} dsh.client.platform must be a string`);
	const inject = optionalStringArray(pkgName, "dsh.client.inject", decl.inject);
	const external = optionalStringArray(pkgName, "dsh.client.external", decl.external);
	if (decl.immediately !== void 0 && typeof decl.immediately !== "boolean") throw new Error(`client-modules: ${pkgName} dsh.client.immediately must be a boolean`);
	...
}
```

以及 `exports["./client"]` 的解析与硬性失败（同文件 `:718-719`）：

```js
const clientRel = clientExportOf(packageName, pkg.exports);
if (clientRel === void 0) throw new Error(`client-modules: ${packageName} declares dsh.client but exports no "./client" bundle`);
```

另一种写法（模板用）：

```json
"exports": { ".": "./index.js", "./client": "./client.js" }
```

### 2.2 `cordis.patch.yml` —— Loader patch 方言

这是 bundle/用户层的**第二个核心文件**。来自 `cordis-composition-reference\SKILL.md:10-24`：

> "A profile composes an ordered list of patch layers over the bundle entry lists. Each patch is a mapping:
> - `insert: [rows]` appends rows; with an `id` naming an existing `group: true` row, the rows are appended inside that group's `config` list.
> - A patch with an `id` and no `insert` targets the existing row with that id. Supplied fields replace the row's fields; **`config` is replaced wholesale, never deep-merged** ...
> A row has `id`, `name` (the plugin package specifier; inserted relative paths are anchored beside their patch file), optional `config`, and optional `disabled`, `inject`, `intercept`, and `isolate`.
> - `group: true` with `name: cordis:group` makes `config` a nested entry list ...
> - `disabled` accepts a boolean, null, or a `!!js` expression ...
> - `!!js` scalars are Loader expressions, **never** `!js`. ...
> - `isolate` maps service names to `true` or a realm label ..."

最小 patch（`templates\decoration\cordis.patch.yml`）：

```yaml
- insert:
    - id: my-decoration
      name: '@local/my-decoration'
```

带 `!!js` 的真实样例（`...\dsh-base\cordis.patch.yml`）：

```yaml
- insert:
    - id: tool-plugin-manager
      name: '@deepseek-ai/dsh-plugin-manager/tools'
      disabled: true

    - id: plugin-manager
      name: '@deepseek-ai/dsh-plugin-manager'
      disabled: !!js "!ctx.get('profileContext')"

    # Profile configuration reloads by default; module roots are opt-in.
    - id: hmr
      name: '@deepseek-ai/dsh-hmr'
      disabled: !!js "!ctx.get('profileContext')"
      config:
        root: []
```

> ⚠️ 反复强调的坑（`host-plugin.md:3` + `app-boot\README.md:205`）：
> "a matching override replaces the complete `config`" — 覆盖某行时**必须重述它需要的每一个字段**，不做深合并。

### 2.3 Profile 的 manifest

`$DSH_HOME/profiles/<name>/package.json`（本机真实内容，`C:\Users\19371\.dsh\profiles\desktop\package.json`）：

```json
{
  "name": "dsh-profile-desktop",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "@deepseek-ai/dsh-experimental-auto-review",
        "@deepseek-ai/dsh-experimental-schedule-bundle"
      ]
    }
  }
}
```

同目录还有 `cordis.yml`（永远是 `[]`，别改）、`cordis.patch.yml`（用户层，改这个）、`pnpm-workspace.yaml`。

---

## 3. API 表面（API surface）

### 3.1 Cordis 核心

`@deepseek-ai/cordis` 的 `Context` 接口（`...\cordis\src\context.ts:16-33`）：

```ts
export interface Context {
  [symbols.isolate]: Dict<symbol>
  [symbols.intercept]: Dict
  root: this
  baseUrl?: string
  events: EventsService
  logger: LoggerService
  reflect: ReflectService
  registry: RegistryService
}
```

Cordis README 的最小可用示例（`cordis\README.md:20-58`）揭示了插件的基本形态：

```ts
const greeter = Object.assign((ctx: Context) => {
  ctx.on('app/ready', (message) => {
    ctx.logger.info('%s #%d', message, ctx.counter.next())
  })
}, {
  inject: ['counter'],
})

await root.plugin(Counter)
await root.plugin(greeter)
```

关键方法（`context.ts` 实测）：`ctx.extend(meta)`、`ctx.isolate(name, label?)`、`ctx.intercept(name, config)`；另有 proxy 混入的 `ctx.plugin()` / `ctx.inject()` / `ctx.provide()` / `ctx.get()` / `ctx.on()` / `ctx.emit()` / `ctx.effect()`。

`ctx.effect()` / `ctx.on()` 是**资源生命周期**的唯一正确入口（`practices.md:8`）：
> "Registrations are effects owned by a context. Plugin unload, agent disposal, slot collapse, and profile patches remove what was registered on the corresponding context."

### 3.2 工具注册（Host）

`defineTool` 是唯一的工具定义入口。完整签名（`...\dsh-tools\README.md:34-58`）：

```ts
import { defineTool } from '@deepseek-ai/dsh-tools'

ctx.tools.register(defineTool({
  name: 'read_file',
  description: 'Read a file from disk.',
  parameters: {
    path: { type: 'string', required: true, description: 'Absolute file path' },
    offset: { type: 'number' },
    limit: { type: 'number' },
  },
  output: {
    schema: { type: 'string' },
    render: (_args, value) => [{ type: 'text', text: value }],
  },
  async execute(args, exec) {
    return readFile(args.path, { encoding: 'utf8', signal: exec.signal })
  },
}))
```

工具服务的全部方法（`dsh-tools\README.md:28,81,85`）：

| API | 作用 |
|---|---|
| `ctx.tools.register(definition)` | 注册工具；注册即对模型可见（schema 自动进系统提示） |
| `ctx.tools.restrict(filter)` | 对某个 agent 做 allow/deny 掩码（只能**减少**） |
| `ctx.tools.guard(guard)` | 单调同步守卫，在 `tools/pre-execute` 之后；返回理由即拒绝，后续监听器**无法翻案** |
| `ctx.tools.get(name, scope)` | 以某 scope 解析工具 |
| `ctx.tools.schemas(scope)` | 返回可见 schema（不含 `execute`） |

schema DSL 支持：`string`、`number`、`integer`、`boolean`、`null`、`array`、`object`、author-only `json`、exact-one `oneOf`。

**真实工具插件完整结构**（`...\dsh-tool-todo\lib\index.js`）：

```js
const name = "tool-todo";
const inject = ["tools", "sessionProjections"];
const Config = z.object({ allowParallelInProgress: z.boolean().required() });  // schemastery

function apply(ctx, config) {
	const allowParallel = config.allowParallelInProgress;
	ctx.sessionProjections.register({ key: "todos", stateSchema: ..., init: () => null, apply: ..., wire: { viewSchema: ..., view: ... }, stateVersion: 2 });
	ctx.tools.register(defineTool({ name: "todo_write", description: ..., parameters: {...}, output: {...},
		execute(args, exec) {
			if (!exec.agent) throw new Error("todo_write requires an owning agent session");
			exec.agent.session.append("todo/write", { todos });
			...
		},
		presentCall: (args) => ({ card: "generic", title: "Update todo list", kind: "other", rawInput: args.todos })
	}));
}
export { Config, apply, inject, name };
```

注意 `Config` 用的是 **`@deepseek-ai/schemastery`**（`import z from "@deepseek-ai/schemastery"`），不是 zod（zod 只用于内部校验）。

### 3.3 事件 / hook（Host）

工具执行流水线（`dsh-tools\README.md:105`）：
> "Every call runs a fixed pipeline: `tools/pre-execute` (extensible allow/deny/ask) → registered monotonic guards → `tools/execute` (around-dispatch wrappers) → `tools/post-execute` (inspect/replace, attach context) → definition-owned `finalizeContent` → the observe-only `tools/result` event."

`practices.md:16` 列出的 waterfall 事件（必须 `return next()` 除非你要接管）：
`agent/pre-step`、`agent/request`、`llm/stream`、`tools/pre-execute`、`tools/execute`、`tools/post-execute`。

其他关键事件：
- `agent/created` —— 拿 `agent.ctx` 注册 per-agent 行为的唯一正确位置
- `system-prompt/assemble` —— ⚠️ `practices.md:17`：**"Do not listen to `system-prompt/assemble` to add or remove tools or text."**
- `session/event`、`turn/end`、`assistant/message`、`tool/result`、`agent/assistant-stream`
- `theme/change`、`locale/change`、`hmr/change`、`hmr/reload`、`internal/plugin`、`internal/update`、`loader/volatile-update`

### 3.4 其他 Host 服务

| API | 来源 | 用途 |
|---|---|---|
| `ctx.systemPrompt.section()` | `practices.md:18` | 加提示词段落（不要用 `system-prompt/assemble`） |
| `agent.inject()` | `practices.md:18` | 加 per-agent 上下文；记为 `agent/inbox/spliced` |
| `ctx.sessionProjections.register({key, stateSchema, init, apply, wire, stateVersion})` | `practices.md:26` + todo 插件 | 从 session log 派生状态（**不要**自己订阅 `session/event` 重扫） |
| `agent.followup()` | `practices.md:29` | 定时器唤醒 agent（`agent.inject()` 不会唤醒） |
| `ctx.skills.register(...)` / `ctx.skills.registerProvider(...)` | `dsh-skill\README.md:52-53` | 内嵌 skill / 注册 skill provider |
| `ctx.pluginManager` | `dsh-plugin-manager\lib\types\tools.js` | bundle 安装/启停（工具背后同一个服务） |
| `ctx.hmr` | `dsh-hmr\README.md:36` | `baseDir`、`config`、`getLinked()`、`getOuterStack()` |
| `ctx.logger` | `cordis\src\context.ts:28` | 日志 |

### 3.5 Client / UI API

**模块加载契约**（`dsh-client-modules\lib\client.js:1-3`，即该包自身的加载方式）：

```js
window.__ModuleLoader__.load({
	id: "@deepseek-ai/dsh-client-modules",
	factory: (require) => {
		...
		return { /* exports */ };
	},
});
```

`dsh-client-modules\lib\client.js:17` 的定义：
> "executing a plugin bundle only REGISTERS its factory (`window.__ModuleLoader__.load({id, factory})`); every module body side effect — including CSS injection — lives inside the factory closure and runs at materialization"

**用户自己写的 client 插件的 factory 返回值**（`templates\decoration\client.js`，官方模板）：

```js
window.__ModuleLoader__.load({
  id: '@local/my-decoration',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    function Decoration() { return h('svg', {...}); }
    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.slots.inject('conversation.composer.dock', () => ctx.slots.register({
          name: 'conversation.composer.dock', id: 'my-decoration', order: 5,
        }, Decoration));
      },
    };
  },
});
```

- `require('react')` 走 shell 预置的冻结模块表（`PLATFORM_MODULES`：React、Cordis、静态 UI 库），**不需要**自己装 React / CDN / UMD（`ui-plugin.md:9`）。
- `id` 必须等于包名（`ui-plugin.md:9`："registers a lazy factory whose id equals the package name"）。
- 非基线的运行时 import 要声明在 `dsh.client.external`（`client-modules\README.md:46`）。

**Slot API**（`dsh-client-ui-slots`）：

```js
ctx.slots.inject(ownerKey, () => ctx.slots.register(options, Component))
```

`register` 的 options 字段（`...\dsh-client-ui-slots\lib\index.js:204-219` 实测）：

| 字段 | 说明 |
|---|---|
| `name` | **必填**，slot key |
| `key` | `keyed` slot 必填 |
| `id` | `list` slot 必填 |
| `select` | `chain` slot 必填 |
| `order` | 排序 |
| `priority` | 冲突消解（"register at a different priority to shadow it (lowest renders)"） |
| `label` | 标签 |
| `inject` | 业务注入 |
| `children` | 声明**子 slot**（声明权 = 渲染权） |
| `store` | `defineStore(...)` 座位 |
| `locale` | 本地化 |
| `registrant` | 诊断用 |

四种 slot kind（`dsh-client-ui-slots\README.md:28`）：`single`（唯一占用）、`list`（有序）、`keyed`（按键分发）、`chain`（自我选举）。

**「声明」slot 没有独立 API** —— 这是最容易搞错的一点。实测 `dsh-client-ui-slots\lib\index.js` 全文件**没有** `declare()`；声明权来自某个 entry / factory 的 `children` 表：

`...\dsh-client-ui-slots\lib\index.js:224-235`（entry 声明子 slot）
```js
if (options.children) {
	const declarations = [];
	for (const [childKey, childSpec] of Object.entries(options.children)) {
		const childRec = this.record(childKey);
		childRec.spec = childSpec;
		childRec.declaredBy = `an entry in "${options.name}"${options.registrant ? ` (${options.registrant})` : ""}`;
		childRec.parent = options.name;
		childRec.declarationEpoch += 1;
		declarations.push([childKey, childRec]);
	}
	...
}
```

`...\dsh-client-ui-slots\lib\index.js:78-81`（factory 同样可以声明）+ `:165`（未声明就注册 → 抛错）
```js
if (!rec?.spec) throw new Error(`slot "${options.name}" is not declared (a parent entry's children table must declare it)`);
```

**真实声明样例**（`...\dsh-client-ui-layout\lib\client.js:601-627`，`root` slot 的占用者声明了 5 个子 slot）：

```js
const disposeRegistration = ctx.slots.register({
	name: "root",
	locale: "common",
	children: {
		"sidebar":        { kind: "single", scope: "root" },
		"main":           { kind: "keyed",  scope: "root" },
		"rightbar":       { kind: "single", scope: "root" },
		"shell.overlay":  { kind: "list",   scope: "root" },
		"shell.leading":  { kind: "single", scope: "root" }
	},
	store
}, AppFrame);
```

spec 的形状就是 `{ kind, scope }`；框架内置的 `root` 在构造时被声明为 `{ kind: "single", scope: "root" }`（`...\dsh-client-ui-slots\lib\index.js:64-72`）。

> **实践含义**：想新增一个 slot key，你必须先占住一个已声明的 slot，并在注册时带 `children`；`SlotMap` 的 TS 类型则靠 `declare module '@deepseek-ai/dsh-client-ui-slots'` 增强（README:56："`SlotMap` is declared empty here and merged by consumers via `declare module` augmentation"）。
> 另一个便利 API：`ctx.slots.provideRoot({ hooks: { ... } })`（`ui-layout\lib\client.js:599`）。

**Slot 目录（真实 slot key，来自 grep 全部 `dsh-client-ui-*/lib/client.js`）**：

| Slot key | 声明/使用方 |
|---|---|
| `root`, `main`, `main.conversation` | ui-renderer / ui-conversation |
| `sidebar`, `sidebar.panellist`, `sidebar.footer.action`, `sidebar.settings` | ui-sidebar |
| `sidebar.brand.mark`, `sidebar.brand.name`, `sidebar.toggle.badge` | ui-sidebar / ui-brand-official |
| `sidebar.workspaces`, `sidebar.workspaces.session.menu.item`, `sidebar.workspaces.session.row.action`, `sidebar.workspaces.directoryFlow` | ui-workspace |
| `sidebar.session.row.leading`, `sidebar.session.row.hover` | ui-workspace / ui-schedule |
| `sidebar.right.pane.tab`, `sidebar.right.pane.tab.title` | ui-plan / ui-deliverables / ui-schedule |
| `sidebar.right.tab.files.actions`, `sidebar.right.tab.document.actions`, `sidebar.right.tab.document.unpreviewable` | ui-open-in-app |
| `shell.overlay`, `shell.leading` | ui-layout |
| `rightbar` | ui-layout |
| `conversation.header`, `conversation.header.leading` | ui-conversation |
| `conversation.session`, `conversation.session.header`, `.header.actions`, `.header.utilities`, `.header.corner`, `.header.lineage` | ui-conversation |
| **`conversation.composer.dock`** | ui-conversation（**官方推荐的装饰位**） |
| `conversation.composer`, `conversation.composer.bar` | ui-approval / ui-user-questions |
| `conversation.input.dock`, `.overlay`, `.attachments`, `.permission`, `.plan`, `.left`, `.right`, `.model`, `.activity` | ui-conversation 等 |
| `conversation.chat.node`, `conversation.chat.turnTail`, `conversation.chat.assistant-actions`, `conversation.chat.commandview` | ui-chat |
| `conversation.message.images`, `conversation.trajectory.images` | ui-attachment |
| `conversation.view`, `conversation.content` (factory) | ui-conversation |
| `conversation.hero.workspace`, `.hero.brand.mark`, `.hero.agentPreset`, `.hero.workspace.directoryFlow` | ui-conversation / ui-workspace |
| `conversation.plan-review.actions`, `conversation.approval.detail` | ui-plan / ui-chat |
| `tool.call.toolview`, `tool.call.images`, `tool.view.cordis` | ui-tool / ui-deliverables / ui-cordis |
| `settings.section`, `settings.general.item`, `settings.header`, `settings.action`, `settings.onboarding` | ui-settings* |
| `settings.plugins.tab`, `settings.models.provider-card`, `settings.models.sign-in`, `settings.models.footer` | ui-settings-plugins / ui-settings-models |
| `plugins.item`, `plugins.detail.actions`, `plugins.detail.badge`, `plugins.detail.section`, `plugins.row.config`, `plugins.bundle.config`, `plugins.bundle.activation` | ui-plugin-manager |
| `deliverables.file.actions`, `deliverables.review.file.actions` | ui-deliverables |

> ⚠️ `practices.md:36`：slot 注册必须通过 `ctx.slots.inject(ownerKey, () => ctx.slots.register(...))`；**不要**在组件外写 DOM 或 append 到 `document.body`。

**其他 Client 服务**：

| API | 证据 |
|---|---|
| `ctx.theme.register({id, colorScheme, tokens})` / `setTheme(id)` / `overrideTokens(source, tokens)` / `getTheme()` / `theme/change` | `dsh-client-ui-theme\lib\client.js:1439-1518` |
| `ctx.locale.register(ns, { zh, en })` / `ctx.locale.bind(ns)` / `ctx.locale.resolveText(text)` / `ctx.locale.addLanguage({id,label,fallback})` | `dsh-client-locale\README.md:38,42,53` |
| `ctx.modules` | `dsh-client-modules\README.md:80` |
| `ctx.configForms.get(ns)` / `ctx.configForms.whileServed([ns], cb)` | `dsh-client-ui-theme\lib\client.js:1581`；`dsh-client-ui-settings-web-search\lib\client.js:307` |
| 主题 token `--dsw-alias-*` | `dsh-client-ui-theme\lib\client.js:1236-1324` 列出内置可检视 token |
| `window.__DSH_BOOT__` | `dsh-client-modules\lib\client.js:102-109` |

⚠️ **硬性禁止**（`practices.md:35`）：
> "Do not `require('@deepseek-ai/dsh-client-ui-primitives')` or load any other Harness Client package as a module; ... a throwing component blanks your slot entry (console: `slot entry crashed in '<slot>'`)."

即：**复制**宿主控件实现，只用 `--dsw-alias-*` token 保持视觉一致，不要 import 宿主组件库。

---

## 4. 开发工作流（Dev workflow）

### 4.1 CLI（实测输出）

`resources\runtime\cli\bin\dsh.cmd` 是入口，内容是：

```bat
@echo off
setlocal DisableDelayedExpansion
set "ELECTRON_RUN_AS_NODE=1"
"%~dp0..\..\..\..\DeepSeek Harness.exe" --expose-internals "%~dp0..\..\..\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js" %*
```

`dsh --version` → **`0.2.0-rc.2`**

`dsh --help`（实测原始输出）：

```
Usage: dsh [--profile] <name> [options] [app-args...]
       dsh plugin --profile <name> <pnpm-args...>

dsh: boot a DeepSeek Harness profile — an ordered stack of plugin-bundle patch
layers under your own overrides.

Options:
  -V, --version                  output the version number
  --profile <name>               the profile under $DSH_HOME/profiles to boot
  --from-default-profile <name>  initialize a new custom profile from a shipped profile template
  --patch <path>                 extra patch-list overlay applied after the profile layer (repeatable)
  --dump-config                  print the composed profile tree and exit
  --dump-config-schema           print JSON Schema for profile entries and patches without mounting
  --dump-default-config          print the profile tree without its user layer or --patch overlays and exit

Examples:
  dsh web                                   boot the web profile (same as: dsh --profile web)
  dsh rescue --from-default-profile web     create rescue from the shipped web template, then boot it
  dsh headless "run the tests"              answer one task, print the result, and exit
  dsh tui --patch ./extra.yml               boot a custom profile with one extra overlay
  dsh web --help                            the web app's own flags and help
  dsh plugin --profile tui add <package>    install a plugin into the tui profile
```

### 4.2 `dsh plugin` —— 唯一的官方插件安装命令

`bin.js:115-127` 的实现说明：
> `plugin` — "manage a profile's plugins by forwarding the remaining arguments to pnpm in the profile directory"

实测 `dsh plugin --profile desktop --help` → **打印的是 pnpm 11.7.0 的 `Usage: pnpm [command] [flags]`**。所以：

```powershell
dsh plugin --profile <name> add <package>       # 安装并加入 profile 依赖
dsh plugin --profile <name> remove <package>
dsh plugin --profile <name> why <package>
```

DSH 自己额外接管三个子命令（`plugin-BGnVfe_D.js:16`）：

```powershell
dsh plugin --profile <name> version-exemptions
dsh plugin --profile <name> allow-version <pkg@ver> --dsh-version <exact> --accept-risk
dsh plugin --profile <name> revoke-version <pkg@ver> --dsh-version <exact>
```

> ⚠️ `--profile desktop` 被特殊对待：`bin.js:36` — `if (profile.toLowerCase() === "desktop") program.error("error: profile \"desktop\" is managed exclusively by the Electron application")`。
> 实测：`dsh --profile desktop --dump-config` → `error: profile "desktop" is managed exclusively by the Electron application`（exit 1）。
> 但 `dsh plugin --profile desktop ...` 是允许的（`manageDesktopProfile: true`，且要求先启动过一次 Desktop 以初始化 profile）。

### 4.3 会话内安装（推荐给 agent / 本机）—— `plugin_manager` 工具

真实工具定义（`...\dsh-plugin-manager\lib\types\tools.js:12-25`）：

```js
ctx.tools.register(defineTool({
    name: 'plugin_manager',
    description: 'List plugins or bundles in the current profile, enable or disable them, install a bundle, or remove an installed bundle. Every action requires danger-full-access permission or approval for this call. ...',
    parameters: {
        action: { type: 'string', required: true, enum: ['list_plugins', 'list_bundles', 'set_plugin', 'set_bundle', 'install_bundle', 'remove_bundle', 'list_version_exemptions', 'set_version_exemption'], description: 'Management operation.' },
        target: { type: 'string', description: 'Plugin entry id, bundle package name, or installation spec, according to action.' },
        enabled: { type: 'boolean', ... },
        runtimeVersion: { type: 'string', ... },
        acceptRisk: { type: 'boolean', ... },
        approvedBuilds: { type: 'array', items: { type: 'string' }, description: 'For install_bundle: pass names from pendingBuilds only after the user explicitly approves running their install scripts in the conversation.' },
        registry: { type: 'string', ... },
        offset: { type: 'number', ... },
        limit: { type: 'number', ... },
    },
    ...
}));
```

`install_bundle` 的 `target`（安装规格）解析规则（`...\dsh-plugin-manager\lib\types\install-spec.js:57-86`）支持：

| 形态 | 判定 |
|---|---|
| **绝对本地路径** | `isAbsolute(path)` → `{ kind: 'path' }`（**相对路径一律拒绝**："a local path must be absolute"） |
| tarball | `\.(tgz\|tar\.gz)$` → `{ kind: 'tarball' }` |
| git | `github:` / `gitlab:` / `git+https://` / `git@host:` / hosted repo URL → `{ kind: 'git', host }` |
| 注册表包 | `name` 或 `name@range` |

> ⚠️ `git` 来源的包**安装时要跑 `prepare` 脚本构建**，pnpm 默认阻止。报错会提示把 key 加到 profile 的 `pnpm-workspace.yaml` 的 `allowBuilds`（`plugin-BGnVfe_D.js:97`）。

### 4.4 插件在磁盘上必须待在哪

```
C:\Users\19371\.dsh\profiles\<profile>\        ← $DSH_HOME/profiles/<profile>
├── package.json          # dsh.profile.bundles（选中的 bundle 列表）
├── cordis.yml            # 永远是 []，别改
├── cordis.patch.yml      # ★ 你的用户覆盖层（用户 patch 层，最后应用）
├── pnpm-workspace.yaml   # nodeLinker: hoisted（本机实测）
├── compatibility.json    # 版本豁免（exact-version exemptions）
└── node_modules\         # 装进来的 bundle（本机 desktop profile 目前【没有】这个目录）
```

**两种放置方式**：

1. **安装成 bundle（持久、跨 session）**：包放任意绝对路径（工作区即可），用 `plugin_manager install_bundle` 或 `dsh plugin add`。会写 profile 的 `package.json` / `cordis.patch.yml` / pnpm 依赖。
2. **临时 overlay（不持久）**：`dsh --profile <name> --patch ./dev.patch.yml`。`dev.patch.yml` 里用 `insert` + **绝对路径**指向插件目录（`app-boot\README.md:65`："Inserted plugin names may be absolute filesystem paths, file URLs, or package specifiers"）。

> ⚠️ 官方 skill 明确禁止手工做第 1 种（`SKILL.md:10`）：
> "Do not write the profile's `package.json` or `cordis.patch.yml`, create packages under `$DSH_HOME`, or run pnpm in the profile directory: `install_bundle` performs those steps."

### 4.5 HMR / 热重载

两个包，别混淆：

| 包 | 侧 | 作用 |
|---|---|---|
| `@deepseek-ai/dsh-hmr` | Host | 重载**插件源码模块** + Include 刷新 + profile 配置变更，共用一个串行队列 |
| `@deepseek-ai/dsh-client-hmr` | 浏览器 | client bundle 重建后的页面侧 `invalidate` / `prefetch` 重载链 |

Host HMR 配置（`dsh-hmr\README.md:27-45`）：

```yaml
- id: hmr
  disabled: false
  config:
    root: ["."]
```

| 字段 | 默认 | 含义 |
|---|---|---|
| `base` | Context base URL | 模块监视基准目录 |
| `root` | `["."]` | 模块监视根；`[]` 只保留显式配置监视 |
| `ignored` | `["**/node_modules", "**/.*", "cache", "data"]` | 排除路径 |
| `debounce` | `100` | 合并模块变更的毫秒数 |

⚠️ 基线的 `dsh-base` 把 hmr 的 `root` 设成 `[]`（**默认不监视源码模块**），要**在启动前的 profile patch 里**改成 `["."]` 才生效。
⚠️ `dsh-hmr\README.md:89`：**"Replacing installed package versions still requires a restart through Plugin Manager."** —— 替换已安装包必须重启。

### 4.6 Client 插件的构建要求

`dsh-client-modules\README.md:50`：
> "The host serves built client bundles, so `pnpm run build` must have produced each `lib/client.js` before launch; a missing bundle fails activation loudly with one build instruction and a package/path list."

- Host 通过 `/plugins` 路由下发，URL 形态 `/plugins/<package>/client.js?rev=<rev>`（`client-modules\README.md:74`），另有 combo 批量路由 `/plugins/??...&rev=...`。
- **纯 JS 手写插件不需要构建步骤**（官方模板 `client.js` 就是裸 `window.__ModuleLoader__.load({...})`）。
- 用 TS/TSX 写的话需要自己 bundler 产出上面那种「注册 lazy factory」的格式（`ui-plugin.md:9`："For compiled sources, use the deployment's Client build tooling to emit this format"）。
- 版本号/revision 来自文件 `mtimeMs`/`ctimeMs`/`size`（`client-modules\README.md:74`）——**不哈希内容**，所以 mtime+size 都不变的改动不会被识别。

### 4.7 有无脚手架 / 生成器？

**官方安装包内没有任何脚手架或 `new` / `create` / `scaffold` 子命令。** 验证：

- `dsh --help` / `dsh plugin --profile desktop --help` 里只有 profile / plugin / dump 三类模式（见 §4.1）。
- `bin.js` 的 `switch (invocation.mode)` 只有 `profile` / `plugin` / `dump-config` / `dump-config-schema` 四个分支（`...\@deepseek-ai\dsh\lib\bin.js:211-249`）。

官方提供的是**模板文件**（复制粘贴用），见 §5.1。
**社区有脚手架**，见 §5.4。

---

## 5. 可运行样例（Working examples）

### 5.1 官方模板（4 + 2 个文件）—— 一手资料

基准目录（asar 内；我已解出到临时目录）：

```
asar 内:      app.asar\dsh\node_modules\@deepseek-ai\dsh-agent-preset\skills\cordis-plugin-development\templates\
已解出到:     C:\Users\19371\AppData\Local\Temp\dsh-asar-research\ex\dsh\node_modules\@deepseek-ai\dsh-agent-preset\skills\cordis-plugin-development\templates\
```

**(a) UI 装饰插件 —— 4 个文件**（`templates\decoration\`）

`package.json`：
```json
{
  "name": "@local/my-decoration",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "exports": { ".": "./index.js", "./client": "./client.js" },
  "dsh": {
    "bundle": { "patch": "./cordis.patch.yml" },
    "client": {
      "platform": "web",
      "immediately": true,
      "inject": ["@deepseek-ai/dsh-client-ui-conversation"]
    }
  }
}
```

`cordis.patch.yml`：
```yaml
- insert:
    - id: my-decoration
      name: '@local/my-decoration'
```

`index.js`（Host 半）：
```js
/** Host half of the decoration bundle; the Client module owns the rendering. */
export function apply() {}
```

`client.js`（Client 半）：
```js
window.__ModuleLoader__.load({
  id: '@local/my-decoration',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    function Decoration() {
      return h('svg', {
        viewBox: '0 0 64 64', width: 48, height: 48,
        'aria-hidden': true,
        style: { display: 'block', pointerEvents: 'none' },
      }, h('circle', { cx: 32, cy: 32, r: 24, fill: '#247bbf' }));
    }
    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.slots.inject('conversation.composer.dock', () => ctx.slots.register({
          name: 'conversation.composer.dock', id: 'my-decoration', order: 5,
        }, Decoration));
      },
    };
  },
});
```

**(b) MCP 接入 bundle —— 2 个文件（0 行 JS）**（`templates\mcp\`）

`package.json`：
```json
{
  "name": "@local/demo-mcp",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
}
```

`cordis.patch.yml`：
```yaml
- insert:
    - id: demo-mcp
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: demo
        transport: streamable-http
        url: http://127.0.0.1:3000/mcp
        failOnStartupError: true
```

验证方式（`mcp-bundle.md:5`）：装完后调 `mcp__demo__ping`。stdio 用 `transport: stdio` + `command` / `args` / `env` / `cwd`。

### 5.2 官方随包文档（skill 包，共 3 个 skill / 9 个 md）

```
...\dsh-agent-preset\skills\cordis-plugin-development\SKILL.md                             (8144 B)
...\dsh-agent-preset\skills\cordis-plugin-development\references\host-plugin.md             (3280 B)
...\dsh-agent-preset\skills\cordis-plugin-development\references\ui-plugin.md               (1992 B)
...\dsh-agent-preset\skills\cordis-plugin-development\references\mcp-bundle.md              ( 984 B)
...\dsh-agent-preset\skills\cordis-plugin-development\references\practices.md               (7631 B)
...\dsh-agent-preset\skills\cordis-plugin-development\references\user-actions.md            (1375 B)
...\dsh-agent-preset\skills\cordis-plugin-development\references\verification.md            ( 954 B)
...\dsh-agent-preset\skills\cordis-composition-reference\SKILL.md                           (2806 B)
...\dsh-agent-preset\skills\cordis-composition-reference\references\packages.md             (38782 B)
...\dsh-agent-preset\skills\editing-cordis-compositions\SKILL.md                            (5739 B)
```

> `packages.md` (38 KB) 是**所有可安装插件包的清单**，按 group 分组并标注是否吃 `config`。skill 建议 `grep -n <keyword>` 而不是整读。

### 5.3 官方随包真实插件 / bundle 实例

| 路径（解出后） | 演示什么 |
|---|---|
| `...\dsh-tool-todo\lib\index.js` | **完整工具插件**：`defineTool` + `ctx.tools.register` + `ctx.sessionProjections.register` + `exec.agent.session.append` + `presentCall`；导出 `{ Config, apply, inject, name }` |
| `...\dsh-base\cordis.patch.yml` (20 KB) | 最大的一份 bundle patch，含 `!!js` 条件、`disabled: true` 行 |
| `...\dsh-web-app\cordis.patch.yml` (21 KB) | Web 覆盖层；`dsh.bundle.patch` 为 5 文件有序数组 |
| `...\dsh-web-app\presets\{standard,ptc,minimal,cordis}.patch.yml` | **agent preset 声明**的 4 个真实样例 |
| `...\dsh-experimental-schedule-bundle\` | 最小可用「可选功能 bundle」：`package.json` + `cordis.patch.yml` + `locale/{en,zh}.json` + `icon.svg` |
| `...\dsh-client-ui-theme\lib\client.js` | **主题插件** + `ctx.theme` 服务实现 |
| `...\dsh-plugin-manager\lib\types\tools.js` | `plugin_manager` 工具完整定义 |
| `...\dsh-agent-preset\skills\*` | **skill 插件**的真实样例 |

### 5.4 社区脚手架（npm，第三方，未在本机验证运行）

`create-dsh-plugin-cli`（v0.1.9，MIT，`github.com/carbide4826/dsh-plugin-cli`，bin 命令 **`dshp`**）。实测 npm 元数据：

```
bin = { dshp: 'dist/cli.mjs' }
dependencies = { commander: '^15.0.0', '@clack/prompts': '^1.8.0' }
engines = { node: '^22.19.0 || >=24.0.0' }
```

零安装启动：

```sh
npm create dsh-plugin-cli          # 或 npx create-dsh-plugin-cli
```

非交互（README 原文）：

```sh
dshp create my-notes --template notebook -s --description <text> --author <name>
dshp create my-llm --template llm --pkg-position library --author <name>
```

支持的 `--template` 精选案例：`quick-tool`、`model-gateway`、`session-bot`、`webhook-bridge`、`notebook`。
原子能力勾选：`tool` / `events` / `service` / `ui` / `protocol`，配置方式 `none|static|dynamic`。

其 README 给出的生成后流程（与我从官方代码独立验证到的事实一致）：

```sh
cd my-plugin
pnpm install
pnpm approve-builds
pnpm add -D @deepseek-ai/dsh@0.2.0-rc.2
pnpm build
pnpm dsh web --patch ./dev.patch.yml
```

> ⚠️ 第三方包，未经本机安全审计；且本机 npm 网络当前被 TLS 中间人干扰（见 §7）。仅供 hackathon 参考。

其他相关社区包（npm 搜索 `dsh-plugin` 结果，仅记录）：`dsh-plugin-guide`（"official docs mirror ... plus a scaffolder, checker and pack verifier CLI"）、`dsh-plugin`（社区插件市场）、`dsh-find-plugin`、`dsh-plugin-studio`、`awesome-dsh-plugin-feed`。

### 5.5 本机已有的一次**失败**安装记录 —— 关于生态与版本门控的直接证据

`C:\Users\19371\.dsh\profiles\desktop\.plugin-manager\logs\operation-4Sffh8\pnpm.log`（原文）：

```
dsh: installation rejected: Plugin dsh-blender@0.2.2 is incompatible with dsh 0.2.0-rc.2:
peerDependencies {"@deepseek-ai/dsh-tools":"^0.1.0-rc.6"}. Running it may cause crashes or data loss.
Update the plugin or install a plugin version compatible with this dsh runtime. To accept this risk
explicitly, grant the exact-version exemption for dsh-blender@0.2.2 on dsh 0.2.0-rc.2 with
`dsh plugin allow-version` or the plugin manager, then retry the installation or restart dsh.
Exact-version exemption: not active.
dsh: nothing was installed.
```

这条日志证明了 4 件事：
1. 本机此前有人尝试安装社区的 `dsh-blender@0.2.2`；
2. DSH **在安装时强制校验**插件 `peerDependencies` 里的 `@deepseek-ai/dsh*` 声明；
3. 不兼容会**拒绝安装**（不是警告）；
4. 逃生口是 `dsh plugin allow-version <pkg@ver> --dsh-version <ver> --accept-risk`。

---

## 6. 依赖与工具链（Dependencies）

### 6.1 语言 / 运行时

| 项目 | 版本 | 来源 |
|---|---|---|
| Node.js | **24.18.1**（安装自带）；本机系统 Node **v24.21.0** | `resources\runtime\versions.json`；`desktop-runtime.json` → `release.nodeVersion` |
| pnpm | **11.7.0** | 同上；`dsh plugin --profile desktop --help` 实测输出 `Version 11.7.0` |
| npm | 11.19.0 | 本机 |
| 模块制式 | **纯 ESM** | 所有包 `"type": "module"` |
| Desktop 主程序 | Electron（`DeepSeek Harness.exe`，244 MB） | 安装目录 |

### 6.2 插件必须声明的 peer 依赖

真实插件包（`...\dsh-tool-todo\package.json`）：

```json
"dependencies": { "zod": "^4.4.3", "@deepseek-ai/schemastery": "~3.18.4" },
"peerDependencies": {
  "@deepseek-ai/cordis": "~4.0.4",
  "@deepseek-ai/dsh-session-projection": "0.2.0-rc.2",
  "@deepseek-ai/dsh-session": "0.2.0-rc.2",
  "@deepseek-ai/dsh-invariants": "0.2.0-rc.2",
  "@deepseek-ai/dsh-agent": "0.2.0-rc.2",
  "@deepseek-ai/dsh-tools": "0.2.0-rc.2"
}
```

Client UI 包（`...\dsh-client-ui-conversation\package.json`）：

```json
"dependencies": { "@deepseek-ai/schemastery": "~3.18.4" },
"peerDependencies": { "@deepseek-ai/cordis": "~4.0.4" }
```

**版本门控规则**（社区 `create-dsh-plugin-cli` README 明确写出，并与本机拒绝日志一致；我从 DSH 代码侧确认了 peer 校验的存在）：
> dsh 在安装与加载插件时，校验 `peerDependencies` 中所有 `@deepseek-ai/dsh` 与 `@deepseek-ai/dsh-*` 声明；其余依赖不参与。

### 6.3 构建工具链

- **纯 JS 插件：零构建**。官方模板就是裸 JS。
- **TypeScript 类型**：来自 npm 上的 `@deepseek-ai/dsh-*` 包（`package.json` 的 `types: lib/types/index.d.ts`）。
  > ⚠️ **Desktop 的 asar 内不含任何 `.d.ts`**（已实测 0 条）。要类型检查必须 `pnpm add -D @deepseek-ai/dsh@0.2.0-rc.2`。
- **bundler**：DSH 自己的源码用 **tsdown**（`dsh-client-modules\README.md:38` 提到 "A source `import()` split by tsdown compiles to `require.async(...)`"）。但发布包只带 `dsh`/`esbuild`/`vite` 作为零散 devDependencies；**没有强制的 bundler 要求**。
- 我在已发布包的 `package.json` 里找到的构建相关 devDependencies：`vite ^6.0.0`、`esbuild ^0.28.1`、`typescript 5.9.2 / 5.2.2 / ^6.0.3`。
- 用 TS 写 client 半时，产物必须长成 `window.__ModuleLoader__.load({id, factory})` 的形状，并且 `id` = 包名，`lib/client.js` 路径必须与 `exports["./client"]` 一致。

### 6.4 随安装自带的 CLI / 运行时资源

```
resources\runtime\
├── bin\            node.cmd (100 B), node (100 B)
├── cli\            dsh.cmd, command-manager.js, command-path.ps1
├── office-skills\
├── pnpm\           内置 pnpm 11.7.0
├── primary-runtime\ dependencies\{node,pnpm,python} + runtime.json
└── versions.json   { node: "24.18.1", pnpm: "11.7.0" }
```

---

## 7. 最短上手路径（最短上手路径 / Shortest path to a hello-world plugin）

本机当前是 **Desktop（`DeepSeek Harness.exe`）+ `desktop` profile**，且当前会话是 `danger-full-access`（无需审批，`plugin_manager install_bundle` 可直接跑）。所以**最短路径是路径 A**。

### 路径 A（推荐，全程用已验证的官方机制，不依赖外网）

**目标**：在 composer 下方画一个蓝色圆点。

```powershell
# ① 建目录（工作区内即可，不需要放进 .dsh）
$b = "C:\Users\19371\Documents\deepseek-harness\default-workspace\my-decoration"
New-Item -ItemType Directory -Force $b | Out-Null
```

**② 写 4 个文件**（内容直接抄 §5.1(a)，把 `@local/my-decoration` 换成你自己的唯一名，例如 `@local/hello-dot`）

- `$b\package.json`
- `$b\cordis.patch.yml`
- `$b\index.js`（`export function apply() {}`）
- `$b\client.js`（`window.__ModuleLoader__.load({ id: '<包名>', factory(require) { ... } })`）

**③ 语法自检（纯 JS 不需要构建）**

```powershell
node --check "$b\index.js"
node --check "$b\client.js"
```

**④ 安装到当前 profile** —— 在 DSH 会话里调用工具（不是 shell）：

```
plugin_manager  { "action": "install_bundle", "target": "C:\\Users\\19371\\Documents\\deepseek-harness\\default-workspace\\my-decoration" }
```

> `target` 必须是**绝对路径**（`install-spec.js:64`："a local path must be absolute"）。
> `install_bundle` 自己会做包安装 + bundle 选中，**不要**手工写 profile 的 `package.json`/`cordis.patch.yml`，**不要**在 profile 目录跑 pnpm。

**⑤ 读返回值判断是否真的生效**

看返回的 `application` 和 `warnings` 字段（`SKILL.md:25`）：
- `application: applied` → 已生效
- `failed` → 要排查
- `overridden` → 被更高优先级层覆盖
- `restart-required` → 没生效

**⑥ 验证**

```
plugin_manager  { "action": "list_plugins" }
```

或（无需审批，更快）：

```
cordis_inspect_query  → Slots.listSubTree   # 确认 conversation.composer.dock 上出现你的 id
```

**⑦ 迭代**：直接改工作区里的 `client.js` → 客户端 HMR（`dsh-client-hmr`）会按文件 mtime/size 推送新 revision 并重载该行。
⚠️ 若改的是 **Host 半** 或要**替换已安装包**，需要重启（`dsh-hmr\README.md:89`）。

**⑧（可选）给插件加显示名/图标**，让 Plugin Manager 卡片好看：

```jsonc
// package.json 顶层
"icon": "./icon.svg",
"exports": { "./package.json": "./package.json", "./locale/*.json": "./locale/*.json" },
"files": ["locale/*.json", "icon.svg"]
```
```jsonc
// locale/en.json
{ "meta": { "title": "Hello Dot", "description": "Draws a dot under the composer." } }
// locale/zh.json 同结构
```
（真实样例见 `...\dsh-experimental-schedule-bundle\locale\en.json`）

**⑨（可选）不在 Desktop 里、想用命令行调试**：

```powershell
$dsh = "C:\Users\19371\AppData\Local\Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd"
& cmd /c "`"$dsh`" web --patch `"$b\dev.patch.yml`""
```
`dev.patch.yml` 里用绝对路径插行；这条路径**不改 profile**，纯 overlay。

### 路径 A+（想加一个模型可调用的 tool）

在 `$b\index.js` 里（Host 半）加：

```js
import { defineTool } from '@deepseek-ai/dsh-tools';

export const name = 'hello-dot';
export const inject = ['tools'];

export function apply(ctx) {
  ctx.tools.register(defineTool({
    name: 'hello_dot',
    description: 'Say hello from the hello-dot plugin.',
    parameters: { who: { type: 'string', required: true } },
    output: { schema: { type: 'string' }, render: (_a, v) => [{ type: 'text', text: v }] },
    execute: async (args) => `hello, ${args.who}`,
  }));
}
```

但这需要 `@deepseek-ai/dsh-tools` 可解析 —— 由于包从 dsh 安装目录解析（`SKILL.md:18`："Packages shipped with dsh resolve from the dsh installation, so the bundle declares no dependencies on them"），**在 profile 内运行时通常不需要自己装**。若在独立项目里跑，需要 `peerDependencies` 声明 + `pnpm add -D @deepseek-ai/dsh@0.2.0-rc.2`。

### 路径 B（社区脚手架，需外网，未在本机验证）

```powershell
npm create dsh-plugin-cli          # 或 npx -y create-dsh-plugin-cli
cd my-plugin
pnpm install
pnpm approve-builds
pnpm add -D @deepseek-ai/dsh@0.2.0-rc.2
pnpm build
pnpm dsh web --patch ./dev.patch.yml
```

⚠️ 本机 npm 出网当前**不稳定且被 TLS 中间人干扰**（见 §8），且该包为第三方。hackathon 若走这条路，建议先用路径 A 跑通再说。

### 一句话记住的规则

1. 一个插件 = 一个 npm 包；manifest 就是 `package.json`。
2. Host 半：`export function apply(ctx, config)`（+ 可选 `inject` / `Config`）或 default export 一个 Service class。
3. Client 半：`package.json` 里 `dsh.client` + `exports["./client"]`；产物是 `window.__ModuleLoader__.load({ id: <包名>, factory })`，factory 返回 `{ inject, apply(ctx) }`。
4. Bundle：`dsh.bundle.patch` → `cordis.patch.yml` 的 `insert` 行。
5. 安装：`plugin_manager install_bundle`（或 `dsh plugin --profile <name> add <pkg>`）。别手改 profile。
6. patch 覆盖某行 = **整段 config 替换**，不深合并。
7. 一切注册都放进 `ctx.effect` / `ctx.on`，返回 disposer。

---

## 8. 未能确定的事项（Could NOT determine）

明确列在下面，避免误用：

### 环境 / 网络

1. **npm 公网访问目前不可靠**。2026-10-14 10:44 起 `registry.npmjs.org` 出现 TLS 劫持：
   ```
   npm error code ERR_TLS_CERT_ALTNAME_INVALID
   request to https://registry.npmjs.org/dsh-blender failed, reason: Hostname/IP does not match
   certificate's altnames: Host: registry.npmjs.org. is not in the cert's altnames:
   DNS:*.bistu.edu.cn, DNS:bistu.edu.cn
   ```
   因此**无法**核实 `dsh-blender`、`dsh-plugin-guide`、`create-dsh-plugin-cli` 的实际包内容（只有一次 `create-dsh-plugin-cli` 的 `npm view` 在干扰前成功）。本报告里所有社区包信息均来自 **npm 搜索结果摘要 + GitHub raw README**，属**外部不可信数据**，未执行、未审计。

### DSH 侧未验证项

2. **npm 上发布的 `@deepseek-ai/dsh-*` 包是否真的带 `lib/types/**/*.d.ts`** —— 未验证（asar 内 0 个 `.d.ts`，但 `package.json` 的 `files`/`types` 字段声称会带）。这是推断，不是实测。
3. **`install_bundle` 返回值的精确 JSON 结构**（`application` / `warnings` / `pendingBuilds` 的字段名与取值）—— 来自官方 skill 文档的转述，**我未实际调用该工具**（作为子 agent 我不适合改动父 profile 状态）。
4. **`--dump-config` / `--dump-config-schema` 的真实输出**—— 未能取得：`dsh --profile desktop --dump-config` 被 `rejectElectronProfile` 拒绝（`error: profile "desktop" is managed exclusively by the Electron application`），我没有为研究而新建 profile。schema 的具体字段只能从 `dsh-package-manifest\README.md` 与 `app-boot\README.md` 的描述推断。
5. **`PLATFORM_MODULES` 模块表的完整内容** —— `dsh-client-modules\README.md:46` 只说了 "React, Cordis, and static UI libraries"，具体清单没找到（应在 shell 的 boot 代码里，可能在 asar 的 `dsh-web-frontend` 包内，我未展开）。
6. ~~`ctx.slots` 的「声明」API 的确切形态~~ —— **已解决**：不存在 `ctx.slots.declare()`；声明由某个 entry / factory 的 `children` 表完成（`{ kind, scope }`），证据见 §3.5。**仍未定位**：`scope` 除 `"root"` 外还有哪些合法取值（grep 到的全是 `scope: "root"`）。
7. **`ctx.slots.inject` 的第一参数是否必须是已声明的 key**（我在 `dsh-client-ui-renderer\lib\client.js:1343` 看到实现，但 `specDynamic(key)` 的行为细节未追）。
8. **Desktop profile 的 `node_modules` 行为** —— 本机 `~\.dsh\profiles\desktop\` **目前没有 `node_modules`**，`dependencies` 也是 `{}`。装第一个 bundle 后它变成什么样（是否创建、是否 hoisted）**未实测**。
9. **`@deepseek-ai/dsh-client-ui-primitives` 等宿主 UI 包在运行时是否真的无法 `require`** —— `practices.md:35` 明确要求不要这么做，但我没有实测违反时的报错路径。
10. **是否允许只发主题（theme）而不发普通 client 插件** —— 从 `ctx.theme.register` 的实现看可行（推断），但没有官方示例，**未验证**。
11. **HMR 对 workspace 里（非 profile 内）插件的源码监视是否默认生效** —— `dsh-base` 把 hmr `root` 设为 `[]`，且 desktop profile 的 `cordis.patch.yml` 里**没有** hmr 行，所以**我推断本机 Host 侧源码 HMR 当前是关闭的**；客户端 bundle HMR（`dsh-client-hmr`）是否同样受影响**未验证**。
12. **官方是否有 git 源码 checkout 可读** —— 本机没有。仓库是 `https://github.com/deepseek-ai/deepseek-harness`（来自 `package.json` 的 `repository`），我没有联网 clone（网络不可靠，且这超出"只读探查本机"的范围）。**报告里所有「源码」引用都是发布包的 `lib/*.js`（构建产物，JSDoc 保留）+ 少量 `cordis/src/*.ts`（该包恰好带了 TS 源）**，不是真正的 DSH 源码树。

---

## 附：本次调查产生的可复用资产

| 路径 | 内容 |
|---|---|
| `C:\Users\19371\AppData\Local\Temp\dsh-asar-research\asar.mjs` | 最小 asar 解析器（`list` / `cat` / `grep` / `extract` 四个子命令），可直接 `node asar.mjs list <regex>` |
| `C:\Users\19371\AppData\Local\Temp\dsh-asar-research\ex\dsh\node_modules\@deepseek-ai\` | 2911 个文件 / 52.2 MB，全部 `@deepseek-ai` 包的 README + `lib/*.js` + `package.json`，**可直接用 read/grep 工具读** |
| `C:\Users\19371\AppData\Local\Temp\dsh-asar-research\ex\dsh\node_modules\@deepseek-ai\dsh-agent-preset\skills\` | 3 个 skill / 10 个 md 的官方插件开发文档 + 6 个模板文件 |

用 asar.mjs 取原文示例：

```powershell
node C:\Users\19371\AppData\Local\Temp\dsh-asar-research\asar.mjs cat "dsh/node_modules/@deepseek-ai/dsh-agent-preset/skills/cordis-plugin-development/SKILL.md"
```
