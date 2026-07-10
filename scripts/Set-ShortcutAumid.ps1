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
if ($TargetPath) { $lnk.TargetPath = $TargetPath }
if ($PSBoundParameters.ContainsKey('Arguments')) { $lnk.Arguments = $Arguments }
if ($WorkingDirectory) { $lnk.WorkingDirectory = $WorkingDirectory }
if ($IconLocation) { $lnk.IconLocation = $IconLocation }
$lnk.Save()

if (-not $AppUserModelID) {
    # 复刻 chrome_plus src/appid.cc:FNV-1a 64bit,输入为 exe 目录路径的 UTF-16LE 字节
    $exeDir = Split-Path -Parent $lnk.TargetPath
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

    [StructLayout(LayoutKind.Explicit)]
    struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    public static void Set(string lnkPath, string aumid)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        int hr = SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 2 /* GPS_READWRITE */, ref iid, out store);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        PROPERTYKEY key = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
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

[LnkAumid]::Set($ShortcutPath, $AppUserModelID)
Write-Host "已更新 $(Split-Path -Leaf $ShortcutPath) -> AUMID: $AppUserModelID"
