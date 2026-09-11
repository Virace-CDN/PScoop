```pwsh
scoop bucket add pscoop https://github.com/Virace-CDN/PScoop
scoop install pscoop/<manifestname>
```

清单位于 `bucket/`，共享安装与卸载方法位于 `scripts/Utils.psm1`。
检查版本使用 `./bin/checkver.ps1 <manifestname>`；`./bin/test.ps1` 运行 Scoop 测试，需要脚本声明的 Pester 和 BuildHelpers 模块。

`lolhexguide` 安装时复制 `third-party/HuyaLolLauncher.exe`，启动器源码由独立的 huyalol 项目维护；本地可直接运行 `scoop install ./bucket/lolhexguide.json`。
