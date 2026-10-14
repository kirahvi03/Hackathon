/**
 * Client 半边：往界面里插一个元素，证明前端扩展点也通了。
 *
 * 规则（来自官方模板与 dsh-client-ui-* 实现）：
 *   - 必须经 window.__ModuleLoader__.load({ id, factory }) 注册，id 用包名
 *   - factory 里只能 require PLATFORM_MODULES 提供的模块（react 在其中），
 *     **不允许** require 任何宿主 Client 包（如 dsh-client-ui-primitives），会 crash
 *   - 槽位声明方式：ctx.slots.inject(key, cb) + ctx.slots.register(spec, Component)
 *     不存在 ctx.slots.declare()
 */
window.__ModuleLoader__.load({
  id: '@hackathon/dsh-starter-plugin',
  factory(require) {
    const React = require('react')
    const h = React.createElement

    /** 一个仅用于验证的小徽标。 */
    function HackathonBadge() {
      return h(
        'div',
        {
          title: 'Hackathon starter plugin is loaded',
          style: {
            display: 'inline-flex',
            alignItems: 'center',
            gap: '4px',
            padding: '2px 8px',
            borderRadius: '999px',
            fontSize: '11px',
            lineHeight: '16px',
            color: '#fff',
            background: '#247bbf',
            userSelect: 'none',
          },
        },
        'plugin ok',
      )
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        ctx.slots.inject('conversation.composer.dock', () =>
          ctx.slots.register(
            {
              name: 'conversation.composer.dock',
              id: 'hackathon-starter-badge',
              order: 5,
              label: 'Hackathon badge',
            },
            HackathonBadge,
          ),
        )
      },
    }
  },
})
