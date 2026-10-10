$script:Categories = @(
    [pscustomobject]@{
        TitleEn = "System Tweaks & AI"
        TitleHe = "אופטימיזציה ופיתוח"
        Key = "tweaks"
        Icon = "&#xE770;"
        Items = @(
            [pscustomobject]@{ Name = "Deep Debloat (Telemetry & Junk)"; TweakId = "DeepDebloat"; IsTweak = $true }
            [pscustomobject]@{ Name = "Gaming Profile (Max Perf, Low Ping)"; TweakId = "ProfileGaming"; IsTweak = $true }
            [pscustomobject]@{ Name = "Office Profile (Battery & Stable)"; TweakId = "ProfileOffice"; IsTweak = $true }
            [pscustomobject]@{ Name = "Content Creator Profile"; TweakId = "ProfileCreator"; IsTweak = $true }
            [pscustomobject]@{ Name = "AI & ML Super Profile (Deep Scan & Max Resources)"; TweakId = "ProfileAI"; IsTweak = $true }
            [pscustomobject]@{ Name = "SSD Trim & Optimization"; TweakId = "SSDOptimize"; IsTweak = $true }
        )
    },
    [pscustomobject]@{
        TitleEn = "Browsers"
        TitleHe = "דפדפנים"
        Key = "browsers"
        Icon = "&#xE774;"
        Items = @(
            [pscustomobject]@{ Name = "Google Chrome"; WingetId = "Google.Chrome" }
            [pscustomobject]@{ Name = "Mozilla Firefox"; WingetId = "Mozilla.Firefox" }
            [pscustomobject]@{ Name = "Brave"; WingetId = "Brave.Brave" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Media & Tools"
        TitleHe = "מדיה וכלים"
        Key = "media"
        Icon = "&#xE189;"
        Items = @(
            [pscustomobject]@{ Name = "VLC Media Player"; WingetId = "VideoLAN.VLC" }
            [pscustomobject]@{ Name = "7-Zip"; WingetId = "7zip.7zip" }
            [pscustomobject]@{ Name = "Notepad++"; WingetId = "Notepad++.Notepad++" }
        )
    }
)
