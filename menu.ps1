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
            [pscustomobject]@{ Name = "Clean Temp & Cache Files"; TweakId = "ClearTemp"; IsTweak = $true }
            [pscustomobject]@{ Name = "Clean Windows Update Cache"; TweakId = "CleanupWinUpdate"; IsTweak = $true }
            [pscustomobject]@{ Name = "Reset Network (DNS & Winsock)"; TweakId = "NetworkReset"; IsTweak = $true }
            [pscustomobject]@{ Name = "Disable Windows Copilot"; TweakId = "DisableCopilot"; IsTweak = $true }
            [pscustomobject]@{ Name = "Block Ads & App Suggestions"; TweakId = "NoConsumerContent"; IsTweak = $true }
            [pscustomobject]@{ Name = "Show Hidden Files & Extensions"; TweakId = "ShowHiddenFiles"; IsTweak = $true }
            [pscustomobject]@{ Name = "Windows Dark Mode"; TweakId = "DarkMode"; IsTweak = $true }
            [pscustomobject]@{ Name = "Classic Right-Click Menu (Win11)"; TweakId = "ClassicContextMenu"; IsTweak = $true }
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
            [pscustomobject]@{ Name = "Opera"; WingetId = "Opera.Opera" }
            [pscustomobject]@{ Name = "Opera GX"; WingetId = "Opera.OperaGX" }
            [pscustomobject]@{ Name = "Vivaldi"; WingetId = "VivaldiTechnologies.Vivaldi" }
            [pscustomobject]@{ Name = "Tor Browser"; WingetId = "TorProject.TorBrowser" }
            [pscustomobject]@{ Name = "Zen Browser"; WingetId = "Zen-Team.Zen-Browser" }
            [pscustomobject]@{ Name = "LibreWolf"; WingetId = "LibreWolf.LibreWolf" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Media & Tools"
        TitleHe = "מדיה וכלים"
        Key = "media"
        Icon = "$([char]0xE189)"
        Items = @(
            [pscustomobject]@{ Name = "VLC Media Player"; WingetId = "VideoLAN.VLC" }
            [pscustomobject]@{ Name = "MPC-HC Player"; WingetId = "clsid2.mpc-hc" }
            [pscustomobject]@{ Name = "Spotify"; WingetId = "Spotify.Spotify" }
            [pscustomobject]@{ Name = "OBS Studio"; WingetId = "OBSProject.OBSStudio" }
            [pscustomobject]@{ Name = "Audacity"; WingetId = "Audacity.Audacity" }
            [pscustomobject]@{ Name = "HandBrake"; WingetId = "HandBrake.HandBrake" }
            [pscustomobject]@{ Name = "GIMP"; WingetId = "GIMP.GIMP" }
            [pscustomobject]@{ Name = "IrfanView"; WingetId = "IrfanSkiljan.IrfanView" }
            [pscustomobject]@{ Name = "ShareX"; WingetId = "ShareX.ShareX" }
            [pscustomobject]@{ Name = "7-Zip"; WingetId = "7zip.7zip" }
            [pscustomobject]@{ Name = "WinRAR"; WingetId = "RARLab.WinRAR" }
            [pscustomobject]@{ Name = "Notepad++"; WingetId = "Notepad++.Notepad++" }
            [pscustomobject]@{ Name = "Everything (Instant Search)"; WingetId = "voidtools.Everything" }
            [pscustomobject]@{ Name = "Microsoft PowerToys"; WingetId = "Microsoft.PowerToys" }
            [pscustomobject]@{ Name = "qBittorrent"; WingetId = "qBittorrent.qBittorrent" }
            [pscustomobject]@{ Name = "Rufus (USB Creator)"; WingetId = "Rufus.Rufus" }
            [pscustomobject]@{ Name = "HWiNFO"; WingetId = "REALiX.HWiNFO" }
            [pscustomobject]@{ Name = "CPU-Z"; WingetId = "CPUID.CPU-Z" }
            [pscustomobject]@{ Name = "CrystalDiskInfo"; WingetId = "CrystalDewWorld.CrystalDiskInfo" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Gaming & Chat"
        TitleHe = "גיימינג ותקשורת"
        Key = "gaming"
        Icon = "$([char]0xE7FC)"
        Items = @(
            [pscustomobject]@{ Name = "Steam"; WingetId = "Valve.Steam" }
            [pscustomobject]@{ Name = "Epic Games Launcher"; WingetId = "EpicGames.EpicGamesLauncher" }
            [pscustomobject]@{ Name = "GOG Galaxy"; WingetId = "GOG.Galaxy" }
            [pscustomobject]@{ Name = "Battle.net"; WingetId = "Blizzard.BattleNet" }
            [pscustomobject]@{ Name = "EA app"; WingetId = "ElectronicArts.EADesktop" }
            [pscustomobject]@{ Name = "Ubisoft Connect"; WingetId = "Ubisoft.Connect" }
            [pscustomobject]@{ Name = "MSI Afterburner"; WingetId = "Guru3D.Afterburner" }
            [pscustomobject]@{ Name = "Discord"; WingetId = "Discord.Discord" }
            [pscustomobject]@{ Name = "Telegram"; WingetId = "Telegram.TelegramDesktop" }
            [pscustomobject]@{ Name = "WhatsApp"; WingetId = "WhatsApp.WhatsApp" }
            [pscustomobject]@{ Name = "Zoom"; WingetId = "Zoom.Zoom" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Dev & Runtimes"
        TitleHe = "פיתוח ורכיבי מערכת"
        Key = "dev"
        Icon = "$([char]0xE943)"
        Items = @(
            [pscustomobject]@{ Name = "Visual Studio Code"; WingetId = "Microsoft.VisualStudioCode" }
            [pscustomobject]@{ Name = "Git"; WingetId = "Git.Git" }
            [pscustomobject]@{ Name = "GitHub Desktop"; WingetId = "GitHub.GitHubDesktop" }
            [pscustomobject]@{ Name = "Python 3.12"; WingetId = "Python.Python.3.12" }
            [pscustomobject]@{ Name = "Node.js LTS"; WingetId = "OpenJS.NodeJS.LTS" }
            [pscustomobject]@{ Name = "Java JDK 21 (Temurin)"; WingetId = "EclipseAdoptium.Temurin.21.JDK" }
            [pscustomobject]@{ Name = ".NET SDK 8"; WingetId = "Microsoft.DotNet.SDK.8" }
            [pscustomobject]@{ Name = "CMake"; WingetId = "Kitware.CMake" }
            [pscustomobject]@{ Name = "Docker Desktop"; WingetId = "Docker.DockerDesktop" }
            [pscustomobject]@{ Name = "Windows Terminal"; WingetId = "Microsoft.WindowsTerminal" }
            [pscustomobject]@{ Name = "PowerShell 7"; WingetId = "Microsoft.PowerShell" }
            [pscustomobject]@{ Name = "Postman"; WingetId = "Postman.Postman" }
            [pscustomobject]@{ Name = "Ollama (Local AI)"; WingetId = "Ollama.Ollama" }
            [pscustomobject]@{ Name = "LM Studio"; WingetId = "ElementLabs.LMStudio" }
            [pscustomobject]@{ Name = "PuTTY"; WingetId = "PuTTY.PuTTY" }
            [pscustomobject]@{ Name = "WinSCP"; WingetId = "WinSCP.WinSCP" }
            [pscustomobject]@{ Name = "Visual C++ Redist x64"; WingetId = "Microsoft.VCRedist.2015+.x64" }
            [pscustomobject]@{ Name = "Visual C++ Redist x86"; WingetId = "Microsoft.VCRedist.2015+.x86" }
            [pscustomobject]@{ Name = "DirectX Runtime"; WingetId = "Microsoft.DirectX" }
            [pscustomobject]@{ Name = ".NET Desktop Runtime 8"; WingetId = "Microsoft.DotNet.DesktopRuntime.8" }
            [pscustomobject]@{ Name = "WebView2 Runtime"; WingetId = "Microsoft.EdgeWebView2Runtime" }
            [pscustomobject]@{ Name = "Java JRE 21 (Temurin)"; WingetId = "EclipseAdoptium.Temurin.21.JRE" }
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
