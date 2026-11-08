# 任务栏状态与面板回归检查

从仓库根目录运行。编译和队列测试需要 .NET 10 SDK；WPF 检查需要 Windows、.NET Framework 4.8 和 Windows PowerShell 5.1。

```powershell
dotnet build src/GlassBoard.csproj -c Release
dotnet run --project tests/TaskbarState/TaskbarRegression.csproj -c Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File tests/verify-taskbar-controller.ps1 -AssemblyPath src/bin/Release/net48/GlassBoard.exe
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File tests/verify-popup.ps1 -AssemblyPath src/bin/Release/net48/GlassBoard.exe
```

- 队列测试直接编译生产代码，检查连续切换、保留其他状态位、原子翻转、写入拒绝、超时、阻塞调用不堆积和响应恢复。
- 控制器检查加载编译后的程序集，注入模拟任务栏接口并使用临时数据目录，检查启动采用系统状态、外部修改同步、读回确认后保存、失败保留偏好及旧恢复记录归档。
- 面板检查会短暂显示测试窗口，检查异步图标加载前后弹层尺寸和坐标稳定、双向面板互斥，以及亮度不支持、恢复支持和主动隐藏三种状态。数据写入独立临时目录。

这些检查不修改当前 Windows 任务栏设置，不覆盖用户的正式配置。它们不能代替整机重启、多显示器和不同 DPI 下的人工验证。
