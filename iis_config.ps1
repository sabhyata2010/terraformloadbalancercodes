import-module servermanager
add-windowsfeature web-server -includeallsubfeature
add-windowsfeature Web-Asp-Net60
add-windowsfeature NET-Framework-Features
Set-Content -Path "C:\inetpub\wwwroot\Default.html" -Value "This is the server  $($env:computername) !"