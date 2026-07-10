<#
.SYNOPSIS
    修复 Chrome 系快捷方式的任务栏归组:更新 .lnk 的目标等字段,并写入
    System.AppUserModel.ID 属性,使其与 chrome++ 运行时设置的进程 AUMID 一致。

.DESCRIPTION
    chrome++ (Bush2021/chrome_plus, src/appid.cc) 会 hook
    SetCurrentProcessExplicitAppUserModelID,把浏览器进程的 AUMID 强制替换为:
        "ChromePlusNext." + FNV-1a-64(exe 所在目录路径的 UTF-16LE 字节) 的大写十六进制
    exe 目录按启动时的字面路径取值(junction 不会被解析),因此只要快捷方式
    始终指向 <app>\current\chrome.exe,AUMID 就跨版本稳定,任务栏固定图标
    与运行窗口永久归组,升级无感。

    本脚本被 bucket 内 chrome / chrome-beta / chrome-canary 的 post_install 调用。

.PARAMETER ShortcutPath
    要处理的 .lnk 完整路径;不存在则静默跳过。

.PARAMETER TargetPath
    可选,新的目标路径(应指向 current junction 下的 chrome.exe)。

.PARAMETER Arguments
    可选,启动参数;显式传空字符串会清空原有参数。

.PARAMETER WorkingDirectory
    可选,工作目录。

.PARAMETER IconLocation
    可选,图标位置(如 "...\chrome.exe,4")。

.PARAMETER AppUserModelID
    可选,显式指定 AUMID;缺省时按 chrome++ 算法从目标 exe 目录计算。
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ShortcutPath,
    [string]$TargetPath,
    [string]$Arguments,
    [string]$WorkingDirectory,
    [string]$IconLocation,
    [string]$AppUserModelID
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ShortcutPath)) {
    return
}

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($ShortcutPath)

$desiredTarget = if ($TargetPath) { $TargetPath } else { $lnk.TargetPath }
$desiredArgs = if ($PSBoundParameters.ContainsKey('Arguments')) { $Arguments } else { $lnk.Arguments }
$desiredWorkDir = if ($WorkingDirectory) { $WorkingDirectory } else { $lnk.WorkingDirectory }
$desiredIcon = if ($IconLocation) { $IconLocation } else { $lnk.IconLocation }

if (-not $AppUserModelID) {
    # 复刻 chrome_plus src/appid.cc:FNV-1a 64bit,输入为 exe 目录路径的 UTF-16LE 字节
    $exeDir = Split-Path -Parent $desiredTarget
    $mask = [System.Numerics.BigInteger]::Parse('FFFFFFFFFFFFFFFF', 'AllowHexSpecifier')
    $hash = [System.Numerics.BigInteger]::Parse('14695981039346656037')
    $prime = [System.Numerics.BigInteger]::Parse('1099511628211')
    foreach ($b in [System.Text.Encoding]::Unicode.GetBytes($exeDir)) {
        $hash = ($hash -bxor $b) * $prime -band $mask
    }
    $hex = $hash.ToString('X16')
    $AppUserModelID = 'ChromePlusNext.' + $hex.Substring($hex.Length - 16)
}

if (-not ([System.Management.Automation.PSTypeName]'LnkAumid').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class LnkAumid
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr zone, uint flags, ref Guid iid, [Out, MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        int GetCount(out uint count);
        int GetAt(uint index, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        int Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROPERTYKEY { public Guid fmtid; public uint pid; }

    // 真实 PROPVARIANT 在 x64 上为 24 字节(vt + 3 个保留 ushort + 16 字节联合体);
    // Size 不足时 GetValue 会越界写入导致未定义行为(读取结果随进程随机为空)。
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
        [FieldOffset(16)] public IntPtr reserved;
    }

    static PROPERTYKEY AumidKey()
    {
        return new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
    }

    public static string Get(string lnkPath)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        int hr = SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 0 /* GPS_DEFAULT */, ref iid, out store);
        if (hr != 0) return null;
        try
        {
            PROPERTYKEY key = AumidKey();
            PROPVARIANT pv;
            store.GetValue(ref key, out pv);
            if (pv.vt == 31 && pv.pointerValue != IntPtr.Zero)
                return Marshal.PtrToStringUni(pv.pointerValue);
            return null;
        }
        finally
        {
            Marshal.ReleaseComObject(store);
        }
    }

    public static void Set(string lnkPath, string aumid)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        int hr = SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 2 /* GPS_READWRITE */, ref iid, out store);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        PROPERTYKEY key = AumidKey();
        PROPVARIANT pv = new PROPVARIANT { vt = 31 /* VT_LPWSTR */, pointerValue = Marshal.StringToCoTaskMemUni(aumid) };
        try
        {
            hr = store.SetValue(ref key, ref pv);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            hr = store.Commit();
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        }
        finally
        {
            Marshal.FreeCoTaskMem(pv.pointerValue);
            Marshal.ReleaseComObject(store);
        }
    }
}
"@
}

# 内容已全部正确时绝不写文件:explorer 会在下次同步任务栏时丢弃被改写过的固定项,
# 稳态下(目标 current + AUMID 恒定)每次升级都不应产生任何写入。
$currentAumid = [LnkAumid]::Get($ShortcutPath)
if (($lnk.TargetPath -eq $desiredTarget) -and
    ($lnk.Arguments -eq $desiredArgs) -and
    ($lnk.WorkingDirectory -eq $desiredWorkDir) -and
    ($lnk.IconLocation -eq $desiredIcon) -and
    ($currentAumid -eq $AppUserModelID)) {
    Write-Host "无需变更 $(Split-Path -Leaf $ShortcutPath)(AUMID: $AppUserModelID)"
    return
}

$lnk.TargetPath = $desiredTarget
$lnk.Arguments = $desiredArgs
$lnk.WorkingDirectory = $desiredWorkDir
if ($desiredIcon) { $lnk.IconLocation = $desiredIcon }
$lnk.Save()
[LnkAumid]::Set($ShortcutPath, $AppUserModelID)
Write-Host "已更新 $(Split-Path -Leaf $ShortcutPath) -> AUMID: $AppUserModelID"
