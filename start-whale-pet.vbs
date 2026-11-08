' 小鲸鱼桌宠 —— 静默启动器（不弹控制台窗口）
Option Explicit
Dim fso, sh, dir, script
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
script = dir & "\WhalePet.ps1"
sh.CurrentDirectory = dir
sh.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
