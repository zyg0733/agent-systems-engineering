# 固定旧历史生成器

`runtime/` 的四个模块逐字节复制自第 20 周验收源代码冻结快照；SHA-256 与原始路径见 `manifest.json`。它们只在 `lab.upgrade` 新建的隔离数据库、专用子 BEAM 中加载，生成真实前 20 个 SQL migration 的旧库。主 BEAM 从不替换模块。其余业务模块使用当前实现。

此夹具固定的是已验收版本的存储读取、写入和 Ecto schema；业务 Event schema 与 Codec 均为 1。升级后的独立 `history_format=2` 是存储封装格式。请勿格式化或“修复”这些历史文件；校验不符会拒绝生成旧历史。
