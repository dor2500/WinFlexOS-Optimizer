$script:Categories = @(
    [pscustomobject]@{
        TitleEn = "System Tweaks & AI"
        TitleHe = "אופטימיזציה ופיתוח"
        Key = "tweaks"
        Icon = "$([char]0xE770)"
        Items = @(
            [pscustomobject]@{ Name = "Extreme Gamer Debloat"; TweakId = "ExtremeDebloat"; IsTweak = $true }
            [pscustomobject]@{ Name = "Forensic Deep Scan"; TweakId = "ForensicScan"; IsTweak = $true }
            [pscustomobject]@{ Name = "Gaming Profile (Max Perf, Low Ping)"; TweakId = "ProfileGaming"; IsTweak = $true }
            [pscustomobject]@{ Name = "Office Profile (Battery & Stable)"; TweakId = "ProfileOffice"; IsTweak = $true }
            [pscustomobject]@{ Name = "Content Creator Profile"; TweakId = "ProfileCreator"; IsTweak = $true }
            [pscustomobject]@{ Name = "AI & ML Super Profile"; TweakId = "ProfileAI"; IsTweak = $true }
            [pscustomobject]@{ Name = "SSD Trim & Optimization"; TweakId = "SSDOptimize"; IsTweak = $true }
        )
    },
    [pscustomobject]@{
        TitleEn = "Browsers"
        TitleHe = "דפדפנים"
        Key = "browsers"
        Icon = "$([char]0xE774)"
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
        Icon = "$([char]0xE189)"
        Items = @(
            [pscustomobject]@{ Name = "VLC Media Player"; WingetId = "VideoLAN.VLC" }
            [pscustomobject]@{ Name = "7-Zip"; WingetId = "7zip.7zip" }
            [pscustomobject]@{ Name = "Notepad++"; WingetId = "Notepad++.Notepad++" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Hardware Audit & Privacy"
        TitleHe = "בדיקת חומרה ופרטיות"
        Key = "audit"
        Icon = "$([char]0xE9D9)"
        Items = @(
            [pscustomobject]@{ Name = "Profile: Gaming"; Title = "Gaming"; Desc = "Max performance, zero mouse accel, lower network latency."; TweakId = "AuditProfile1"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Office & Browsing"; Title = "Office & Browsing"; Desc = "Stability, power saving, bloatware removal."; TweakId = "AuditProfile2"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Content Creation"; Title = "Content Creation"; Desc = "Maximize stable resources for rendering/production."; TweakId = "AuditProfile3"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: AI & Machine Learning"; Title = "AI & Machine Learning"; Desc = "Deep system scan, max RAM/VRAM utilization, Long Paths."; TweakId = "AuditProfile4"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Forensic Deep Scan"; Title = "Forensic Deep Scan"; Desc = "Driver & Targeted Folder Analysis - ~5-10 Minutes."; TweakId = "AuditProfile5"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: UNDO"; Title = "UNDO"; Desc = "Revert all optimizations to Windows defaults."; TweakId = "AuditProfile6"; IsTweak = $true }
        )
    }
)
