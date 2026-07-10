<#
.SYNOPSIS
    通过官方 TaskbarManager API 请求把应用固定到任务栏(Windows 弹原生确认框,用户点一次)。

.DESCRIPTION
    需要 Windows PowerShell 5.1(WinRT 投影),scoop post_install 里请用
    `powershell -NoProfile -Sta -File ...` 显式调用(pwsh 7 无内置 WinRT 投影)。

    关键前提(实测,微软文档亦载明):TaskbarManager 只有在**调用进程本身处于前台**时
    IsPinningAllowed 才为 True——这与目标应用是否运行无关。安装器/后台脚本天然不在前台,
    故本脚本先创建一个屏幕外的置顶小窗口并抢占前台,再调用固定 API;用户只会看到系统
    原生的固定确认框,看不到该辅助窗口。

    原理:
    1. 把当前进程 AUMID 设置为目标应用运行时的 AUMID
       (chrome++ 规则:"ChromePlusNext." + FNV-1a-64(exe 目录路径 UTF-16LE) 大写 hex);
    2. 建前台窗口满足"应用在前台"前提;
    3. 调 TaskbarManager.RequestPinCurrentAppAsync(),Windows 按 AUMID 匹配开始菜单
       快捷方式生成固定项——因此调用前开始菜单 .lnk 必须已由 Set-ShortcutAumid.ps1
       写入同款 AUMID。

    KB5074105(Build 26100.7705 / 26200.7705,2026-01)起无需 LAF token。
    任何前提不满足(旧系统 / 策略禁止 / 用户拒绝 / 超时)都安静退出,不阻塞安装。

.PARAMETER AppDir
    应用 exe 所在目录(应为 current junction 路径),用于按 chrome++ 算法计算 AUMID。

.PARAMETER AppUserModelID
    直接指定 AUMID,优先于 AppDir。
#>
param(
    [string]$AppDir,
    [string]$AppUserModelID
)

$ErrorActionPreference = 'Stop'

if (-not $AppUserModelID) {
    if (-not $AppDir) { throw 'AppDir 或 AppUserModelID 必须提供一个' }
    $mask = [System.Numerics.BigInteger]::Parse('FFFFFFFFFFFFFFFF', 'AllowHexSpecifier')
    $hash = [System.Numerics.BigInteger]::Parse('14695981039346656037')
    $prime = [System.Numerics.BigInteger]::Parse('1099511628211')
    foreach ($b in [System.Text.Encoding]::Unicode.GetBytes($AppDir)) {
        $hash = ($hash -bxor $b) * $prime -band $mask
    }
    $hex = $hash.ToString('X16')
    $AppUserModelID = 'ChromePlusNext.' + $hex.Substring($hex.Length - 16)
}

$form = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PinNative {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    public static extern void SetCurrentProcessExplicitAppUserModelID(string id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    // 在前台锁定下也尽量把自己的窗口抬到前台:临时挂接当前前台线程输入队列
    public static void ForceForeground(IntPtr h) {
        IntPtr fg = GetForegroundWindow();
        uint dummy; uint fgThread = GetWindowThreadProcessId(fg, out dummy);
        uint cur = GetCurrentThreadId();
        if (fgThread != cur) AttachThreadInput(cur, fgThread, true);
        ShowWindow(h, 5); // SW_SHOW
        BringWindowToTop(h);
        SetForegroundWindow(h);
        SetActiveWindow(h);
        if (fgThread != cur) AttachThreadInput(cur, fgThread, false);
    }
    public static bool IsForeground(IntPtr h) { return GetForegroundWindow() == h; }
}
"@

    [PinNative]::SetCurrentProcessExplicitAppUserModelID($AppUserModelID)

    # 屏幕外置顶小窗口:满足"应用在前台"前提,用户不可见
    $form = [System.Windows.Forms.Form]::new()
    $form.FormBorderStyle = 'None'
    $form.Size = [System.Drawing.Size]::new(1, 1)
    $form.StartPosition = 'Manual'
    $form.Location = [System.Drawing.Point]::new(-3000, -3000)
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.Add_Shown({ [PinNative]::ForceForeground($form.Handle) })
    $form.Show()

    $null = [Windows.UI.Shell.TaskbarManager, Windows.UI.Shell, ContentType = WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

    # 用消息泵等待异步,保持 STA 与窗口前台状态,避免 .Wait() 阻塞导致固定框卡住
    function Wait-WinRt($op, [Type]$resultType) {
        $task = $asTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
        $deadline = (Get-Date).AddSeconds(120)
        while (-not $task.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
            if ((Get-Date) -gt $deadline) { throw '等待固定确认超时(120s 无人应答)' }
        }
        if ($task.IsFaulted) { throw $task.Exception }
        return $task.Result
    }

    $tm = [Windows.UI.Shell.TaskbarManager]::GetDefault()
    if (-not $tm.IsSupported) {
        Write-Host "任务栏固定 API 不受支持(需 Windows 11 24H2 及以上),跳过自动固定。"
        return
    }

    if (Wait-WinRt ($tm.IsCurrentAppPinnedAsync()) ([bool])) {
        Write-Host "已在任务栏固定($AppUserModelID),无需操作。"
        return
    }

    # IsPinningAllowed 要求调用进程持有前台窗口;SetForegroundWindow 有竞态,
    # 反复抢前台并轮询,直到真正拿到前台+可固定,或超时放弃(不阻塞安装)。
    $allowed = $false
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        [PinNative]::ForceForeground($form.Handle)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
        if ([PinNative]::IsForeground($form.Handle) -and $tm.IsPinningAllowed) { $allowed = $true; break }
    }
    if (-not $allowed) {
        Write-Host "任务栏固定暂不可用(未能取得前台或被策略禁止)。"
        Write-Host '可稍后手动固定:启动应用后右键任务栏图标选择固定。'
        return
    }

    Write-Host '请求固定到任务栏,请在弹出的 Windows 确认框中点击确认...'
    $ok = Wait-WinRt ($tm.RequestPinCurrentAppAsync()) ([bool])
    if ($ok) {
        Write-Host "已固定到任务栏($AppUserModelID)。"
    } else {
        Write-Host '固定请求未完成(被拒绝或不可用);可稍后手动固定:启动应用后右键任务栏图标选择固定。'
    }
} catch {
    Write-Host "自动固定失败:$($_.Exception.Message);可稍后手动固定。"
    exit 0
} finally {
    if ($form) { $form.Close(); $form.Dispose() }
}
