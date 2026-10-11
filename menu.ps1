$script:Categories = @(
    [pscustomobject]@{
        TitleEn = "System Tweaks & AI"
        TitleHe = "אופטימיזציה ופיתוח"
        Key = "tweaks"
        Icon = "$([char]0xE770)"
        Items = @(
            [pscustomobject]@{ Name = "AI & ML Super Profile"; TweakId = "ProfileAI"; IsTweak = $true }
            [pscustomobject]@{ Name = "Block Ads & App Suggestions"; TweakId = "NoConsumerContent"; IsTweak = $true }
            [pscustomobject]@{ Name = "Classic Right-Click Menu (Win11)"; TweakId = "ClassicContextMenu"; IsTweak = $true }
            [pscustomobject]@{ Name = "Clean Temp & Cache Files"; TweakId = "ClearTemp"; IsTweak = $true }
            [pscustomobject]@{ Name = "Clean Windows Update Cache"; TweakId = "CleanupWinUpdate"; IsTweak = $true }
            [pscustomobject]@{ Name = "Content Creator Profile"; TweakId = "ProfileCreator"; IsTweak = $true }
            [pscustomobject]@{ Name = "Disable Windows Copilot"; TweakId = "DisableCopilot"; IsTweak = $true }
            [pscustomobject]@{ Name = "Extreme Gamer Debloat"; TweakId = "ExtremeDebloat"; IsTweak = $true }
            [pscustomobject]@{ Name = "Forensic Deep Scan"; TweakId = "ForensicScan"; IsTweak = $true }
            [pscustomobject]@{ Name = "Gaming Profile (Max Perf, Low Ping)"; TweakId = "ProfileGaming"; IsTweak = $true }
            [pscustomobject]@{ Name = "Generate HTML Report (Desktop)"; TweakId = "GenerateHtmlReport"; IsTweak = $true }
            [pscustomobject]@{ Name = "Nuclear System Debloat (Extreme)"; TweakId = "NuclearDebloat"; IsTweak = $true }
            [pscustomobject]@{ Name = "Office Profile (Battery & Stable)"; TweakId = "ProfileOffice"; IsTweak = $true }
            [pscustomobject]@{ Name = "Reset Network (DNS & Winsock)"; TweakId = "NetworkReset"; IsTweak = $true }
            [pscustomobject]@{ Name = "Show Hidden Files & Extensions"; TweakId = "ShowHiddenFiles"; IsTweak = $true }
            [pscustomobject]@{ Name = "SSD Trim & Optimization"; TweakId = "SSDOptimize"; IsTweak = $true }
            [pscustomobject]@{ Name = "Windows Dark Mode"; TweakId = "DarkMode"; IsTweak = $true }
        )
    },
    [pscustomobject]@{
        TitleEn = "Browsers"
        TitleHe = "דפדפנים"
        Key = "browsers"
        Icon = "$([char]0xE774)"
        Items = @(
            [pscustomobject]@{ Name = "Arc Browser"; WingetId = "TheBrowserCompany.Arc" }
            [pscustomobject]@{ Name = "Brave"; WingetId = "Brave.Brave" }
            [pscustomobject]@{ Name = "DuckDuckGo"; WingetId = "DuckDuckGo.Desktop" }
            [pscustomobject]@{ Name = "Floorp"; WingetId = "Ablaze.Floorp" }
            [pscustomobject]@{ Name = "Google Chrome"; WingetId = "Google.Chrome" }
            [pscustomobject]@{ Name = "LibreWolf"; WingetId = "LibreWolf.LibreWolf" }
            [pscustomobject]@{ Name = "Microsoft Edge"; WingetId = "Microsoft.Edge" }
            [pscustomobject]@{ Name = "Mozilla Firefox"; WingetId = "Mozilla.Firefox" }
            [pscustomobject]@{ Name = "Mullvad Browser"; WingetId = "MullvadVPN.MullvadBrowser" }
            [pscustomobject]@{ Name = "Opera GX"; WingetId = "Opera.OperaGX" }
            [pscustomobject]@{ Name = "Sidekick Browser"; WingetId = "Sidekick.Sidekick" }
            [pscustomobject]@{ Name = "Thorium Browser"; WingetId = "Alex313031.Thorium" }
            [pscustomobject]@{ Name = "Tor Browser"; WingetId = "TorProject.TorBrowser" }
            [pscustomobject]@{ Name = "Vivaldi"; WingetId = "VivaldiTechnologies.Vivaldi" }
            [pscustomobject]@{ Name = "Waterfox"; WingetId = "Waterfox.Waterfox" }
            [pscustomobject]@{ Name = "Yandex Browser"; WingetId = "Yandex.Yandex" }
            [pscustomobject]@{ Name = "Zen Browser"; WingetId = "Zen-Team.Zen-Browser" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Media & Audio"
        TitleHe = "מדיה וסאונד"
        Key = "media"
        Icon = "$([char]0xE189)"
        Items = @(
            [pscustomobject]@{ Name = "AIMP"; WingetId = "AIMP.AIMP" }
            [pscustomobject]@{ Name = "Audacity"; WingetId = "Audacity.Audacity" }
            [pscustomobject]@{ Name = "CapCut"; WingetId = "Bytedance.CapCut" }
            [pscustomobject]@{ Name = "EarTrumpet"; WingetId = "FileTrekker.EarTrumpet" }
            [pscustomobject]@{ Name = "Foobar2000"; WingetId = "PeterPawlowski.foobar2000" }
            [pscustomobject]@{ Name = "GOM Player"; WingetId = "GOMLab.GOMPlayer" }
            [pscustomobject]@{ Name = "HandBrake"; WingetId = "HandBrake.HandBrake" }
            [pscustomobject]@{ Name = "iTunes"; WingetId = "Apple.iTunes" }
            [pscustomobject]@{ Name = "K-Lite Codec Pack (Mega)"; WingetId = "CodecGuide.K-LiteCodecPack.Mega" }
            [pscustomobject]@{ Name = "Kodi"; WingetId = "XBMCFoundation.Kodi" }
            [pscustomobject]@{ Name = "MediaMonkey"; WingetId = "Ventis.MediaMonkey" }
            [pscustomobject]@{ Name = "MPC-HC Player"; WingetId = "clsid2.mpc-hc" }
            [pscustomobject]@{ Name = "OBS Studio"; WingetId = "OBSProject.OBSStudio" }
            [pscustomobject]@{ Name = "Plex Media Server"; WingetId = "Plex.PlexMediaServer" }
            [pscustomobject]@{ Name = "Spotify"; WingetId = "Spotify.Spotify" }
            [pscustomobject]@{ Name = "Tenacity (Audacity Alt)"; WingetId = "tenacityteam.tenacity" }
            [pscustomobject]@{ Name = "VLC Media Player"; WingetId = "VideoLAN.VLC" }
            [pscustomobject]@{ Name = "Winamp"; WingetId = "Radionomy.Winamp" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Design & Creativity"
        TitleHe = "עיצוב ויצירה"
        Key = "design"
        Icon = "$([char]0xE115)"
        Items = @(
            [pscustomobject]@{ Name = "Blender"; WingetId = "BlenderFoundation.Blender" }
            [pscustomobject]@{ Name = "DaVinci Resolve"; WingetId = "BlackmagicDesign.DaVinciResolve" }
            [pscustomobject]@{ Name = "Figma"; WingetId = "Figma.Figma" }
            [pscustomobject]@{ Name = "GIMP"; WingetId = "GIMP.GIMP" }
            [pscustomobject]@{ Name = "Inkscape"; WingetId = "Inkscape.Inkscape" }
            [pscustomobject]@{ Name = "IrfanView"; WingetId = "IrfanSkiljan.IrfanView" }
            [pscustomobject]@{ Name = "Krita"; WingetId = "KDE.Krita" }
            [pscustomobject]@{ Name = "Paint.NET"; WingetId = "dotPDNLLC.paintdotnet" }
            [pscustomobject]@{ Name = "ShareX"; WingetId = "ShareX.ShareX" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Gaming & Launchers"
        TitleHe = "גיימינג ומשגרים"
        Key = "gaming"
        Icon = "$([char]0xE7FC)"
        Items = @(
            [pscustomobject]@{ Name = "Amazon Games"; WingetId = "Amazon.Games" }
            [pscustomobject]@{ Name = "Battle.net"; WingetId = "Blizzard.BattleNet" }
            [pscustomobject]@{ Name = "CurseForge"; WingetId = "Overwolf.CurseForge" }
            [pscustomobject]@{ Name = "EA app"; WingetId = "ElectronicArts.EADesktop" }
            [pscustomobject]@{ Name = "Epic Games Launcher"; WingetId = "EpicGames.EpicGamesLauncher" }
            [pscustomobject]@{ Name = "GOG Galaxy"; WingetId = "GOG.Galaxy" }
            [pscustomobject]@{ Name = "Logitech G HUB"; WingetId = "Logitech.GHUB" }
            [pscustomobject]@{ Name = "Minecraft Launcher"; WingetId = "Mojang.MinecraftLauncher" }
            [pscustomobject]@{ Name = "Moonlight Game Streaming"; WingetId = "MoonlightGameStreamingProject.Moonlight" }
            [pscustomobject]@{ Name = "MSI Afterburner"; WingetId = "Guru3D.Afterburner" }
            [pscustomobject]@{ Name = "NVIDIA GeForce NOW"; WingetId = "Nvidia.GeForceNOW" }
            [pscustomobject]@{ Name = "Osu!"; WingetId = "ppy.osu" }
            [pscustomobject]@{ Name = "Overwolf"; WingetId = "Overwolf.Overwolf" }
            [pscustomobject]@{ Name = "Parsec"; WingetId = "Parsec.Parsec" }
            [pscustomobject]@{ Name = "Playnite (Game Manager)"; WingetId = "JosefNemec.Playnite" }
            [pscustomobject]@{ Name = "Razer Synapse 3"; WingetId = "Razer.Synapse" }
            [pscustomobject]@{ Name = "RetroArch"; WingetId = "Libretro.RetroArch" }
            [pscustomobject]@{ Name = "Riot Client"; WingetId = "RiotGames.RiotClient" }
            [pscustomobject]@{ Name = "Roblox"; WingetId = "Roblox.Roblox" }
            [pscustomobject]@{ Name = "Steam"; WingetId = "Valve.Steam" }
            [pscustomobject]@{ Name = "Twitch"; WingetId = "Twitch.Twitch" }
            [pscustomobject]@{ Name = "Ubisoft Connect"; WingetId = "Ubisoft.Connect" }
            [pscustomobject]@{ Name = "Xbox App"; WingetId = "Microsoft.XboxApp" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Communication & Chat"
        TitleHe = "תקשורת וצ'אט"
        Key = "chat"
        Icon = "$([char]0xE717)"
        Items = @(
            [pscustomobject]@{ Name = "Discord"; WingetId = "Discord.Discord" }
            [pscustomobject]@{ Name = "Microsoft Teams"; WingetId = "Microsoft.Teams" }
            [pscustomobject]@{ Name = "Signal"; WingetId = "OpenWhisperSystems.Signal" }
            [pscustomobject]@{ Name = "Skype"; WingetId = "Microsoft.Skype" }
            [pscustomobject]@{ Name = "Slack"; WingetId = "SlackTechnologies.Slack" }
            [pscustomobject]@{ Name = "Telegram"; WingetId = "Telegram.TelegramDesktop" }
            [pscustomobject]@{ Name = "WhatsApp"; WingetId = "WhatsApp.WhatsApp" }
            [pscustomobject]@{ Name = "Zoom"; WingetId = "Zoom.Zoom" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Development Tools"
        TitleHe = "כלי פיתוח"
        Key = "dev"
        Icon = "$([char]0xE943)"
        Items = @(
            [pscustomobject]@{ Name = "Android Studio"; WingetId = "Google.AndroidStudio" }
            [pscustomobject]@{ Name = "Cursor (AI Code Editor)"; WingetId = "Cursor.Cursor" }
            [pscustomobject]@{ Name = "DBeaver Community"; WingetId = "dbeaver.dbeaver" }
            [pscustomobject]@{ Name = "Git"; WingetId = "Git.Git" }
            [pscustomobject]@{ Name = "GitHub Desktop"; WingetId = "GitHub.GitHubDesktop" }
            [pscustomobject]@{ Name = "HeidiSQL"; WingetId = "HeidiSQL.HeidiSQL" }
            [pscustomobject]@{ Name = "IntelliJ IDEA Community"; WingetId = "JetBrains.IntelliJIDEA.Community" }
            [pscustomobject]@{ Name = "LM Studio"; WingetId = "ElementLabs.LMStudio" }
            [pscustomobject]@{ Name = "MySQL Workbench"; WingetId = "Oracle.MySQLWorkbench" }
            [pscustomobject]@{ Name = "Neovim"; WingetId = "Neovim.Neovim" }
            [pscustomobject]@{ Name = "Ollama (Local AI)"; WingetId = "Ollama.Ollama" }
            [pscustomobject]@{ Name = "pgAdmin 4"; WingetId = "pgAdmin.pgAdmin4" }
            [pscustomobject]@{ Name = "Postman"; WingetId = "Postman.Postman" }
            [pscustomobject]@{ Name = "PuTTY"; WingetId = "PuTTY.PuTTY" }
            [pscustomobject]@{ Name = "PyCharm Community"; WingetId = "JetBrains.PyCharm.Community" }
            [pscustomobject]@{ Name = "Rider"; WingetId = "JetBrains.Rider" }
            [pscustomobject]@{ Name = "Sublime Text 4"; WingetId = "SublimeHQ.SublimeText.4" }
            [pscustomobject]@{ Name = "Termius"; WingetId = "Termius.Termius" }
            [pscustomobject]@{ Name = "Unity Hub"; WingetId = "Unity.UnityHub" }
            [pscustomobject]@{ Name = "Visual Studio Code"; WingetId = "Microsoft.VisualStudioCode" }
            [pscustomobject]@{ Name = "WebStorm"; WingetId = "JetBrains.WebStorm" }
            [pscustomobject]@{ Name = "WinSCP"; WingetId = "WinSCP.WinSCP" }
            [pscustomobject]@{ Name = "Zed"; WingetId = "Zed.Zed" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Runtimes & Frameworks"
        TitleHe = "סביבות ריצה ומסדי נתונים"
        Key = "runtimes"
        Icon = "$([char]0xE756)"
        Items = @(
            [pscustomobject]@{ Name = ".NET Desktop Runtime 8"; WingetId = "Microsoft.DotNet.DesktopRuntime.8" }
            [pscustomobject]@{ Name = ".NET SDK 8"; WingetId = "Microsoft.DotNet.SDK.8" }
            [pscustomobject]@{ Name = "CMake"; WingetId = "Kitware.CMake" }
            [pscustomobject]@{ Name = "DirectX Runtime"; WingetId = "Microsoft.DirectX" }
            [pscustomobject]@{ Name = "Docker Desktop"; WingetId = "Docker.DockerDesktop" }
            [pscustomobject]@{ Name = "Go"; WingetId = "GoLang.Go" }
            [pscustomobject]@{ Name = "Java JDK 21 (Temurin)"; WingetId = "EclipseAdoptium.Temurin.21.JDK" }
            [pscustomobject]@{ Name = "Java JRE 21 (Temurin)"; WingetId = "EclipseAdoptium.Temurin.21.JRE" }
            [pscustomobject]@{ Name = "MongoDB"; WingetId = "MongoDB.Server" }
            [pscustomobject]@{ Name = "MySQL"; WingetId = "Oracle.MySQL" }
            [pscustomobject]@{ Name = "PHP"; WingetId = "PHP.PHP" }
            [pscustomobject]@{ Name = "PostgreSQL"; WingetId = "PostgreSQL.PostgreSQL" }
            [pscustomobject]@{ Name = "Python 3.12"; WingetId = "Python.Python.3.12" }
            [pscustomobject]@{ Name = "Ruby"; WingetId = "RubyInstallerTeam.Ruby" }
            [pscustomobject]@{ Name = "Rust"; WingetId = "Rustlang.Rustup" }
            [pscustomobject]@{ Name = "Visual C++ Redist x64"; WingetId = "Microsoft.VCRedist.2015+.x64" }
            [pscustomobject]@{ Name = "Visual C++ Redist x86"; WingetId = "Microsoft.VCRedist.2015+.x86" }
            [pscustomobject]@{ Name = "WebView2 Runtime"; WingetId = "Microsoft.EdgeWebView2Runtime" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Utilities & System"
        TitleHe = "עזרי מערכת"
        Key = "utils"
        Icon = "$([char]0xE713)"
        Items = @(
            [pscustomobject]@{ Name = "7-Zip"; WingetId = "7zip.7zip" }
            [pscustomobject]@{ Name = "AnyDesk"; WingetId = "AnyDeskSoftwareGmbH.AnyDesk" }
            [pscustomobject]@{ Name = "AOMEI Partition Assistant"; WingetId = "AOMEI.PartitionAssistant" }
            [pscustomobject]@{ Name = "AutoHotkey"; WingetId = "Lexikos.AutoHotkey" }
            [pscustomobject]@{ Name = "CrystalDiskInfo"; WingetId = "CrystalDewWorld.CrystalDiskInfo" }
            [pscustomobject]@{ Name = "CrystalDiskMark"; WingetId = "CrystalDewWorld.CrystalDiskMark" }
            [pscustomobject]@{ Name = "Dropbox"; WingetId = "Dropbox.Dropbox" }
            [pscustomobject]@{ Name = "Everything (Instant Search)"; WingetId = "voidtools.Everything" }
            [pscustomobject]@{ Name = "FanControl"; WingetId = "Rem0o.FanControl.Beta" }
            [pscustomobject]@{ Name = "Fluent Search"; WingetId = "BlastApps.FluentSearch" }
            [pscustomobject]@{ Name = "Foxit PDF Reader"; WingetId = "Foxit.FoxitReader" }
            [pscustomobject]@{ Name = "Google Drive"; WingetId = "Google.Drive" }
            [pscustomobject]@{ Name = "HWiNFO"; WingetId = "REALiX.HWiNFO" }
            [pscustomobject]@{ Name = "HWMonitor"; WingetId = "CPUID.HWMonitor" }
            [pscustomobject]@{ Name = "Macrorit Partition Expert"; WingetId = "Macrorit.PartitionExpert" }
            [pscustomobject]@{ Name = "Microsoft PowerToys"; WingetId = "Microsoft.PowerToys" }
            [pscustomobject]@{ Name = "Notepad++"; WingetId = "Notepad++.Notepad++" }
            [pscustomobject]@{ Name = "PowerShell 7"; WingetId = "Microsoft.PowerShell" }
            [pscustomobject]@{ Name = "Process Explorer"; WingetId = "Microsoft.Sysinternals.ProcessExplorer" }
            [pscustomobject]@{ Name = "qBittorrent"; WingetId = "qBittorrent.qBittorrent" }
            [pscustomobject]@{ Name = "Rufus (USB Creator)"; WingetId = "Rufus.Rufus" }
            [pscustomobject]@{ Name = "RustDesk"; WingetId = "RustDesk.RustDesk" }
            [pscustomobject]@{ Name = "StartAllBack"; WingetId = "Tihiy.StartAllBack" }
            [pscustomobject]@{ Name = "SumatraPDF"; WingetId = "SumatraPDF.SumatraPDF" }
            [pscustomobject]@{ Name = "Sysinternals Suite"; WingetId = "Microsoft.Sysinternals" }
            [pscustomobject]@{ Name = "TeamViewer"; WingetId = "TeamViewer.TeamViewer" }
            [pscustomobject]@{ Name = "TeraCopy"; WingetId = "CodeSector.TeraCopy" }
            [pscustomobject]@{ Name = "TranslucentTB"; WingetId = "TranslucentTB.TranslucentTB" }
            [pscustomobject]@{ Name = "TreeSize Free"; WingetId = "JAMSoftware.TreeSize.Free" }
            [pscustomobject]@{ Name = "VirtualBox"; WingetId = "Oracle.VirtualBox" }
            [pscustomobject]@{ Name = "VMware Workstation Player"; WingetId = "VMware.WorkstationPlayer" }
            [pscustomobject]@{ Name = "Winaero Tweaker"; WingetId = "Winaero.WinaeroTweaker" }
            [pscustomobject]@{ Name = "WindirStat"; WingetId = "WinDirStat.WinDirStat" }
            [pscustomobject]@{ Name = "Windows Terminal"; WingetId = "Microsoft.WindowsTerminal" }
            [pscustomobject]@{ Name = "WinRAR"; WingetId = "RARLab.WinRAR" }
        )
    },
    [pscustomobject]@{
        TitleEn = "Security & Cleanup"
        TitleHe = "אבטחה וניקוי"
        Key = "security"
        Icon = "$([char]0xE773)"
        Items = @(
            [pscustomobject]@{ Name = "1Password"; WingetId = "AgileBits.1Password" }
            [pscustomobject]@{ Name = "Bitwarden"; WingetId = "Bitwarden.Bitwarden" }
            [pscustomobject]@{ Name = "BleachBit"; WingetId = "BleachBit.BleachBit" }
            [pscustomobject]@{ Name = "CCleaner"; WingetId = "Piriform.CCleaner" }
            [pscustomobject]@{ Name = "Geek Uninstaller"; WingetId = "ThomasKoen.GeekUninstaller" }
            [pscustomobject]@{ Name = "Malwarebytes"; WingetId = "Malwarebytes.Malwarebytes" }
            [pscustomobject]@{ Name = "Revo Uninstaller"; WingetId = "RevoUninstaller.RevoUninstaller" }
            [pscustomobject]@{ Name = "Wireshark"; WingetId = "WiresharkFoundation.Wireshark" }
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
            [pscustomobject]@{ Name = "Profile: Ultimate Debloat"; Title = "Ultimate Debloat"; Desc = "Extreme telemetry removal, disable Defender, remove Edge."; TweakId = "AuditProfile7"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Privacy Shield"; Title = "Privacy Shield"; Desc = "Block all tracking, disable Cortana, spoof telemetry."; TweakId = "AuditProfile8"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Laptop Battery Saver"; Title = "Laptop Battery Saver"; Desc = "Underclock CPU, max power saving, disable background sync."; TweakId = "AuditProfile9"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Network Supercharger"; Title = "Network Supercharger"; Desc = "Optimize TCP/IP stack, flush DNS, prioritize gaming packets."; TweakId = "AuditProfile10"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Nuclear Ultra-Deep Debloat"; Title = "Nuclear Ultra-Deep Debloat"; Desc = "Extreme background stripping of Edge, Copilot, Widgets & telemetry."; TweakId = "AuditProfile11"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Deep System Cleanup"; Title = "Deep System Cleanup"; Desc = "Clean Windows Update cache, crash dumps, temp files, and SSD TRIM."; TweakId = "AuditProfile12"; IsTweak = $true }
            [pscustomobject]@{ Name = "Profile: Security Hardening"; Title = "Security Hardening"; Desc = "Disable WPAD, Remote Assistance, and lock screen exposure."; TweakId = "AuditProfile13"; IsTweak = $true }
            [pscustomobject]@{ Name = "Generate HTML Report (Desktop)"; Title = "Generate HTML Report"; Desc = "Create an interactive, transparent HTML report of all system changes."; TweakId = "GenerateHtmlReport"; IsTweak = $true }
        )
    }
)
