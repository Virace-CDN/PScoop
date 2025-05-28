# https://github.com/chawyehsu/dorado/blob/master/scripts/DoradoUtils.psm1
# Thanks to chawyehsu

#Requires -Version 5.1
Set-StrictMode -Version 3.0
function Mount-ExternalRuntimeData {
    <#
    .SYNOPSIS
        Mount external runtime data

    .PARAMETER Source
        The source path, which is the persist_dir

    .PARAMETER Target
        The target path, which is the actual path app uses to access the runtime data
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Source,
        [Parameter(Mandatory = $true, Position = 1)]
        [string] $Target
    )

    if (Test-Path $Source) {
        Remove-Item $Target -Force -Recurse -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory $Source -Force | Out-Null
        if (Test-Path $Target) {
            Get-ChildItem $Target | Move-Item -Destination $Source -Force
            Remove-Item $Target
        }
    }

    New-Item -ItemType Junction -Path $Target -Target $Source -Force | Out-Null
}

function Dismount-ExternalRuntimeData {
    <#
    .SYNOPSIS
        Unmount external runtime data

    .PARAMETER Target
        The target path, which is the actual path app uses to access the runtime data
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Target
    )

    if (Test-Path $Target) {
        Remove-Item $Target -Force -Recurse
    }
}

function Get-DumplingsInstallerInfo {
    <#
    .SYNOPSIS
        获取 SpecterShell/Dumplings 仓库中的应用安装程序信息

    .DESCRIPTION
        从 SpecterShell/Dumplings 仓库获取指定应用程序的最新版本安装程序信息
        返回所有可用架构（x86、x64、arm64）的安装程序 URL
        如果存在 RealVersion，则使用它作为最终版本号

    .PARAMETER AppId
        应用程序的标识符，例如 "ByteDance.Doubao"

    .EXAMPLE
        Get-DumplingsInstallerInfo -AppId "ByteDance.Doubao"

    .NOTES
        需要 PowerShell-yaml 模块来解析 YAML 内容
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $AppId
    )

    # 构建 State.yaml 文件的 URL
    $stateUrl = "https://github.com/SpecterShell/Dumplings/raw/refs/heads/main/Tasks/$AppId/State.yaml"
    Write-Verbose "State URL: $stateUrl"

    try {
        # 获取 State.yaml 文件内容
        $stateContent = Invoke-WebRequest -Uri $stateUrl -ErrorAction Stop
        $logFileName = $stateContent.Content.Trim()
        Write-Verbose "日志文件名: $logFileName"

        # 构建日志文件的 URL
        $logUrl = "https://github.com/SpecterShell/Dumplings/raw/refs/heads/main/Tasks/$AppId/$logFileName"
        Write-Verbose "日志 URL: $logUrl"

        # 获取并解析日志文件内容
        $logContent = Invoke-WebRequest -Uri $logUrl -ErrorAction Stop
        $installerInfo = ConvertFrom-Yaml $logContent.Content

        # 创建结果对象
        $result = @{}

        # 设置版本号，优先使用 RealVersion（如果存在）
        if ($installerInfo.PSObject.Properties.Name -contains "RealVersion" -and $installerInfo.RealVersion) {
            $result.Version = $installerInfo.RealVersion
            Write-Verbose "使用 RealVersion: $($installerInfo.RealVersion)"
        } else {
            $result.Version = $installerInfo.Version
            Write-Verbose "使用 Version: $($installerInfo.Version)"
        }

        # 遍历所有安装程序，收集不同架构的 URL
        foreach ($installer in $installerInfo.Installer) {
            if ($installer.Architecture -eq "x86") {
                $result.x86 = $installer.InstallerUrl
                Write-Verbose "找到 x86 架构安装程序: $($installer.InstallerUrl)"
            } elseif ($installer.Architecture -eq "x64") {
                $result.x64 = $installer.InstallerUrl
                Write-Verbose "找到 x64 架构安装程序: $($installer.InstallerUrl)"
            } elseif ($installer.Architecture -eq "arm64") {
                $result.arm64 = $installer.InstallerUrl
                Write-Verbose "找到 arm64 架构安装程序: $($installer.InstallerUrl)"
            }
        }

        return $result
    } catch {
        Write-Error "获取应用信息时出错: $_"
        return $null
    }
}

Export-ModuleMember `
    -Function `
    Mount-ExternalRuntimeData, Dismount-ExternalRuntimeData, Get-DumplingsInstallerInfo
