# W22 六章与实验修订记录

记录类型：作者与代理的技术核验，**不是外部自然人试读反馈**。用户确认本轮先完成试读包和技术验收；外部人数保持 0，3–5 人与 P5 外部准入待验收。

| 编号 | 实际发现的卡点 | 本轮处理 | 核对方式 |
| --- | --- | --- | --- |
| R01 | book 原来只有 ch20，原计划六章不存在完整可读路径 | 新增 ch02/ch05/ch08/ch14/ch16，修订 ch20；指南明确六章顺序 | 六章实际文件与本地链接检查；章内 Elixir 示例原样执行 |
| R02 | 原计划 L03/L04 等与连续交付编号不同，Session 易被导向文件工具 | 使用现行明确链接，Session→L05、history→L06、effects→L07/L08 | suite 固定章节/实验映射；指南和六章同一表 |
| R03 | Kernel 拒绝 turn 上限容易被误写为直接进入 failed | ch02 区分 reducer 拒绝与 RunServer 显式 fail | 原样纯值示例与对应测试 |
| R04 | storage:postgres 容易被推导成进程内 Provider/Budget 自动恢复 | ch05/ch08 明确 RunServer 与 Recovery/TaskBudgetStore 边界 | 原源码/测试链接和 P1 内存示例；不改变预算实现 |
| R05 | 早期 L06 的当周描述“没有迁移器”容易被当现状 | ch14 与 L06 增加 W21 显式 layout 1→2 链接，Event/Codec仍v1 | L20 与版本校验源码对应 |
| R06 | checkpoint 被误认为跳过全历史验证，replay/rebuild/resume易混用 | ch14 明确前缀完整校验与纯 rebuild；resume 单独有执行权 | 原历史/模型录制测试与独立 BEAM 命令 |
| R07 | ch20 旧稿省略命名队列 Queue→Run→Intent 锁序和容量口径 | 补入锁序、槽位/有效lease/queuequota/unknown占位边界 | 源码逐符号校对；fencing、背压实验链接 |
| R08 | 默认输出目录重复会失败；长期 export 内存开关污染后续实验 | 六章/指南使用唯一 --output 和命令级内存前缀 | 现行 CLI 参数核对与拒绝覆盖测试 |
| R09 | DATABASE_URL 或 Mix/Hex/build 继承项可能连接原环境 | Reproduction固定环境plan；清除继承项，独立端口/路径/PGDATA | 实际干净复现日志、cluster identity、空库和新迁移证据 |
| R10 | 第一个反馈添加逻辑的with错误；绝对路径根目录拼接错误 | 修复谓词和路径根处理，加入首反馈/重复/路径测试 | ReaderStudy专项；失败首轮日志保留 |
| R11 | 自洽重算protocol可改章节；旧损坏report可被覆盖 | 固定suite、导出manifest和完整assets绑定；覆盖前验证旧report shape/hash | 篡改/标量/旧报告保留测试 |
| R12 | 五份合法反馈汇总超过单条JSON上限 | 单条256KiB、报告2MiB分别限制 | >256KiB合法报告连续report两次测试 |
| R13 | 先mkdir_p再查祖先symlink会在拒绝前留子目录 | 逐级核对既有祖先，再mkdir；拒绝无副作用 | owned临时目录probe与回归测试 |
| R14 | macOS大小写与NFC/NFD别名可绕过字符串source前缀 | 创建前比较所有selected目录与目标祖先的设备/inode | 两项回归及另一次独立纯probe；源manifest不变、无nested副本 |
| R16 | 干净集群初始化核验时，PGSERVICE空字符串被libpq当成空服务名 | 将可选路由变量改为nil/unset，保留失败日志并精确停止初次cluster；在全新目录重跑 | 固定环境回归断言与第二次真实干净复现 |
| R17 | umask077下复制夹具的目录mode改变，固定chmod0600不一定是权限变化；两个旧测试假定100ms/20ms时间窗口 | 仅修测试夹具保留目录mode、相对原mode切换；旧异步kill用有界5s等待，队列断言精确核对已服务low而不假定其他Run未变老 | 两个新工具在umask077分别22/17通过；旧专项与最终完整复现；业务运行时不改 |
| R18 | 相同状态和成本的重复评测仍可能触发真实latency回归，旧Demo错误要求耗时也必过门槛 | 仅修EvalDemo验收口径，保留Comparison默认门槛及真实passed/status/latency；报告明确不声称耗时可重复 | 新纯测试实际构造全局/单task延迟回归、质量退步、unknowncost与缺失检查；5项含60样本native测试通过 |
| R15 | 模板/自动检查容易被汇总为读者人数 | 双gate明确区分技术与真人，正式0人、P5 false | 合成测试只在临时目录并清理；正式报告只收实际反馈 |

技术核验原始记录：[A组](reader-review-a.md)、[B组](reader-study-review-b.md)。两者负责章稿与源码检查，不是读者访谈。A组逐章代码、8个相邻测试116 passed、Streaming三分支、离线repair和P1 --memory已实际执行。B组运行ch14纯值例，核对69个链接和现行CLI，并独立验证R14修复。

本周尚未获得真人对易读性、耗时、操作卡点分布或主实验独立完成率的原始数据，不为这些指标填0成功率或估计耗时。后续收到反馈后，以同一protocol保留原始记录，按位置、严重性、期望/实际结果和修复证据汇总；blocker未解决时外部gate不得通过。协议修订要重新冻结版本，不能把旧读者记录无条件挪到新hash。

缓存provenance描述执行前输入：Hex会正常重写`hex/cache.ets`。正式记录保留初始registry原字节及使用后hash；安装archive、包、Hex/Rebar工具仍逐项校验，不能因registry预期变化而忽略其他输入漂移。
