<#
.SYNOPSIS
    QQ-NT 安装和卸载工具函数
.DESCRIPTION
    提供 QQ-NT 安装、配置和卸载过程中需要的各种工具函数
#>

function Initialize-QQNT {
    <#
    .SYNOPSIS
        初始化 QQ-NT 配置
    .DESCRIPTION
        设置 QQ-NT 的数据存储路径，更新注册表信息，处理用户数据迁移
    .PARAMETER PersistDir
        持久化数据目录路径
    .PARAMETER Version
        QQ-NT 的版本号
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $PersistDir,

        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    # 1. 设置配置文件
    $configFile = "$env:PUBLIC\Documents\Tencent\QQ\UserDataInfo.ini"
    $configDir = Split-Path $configFile -Parent

    if (!(Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $iniContent = @"
[UserDataSet]
UserDataSavePathType=2
UserDataSavePath=$PersistDir\Tencent Files
"@

    Set-Content -Path $configFile -Value $iniContent -Force
    Write-Host "已配置 QQ-NT 数据存储路径: $PersistDir\Tencent Files" -ForegroundColor Cyan

    # 2. 更新注册表版本信息
    $regPath = 'HKCU:\Software\Tencent\QQNT'
    if (!(Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name 'version' -Value $Version -PropertyType String -Force | Out-Null
    Write-Host "已更新注册表版本信息: $Version" -ForegroundColor Cyan

    # 3. 处理用户数据迁移
    $userTencentFiles = "$env:USERPROFILE\Documents\Tencent Files"
    $persistTencentFiles = "$PersistDir\Tencent Files"

    if (Test-Path $userTencentFiles) {
        if (!(Test-Path $persistTencentFiles)) {
            New-Item -ItemType Directory -Path $persistTencentFiles -Force | Out-Null
        }

        # 获取用户目录下的文件夹，排除 "1" 和 "nt_qq"
        $userFolders = Get-ChildItem -Path $userTencentFiles -Directory |
                       Where-Object { $_.Name -ne '1' -and $_.Name -ne 'nt_qq' }

        # 获取持久化目录下的文件夹名称列表
        $persistFolders = Get-ChildItem -Path $persistTencentFiles -Directory |
                          ForEach-Object { $_.Name }

        # 找出冲突的文件夹（两边都有的）
        $conflictFolders = $userFolders | Where-Object { $persistFolders -contains $_.Name }

        # 找出需要迁移的新文件夹（用户目录有但持久化目录没有的）
        $newFolders = $userFolders | Where-Object { $persistFolders -notcontains $_.Name }

        # 处理冲突文件夹
        if ($conflictFolders) {
            Write-Host "警告: 发现冲突的QQ数据文件夹，请手动迁移以下文件夹的数据:" -ForegroundColor Yellow
            $conflictFolders | ForEach-Object { Write-Host "  - $($_.FullName)" }
        }

        # 处理新文件夹
        if ($newFolders) {
            Write-Host "发现新的QQ数据文件夹，正在复制到持久化目录..." -ForegroundColor Cyan
            $newFolders | ForEach-Object {
                Write-Host "  - 复制 $($_.Name) 到 $persistTencentFiles"
                Copy-Item -Path $_.FullName -Destination "$persistTencentFiles\$($_.Name)" -Recurse -Force
            }
            Write-Host "复制完成。请手动删除原始数据文件夹中的数据以节省空间。" -ForegroundColor Green
        }
    }
}

function Uninstall-QQNT {
    <#
    .SYNOPSIS
        卸载 QQ-NT 时的清理操作
    .DESCRIPTION
        删除 QQ-NT 的配置文件夹和注册表项
    #>
    [CmdletBinding()]
    param ()

    # 删除配置文件夹
    $tencentFolder = "$env:PUBLIC\Documents\Tencent"
    if (Test-Path $tencentFolder) {
        Remove-Item -Path $tencentFolder -Recurse -Force
        Write-Host "已删除 $tencentFolder" -ForegroundColor Cyan
    }

    # 删除注册表项
    $regPath = 'HKCU:\Software\Tencent\QQNT'
    if (Test-Path $regPath) {
        Remove-Item -Path $regPath -Recurse -Force
        Write-Host "已删除注册表项 $regPath" -ForegroundColor Cyan
    }
}

# 导出函数
Export-ModuleMember -Function Initialize-QQNT, Uninstall-QQNT
