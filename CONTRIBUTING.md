# Contributing / 贡献指南

1. 先阅读 `MODEL_AND_MEDIA_RIGHTS.md` 和 `SECURITY.md`。
2. 只提交原创代码、脱敏 JSON 夹具和可核验的文档；禁止提交真实媒体或凭据。
3. 所有路径必须通过参数传入并受 `VideoRoot` 守卫；不要恢复机器特定的绝对路径。
4. 修改脚本后运行全部离线测试，并在 PR 中说明外部服务未被调用。
5. 第三方代码必须保留原许可证并登记在 `THIRD_PARTY_NOTICES.md`。

Pull requests should include the exact offline commands and their output. Do
not claim end-to-end generation unless the external provider setup and media
rights were independently verified.
