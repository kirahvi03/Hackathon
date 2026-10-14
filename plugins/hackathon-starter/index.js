/**
 * Host 半边：注册一个模型可调用的工具。
 *
 * 这份骨架的每个字段都对照官方实现 @deepseek-ai/dsh-tool-todo 抄写，
 * 不是猜测的 API：
 *   - 模块用**具名导出**：{ Config, apply, inject, name }
 *   - Config 用 @deepseek-ai/schemastery 定义，激活时校验该行的 config
 *   - 工具经 ctx.tools.register(defineTool({...})) 注册
 *   - defineTool 的字段：name / description / parameters / output.{schema,render}
 *     / execute(args, exec) / presentCall(args)
 */
import { defineTool } from '@deepseek-ai/dsh-tools'
import z from '@deepseek-ai/schemastery'

/** 插件行 id，出现在 profile 的插件树里。 */
export const name = 'hackathon-starter'

/** 声明依赖的服务：只有拿到 ctx.tools 才会激活本插件。 */
export const inject = ['tools']

/** 该插件行 config 的 schema；改这里就能给插件加可配置项。 */
export const Config = z.object({
  greeting: z.string().default('Hello from a DSH plugin'),
})

const DESCRIPTION =
  'Prove that a custom DSH plugin is loaded and callable: returns the greeting from this plugin\'s config plus the host runtime facts (Node version, platform, working directory, current time).'

/**
 * 注册工具。Cordis 插件约定：所有资源都在 apply 内注册。
 * @param ctx - 插件上下文，携带 tools 注册表。
 * @param config - 该插件行的 config，已按 {@link Config} 校验。
 */
export function apply(ctx, config) {
  // config 可能为空（取决于 patch 是否提供），因此保留运行时兜底。
  const greeting = (config && config.greeting) || 'Hello from a DSH plugin'

  ctx.tools.register(
    defineTool({
      name: 'plugin_ping',
      description: DESCRIPTION,
      parameters: {
        note: {
          type: 'string',
          description: 'Optional text to echo back, to verify argument passing.',
        },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            message: { type: 'string', required: true },
            note: { type: 'string' },
            host: {
              type: 'object',
              additionalProperties: false,
              required: true,
              properties: {
                node: { type: 'string', required: true },
                platform: { type: 'string', required: true },
                cwd: { type: 'string', required: true },
                time: { type: 'string', required: true },
              },
            },
          },
        },
        // render 决定这条工具结果怎么进入对话记录。
        render: (_args, value) => [
          {
            type: 'text',
            text: `${value.message} (node ${value.host.node}, ${value.host.time})`,
          },
        ],
      },
      execute(args) {
        return Promise.resolve({
          message: greeting,
          ...(args.note !== undefined ? { note: args.note } : {}),
          host: {
            node: process.version,
            platform: process.platform,
            cwd: process.cwd(),
            time: new Date().toISOString(),
          },
        })
      },
      presentCall: (args) => ({
        card: 'generic',
        title: 'Plugin ping',
        kind: 'other',
        rawInput: args,
      }),
    }),
  )
}
