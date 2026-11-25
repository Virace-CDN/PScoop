Import-Module "$PSScriptRoot\..\TelegramUpdates.psm1" -ErrorAction Stop

$downloadHosts = @('qqdl.gtimg.cn', 'dldir1.qq.com', 'dldir1v6.qq.com', 'downv6.qq.com')
$releases = foreach ($post in Get-TelegramChannelPosts -Channel 'qq_updatelog' -Keyword '#QQ_NT_Windows') {
    if ($post.Text -notmatch '\bWindows QQ_NT (?<version>\d+\.\d+\.\d+\.\d+)(?=\s|$)') {
        continue
    }

    $version = [version] $Matches.version
    $filePattern = '(?<![\d.])' + [regex]::Escape($version.ToString()) + '_x64\.exe$'

    foreach ($link in $post.Links) {
        $uri = $null
        if (![uri]::TryCreate($link, [UriKind]::Absolute, [ref] $uri) -or
            $uri.Scheme -ne 'https' -or !$uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or
            $uri.Host -notin $downloadHosts -or $uri.AbsolutePath -notmatch $filePattern) {
            continue
        }

        [pscustomobject]@{ Version = $version; Url = $uri.AbsoluteUri }
    }
}

$latest = $releases | Sort-Object -Property Version -Descending | Select-Object -First 1
if (!$latest) {
    throw 'No QQ NT Windows x64 release with an allowed Tencent download URL was found.'
}

$latest
