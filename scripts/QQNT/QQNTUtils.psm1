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

    # 检查是否已存在配置文件，并且已经设置了自定义路径
    $customPathAlreadySet = $false
    $originalUserDataPath = $null

    if (Test-Path $configFile) {
        $iniContent = Get-Content $configFile -Raw
        if ($iniContent -match 'UserDataSavePathType=2') {
            $customPathAlreadySet = $true
            # 尝试提取原始路径
            if ($iniContent -match 'UserDataSavePath=(.+)') {
                $originalUserDataPath = $matches[1].Trim()
                Write-Host "检测到已有自定义数据路径: $originalUserDataPath" -ForegroundColor Yellow
                Write-Host "建议路径: $PersistDir\Tencent Files" -ForegroundColor Yellow
                Write-Host "为避免数据丢失，请手动将数据从当前路径迁移到建议路径，然后修改配置文件。" -ForegroundColor Yellow
            }
        }
    }

    if (!$customPathAlreadySet) {
        # 如果没有设置自定义路径，则创建配置文件
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
    }

    # 2. 更新注册表版本信息 (HKCU)
    $regPath = 'HKCU:\Software\Tencent\QQNT'
    if (!(Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name 'version' -Value $Version -PropertyType String -Force | Out-Null
    Write-Host "已更新HKCU注册表版本信息: $Version" -ForegroundColor Cyan

    # 2.1 更新64位系统注册表信息 (HKLM)
    $regPathSystem = 'HKLM:\SOFTWARE\WOW6432Node\Tencent\QQNT'
    $previousVersion = $Version  # 默认情况下，如果注册表为空，三个版本值相同

    # 检查注册表项是否存在，获取原有的version值作为PreviousVersion
    if (Test-Path $regPathSystem) {
        try {
            $existingVersion = Get-ItemProperty -Path $regPathSystem -Name 'version' -ErrorAction SilentlyContinue
            if ($existingVersion -and $existingVersion.version) {
                $previousVersion = $existingVersion.version
                Write-Host "检测到已有版本: $previousVersion" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "无法读取已有版本信息，将使用当前版本作为PreviousVersion" -ForegroundColor Yellow
        }
    } else {
        New-Item -Path $regPathSystem -Force | Out-Null
    }

    # 更新系统注册表中的版本信息
    New-ItemProperty -Path $regPathSystem -Name 'version' -Value $Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regPathSystem -Name 'rversion' -Value $Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regPathSystem -Name 'PreviousVersion' -Value $previousVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regPathSystem -Name 'Install' -Value $PersistDir -PropertyType String -Force | Out-Null

    Write-Host "已更新HKLM注册表信息:" -ForegroundColor Cyan
    Write-Host "  - 安装路径: $PersistDir" -ForegroundColor Cyan
    Write-Host "  - 当前版本: $Version" -ForegroundColor Cyan
    Write-Host "  - 上一版本: $previousVersion" -ForegroundColor Cyan

    # 3. 处理用户数据迁移
    # 只有在没有设置自定义路径时才进行数据迁移
    if (!$customPathAlreadySet) {
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
}

function Uninstall-QQNT {
    <#
    .SYNOPSIS
        卸载 QQ-NT 时的清理操作
    .DESCRIPTION
        删除 QQ-NT 的配置文件夹和注册表项，提供数据保护提示
    #>
    [CmdletBinding()]
    param ()

    # 检查配置文件，提取用户数据路径
    $configFile = "$env:PUBLIC\Documents\Tencent\QQ\UserDataInfo.ini"
    $tencentFolder = "$env:PUBLIC\Documents\Tencent"
    $userDataPath = $null

    if (Test-Path $configFile) {
        try {
            $iniContent = Get-Content $configFile -Raw -ErrorAction SilentlyContinue
            if ($iniContent -match 'UserDataSavePathType=2' -and $iniContent -match 'UserDataSavePath=(.+)') {
                $userDataPath = $matches[1].Trim()

                Write-Host "警告: 检测到自定义数据路径: $userDataPath" -ForegroundColor Yellow
                Write-Host "该路径可能包含您的聊天记录和其他重要数据。" -ForegroundColor Yellow
                Write-Host "卸载程序不会删除此路径下的数据，如需彻底删除，请手动操作。" -ForegroundColor Yellow
                Write-Host ""
            }
        } catch {
            Write-Host "无法读取配置文件，继续卸载过程..." -ForegroundColor Yellow
        }
    }

    # 删除配置文件夹
    if (Test-Path $tencentFolder) {
        Remove-Item -Path $tencentFolder -Recurse -Force
        Write-Host "已删除配置文件夹: $tencentFolder" -ForegroundColor Cyan
    }

    # 删除用户注册表项
    $regPath = 'HKCU:\Software\Tencent\QQNT'
    if (Test-Path $regPath) {
        Remove-Item -Path $regPath -Recurse -Force
        Write-Host "已删除用户注册表项: $regPath" -ForegroundColor Cyan
    }

    # 删除系统注册表项
    $regPathSystem = 'HKLM:\SOFTWARE\WOW6432Node\Tencent\QQNT'
    if (Test-Path $regPathSystem) {
        Remove-Item -Path $regPathSystem -Recurse -Force
        Write-Host "已删除系统注册表项: $regPathSystem" -ForegroundColor Cyan
    }

    # 提示用户关于数据文件的处理
    if ($userDataPath) {
        Write-Host "\n卸载完成，但您的QQ数据文件仍保留在: $userDataPath" -ForegroundColor Green
        Write-Host "如果您不再需要这些数据，可以手动删除该目录。" -ForegroundColor Green
    } else {
        Write-Host "\n卸载完成。" -ForegroundColor Green
    }
}

# 导出函数
Export-ModuleMember -Function Initialize-QQNT, Uninstall-QQNT
