function Get-TelegramChannelPosts {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidatePattern('^@?[a-zA-Z0-9_]+$')]
        [string] $Channel,

        [string] $Keyword
    )

    $channelName = $Channel.TrimStart('@')
    $url = "https://t.me/s/$channelName"
    if ($Keyword) {
        $url += '?q=' + [uri]::EscapeDataString($Keyword)
    }

    $page = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
    $posts = [regex]::Split([string] $page.Content, '<div class="tgme_widget_message_wrap\b')

    foreach ($post in $posts | Select-Object -Skip 1) {
        $id = [regex]::Match($post, 'data-post="(?<channel>[a-zA-Z0-9_]+)/(?<id>[0-9]+)"')
        $body = [regex]::Match($post, '(?s)<div class="tgme_widget_message_text\b[^>]*>(?<html>.*?)</div>')
        if (!$id.Success -or $id.Groups['channel'].Value -ne $channelName -or !$body.Success) {
            continue
        }

        $html = $body.Groups['html'].Value
        $text = [System.Net.WebUtility]::HtmlDecode(($html -replace '<[^>]+>', ' '))
        $links = foreach ($link in [regex]::Matches($html, '\bhref="(?<url>[^"]+)"')) {
            [System.Net.WebUtility]::HtmlDecode($link.Groups['url'].Value)
        }

        [pscustomobject]@{
            Id = $id.Groups['id'].Value
            Text = ($text -replace '\s+', ' ').Trim()
            Links = @($links)
        }
    }
}

Export-ModuleMember -Function Get-TelegramChannelPosts
