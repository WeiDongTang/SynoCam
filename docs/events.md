# 埋点事件模型：SynoCam

统一 schema：`event_name` + `properties` + `user_id` + `timestamp` + `session_id`

| 事件 | 含义 | 关键属性 | 层级 |
|---|---|---|---|
| `app_launch` | 启动应用 | channel, ab_group | 行为 |
| `register` | 完成注册 | method | 漏斗/转化 |
| `login` | 登录 | method | 行为 |
| `complete_purchase` | 完成付费 | product_id, amount, currency | 漏斗/转化 |
| `add_to_cart` | 加入购物车 | product_id | 漏斗/转化 |
| `share` | 分享 | target | 行为 |
| `logout` | 退出登录 |  | 行为 |

> 命名：动词_名词；枚举常量化；不上报 PII；iOS 需 ATT 授权后取 IDFA。
