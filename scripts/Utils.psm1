# https://github.com/chawyehsu/dorado/blob/master/scripts/DoradoUtils.psm1
# Thanks to chawyehsu

#Requires -Version 5.1
Set-StrictMode -Version 3.0

function Test-RuntimeDataJunction {
    param($Item, [string] $Source)
    if ($Item.LinkType -ne 'Junction' -or @($Item.Target).Count -ne 1) { return $false }
    return [IO.Path]::GetFullPath([string]@($Item.Target)[0]).TrimEnd('\') -eq [IO.Path]::GetFullPath($Source).TrimEnd('\')
}

function Mount-ExternalRuntimeData {
    <#
    .SYNOPSIS
        将运行数据合并迁入持久目录，再创建指向持久目录的 junction。
    .PARAMETER Source
        持久目录。同名文件内容不同时停止迁移，不覆盖任意一份数据。
    .PARAMETER Target
        应用实际使用的运行目录。仅在数据迁移完成后删除原目录。
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)][string] $Source,
        [Parameter(Mandatory = $true, Position = 1)][string] $Target
    )
    $ErrorActionPreference = 'Stop'
    $Source = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $Target = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    if ($Source -eq $Target -or $Source.StartsWith($Target + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $Target.StartsWith($Source + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '持久目录与运行目录必须是互不包含的独立路径。'
    }
    $saved = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    $existing = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if ($saved -and (!$saved.PSIsContainer -or ($saved.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "持久路径不是普通目录：$Source"
    }
    if ($existing -and ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if (!(Test-RuntimeDataJunction -Item $existing -Source $Source) -or !$saved) {
            throw "拒绝替换陌生或失效链接：$Target"
        }
        return
    }
    if ($existing -and !$existing.PSIsContainer) { throw "运行数据路径不是目录：$Target" }
    $entries = @()
    if ($existing) {
        $entries = @(Get-ChildItem -LiteralPath $Target -Recurse -Force)
        if ($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
            throw "运行数据包含链接，请先手动处理：$Target"
        }
        # 先检查整棵目录树，避免迁移一半才发现文件冲突或跨链接写入。
        foreach ($entry in $entries) {
            $destination = Join-Path $Source $entry.FullName.Substring($Target.Length + 1)
            $other = Get-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            if (!$other) { continue }
            if (($other.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $other.PSIsContainer -ne $entry.PSIsContainer) {
                throw "数据路径冲突：$($entry.FullName) / $destination"
            }
            if (!$entry.PSIsContainer -and ((Get-FileHash -LiteralPath $entry.FullName).Hash -ne (Get-FileHash -LiteralPath $destination).Hash)) {
                throw "同名文件内容不同，请先处理冲突：$($entry.FullName) / $destination"
            }
        }
    }
    New-Item -ItemType Directory -Path $Source, (Split-Path $Target) -Force | Out-Null
    foreach ($entry in $entries | Where-Object PSIsContainer) {
        New-Item -ItemType Directory -Path (Join-Path $Source $entry.FullName.Substring($Target.Length + 1)) -Force | Out-Null
    }
    foreach ($entry in $entries | Where-Object { !$_.PSIsContainer }) {
        $destination = Join-Path $Source $entry.FullName.Substring($Target.Length + 1)
        if (!(Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $entry.FullName -Destination $destination
        }
    }
    if ($existing) {
        # 剩余文件应当仅为两边内容相同的副本；再次核验后才删除原件。
        foreach ($file in Get-ChildItem -LiteralPath $Target -Recurse -Force -File) {
            $destination = Join-Path $Source $file.FullName.Substring($Target.Length + 1)
            if (!(Test-Path -LiteralPath $destination -PathType Leaf) -or
                (Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) {
                throw "迁移期间数据发生变化，已保留剩余文件：$($file.FullName)"
            }
            Remove-Item -LiteralPath $file.FullName -Force
        }
        # 只删除空目录；迁移失败或出现新文件时不会递归删除剩余数据。
        foreach ($directory in Get-ChildItem -LiteralPath $Target -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending) {
            [IO.Directory]::Delete($directory.FullName)
        }
        [IO.Directory]::Delete($Target)
    }
    New-Item -ItemType Junction -Path $Target -Target $Source | Out-Null
}

function Dismount-ExternalRuntimeData {
    <#
    .SYNOPSIS
        只移除运行目录的 junction，保留持久数据和普通目录。
    .PARAMETER Target
        应用实际使用的运行目录。
    .PARAMETER Source
        可选的预期持久目录；指定后仅移除指向该目录的 junction。
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)][string] $Target,
        [string] $Source
    )
    $ErrorActionPreference = 'Stop'
    $item = Get-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'Junction' -and (!$Source -or (Test-RuntimeDataJunction -Item $item -Source $Source))) {
        [IO.Directory]::Delete([IO.Path]::GetFullPath($Target))
    } elseif ($item) {
        Write-Warning "保留普通目录或非预期链接：$Target"
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

        # 添加调试信息
        Write-Verbose "对象类型: $($installerInfo.GetType().FullName)"
        Write-Verbose "所有属性: $($installerInfo.PSObject.Properties.Name -join ', ')"

        # 根据对象类型选择不同的检查方法
        $hasRealVersion = if ($installerInfo -is [hashtable] -or $installerInfo -is [System.Collections.IDictionary]) {
            $installerInfo.ContainsKey("RealVersion")
        } else {
            $installerInfo.PSObject.Properties.Name -contains "RealVersion"
        }

        Write-Verbose "RealVersion存在: $hasRealVersion"
        if ($hasRealVersion) {
            Write-Verbose "RealVersion值: $($installerInfo.RealVersion)"
        }
        Write-Verbose "Version值: $($installerInfo.Version)"

        # 设置版本号，优先使用 RealVersion（如果存在）
        if ($hasRealVersion -and $installerInfo.RealVersion) {
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
