<#
.SYNOPSIS
    通过官方 TaskbarManager API 请求把应用固定到任务栏(Windows 弹原生确认框,用户点一次)。

.DESCRIPTION
    需要 Windows PowerShell 5.1(WinRT 投影),scoop post_install 里请用
    `powershell -NoProfile -File ...` 显式调用(pwsh 7 无内置 WinRT 投影)。

    原理:
    1. 把当前进程 AUMID 设置为目标应用运行时的 AUMID
       (chrome++ 规则:"ChromePlusNext." + FNV-1a-64(exe 目录路径 UTF-16LE) 大写 hex);
    2. 调用 TaskbarManager.RequestPinCurrentAppAsync(),Windows 按 AUMID 匹配
       开始菜单快捷方式生成固定项——因此调用前开始菜单 .lnk 必须已由
       Set-ShortcutAumid.ps1 写入同款 AUMID。

    KB5074105(Build 26100.7705 / 26200.7705,2026-01)起无需 LAF token。
    不满足条件(旧系统 / 策略禁止 / 用户拒绝 / 无人应答超时)时安静退出,不阻塞安装。

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

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AppId {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    public static extern void SetCurrentProcessExplicitAppUserModelID(string appId);
}
"@
    [AppId]::SetCurrentProcessExplicitAppUserModelID($AppUserModelID)

    $null = [Windows.UI.Shell.TaskbarManager, Windows.UI.Shell, ContentType = WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

    function Await($winRtTask, $resultType) {
        $asTask = $asTaskGeneric.MakeGenericMethod($resultType)
        $netTask = $asTask.Invoke($null, @($winRtTask))
        if (-not $netTask.Wait(90000)) { throw '等待固定确认超时(90s 无人应答)' }
        return $netTask.Result
    }

    $tm = [Windows.UI.Shell.TaskbarManager]::GetDefault()
    if (-not $tm.IsSupported -or -not $tm.IsPinningAllowed) {
        Write-Host "任务栏固定 API 不可用(IsSupported=$($tm.IsSupported), IsPinningAllowed=$($tm.IsPinningAllowed)),跳过自动固定。"
        exit 0
    }

    if (Await ($tm.IsCurrentAppPinnedAsync()) ([bool])) {
        Write-Host "已在任务栏固定($AppUserModelID),无需操作。"
        exit 0
    }

    Write-Host '请求固定到任务栏,请在弹出的 Windows 确认框中点击确认...'
    $ok = Await ($tm.RequestPinCurrentAppAsync()) ([bool])
    if ($ok) {
        Write-Host "已固定到任务栏($AppUserModelID)。"
    } else {
        Write-Host '固定请求未完成(被拒绝或不可用);可稍后手动固定:启动应用后右键任务栏图标选择固定。'
    }
} catch {
    Write-Host "自动固定失败:$($_.Exception.Message);可稍后手动固定。"
    exit 0
}
