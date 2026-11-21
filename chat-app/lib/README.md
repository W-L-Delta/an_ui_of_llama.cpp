# chat-app/lib/

这里放 WebView2 的托管 DLL（不随仓库提交，体积较大）。需要三个文件：

| 文件 | 来源 |
|---|---|
| `Microsoft.Web.WebView2.Core.dll` | NuGet 包 `Microsoft.Web.WebView2` 的 `lib/net45/` |
| `Microsoft.Web.WebView2.WinForms.dll` | 同上 |
| `WebView2Loader.dll` | 同上，`runtimes/win-x64/native/` |

最省事的做法：

```powershell
# 下载 nupkg 并解压（示例版本号可换）
curl.exe -L -o "$env:TEMP\webview2.zip" https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.3405.78
Expand-Archive "$env:TEMP\webview2.zip" "$env:TEMP\webview2" -Force
Copy-Item "$env:TEMP\webview2\lib\net45\Microsoft.Web.WebView2.*.dll" chat-app\lib\
Copy-Item "$env:TEMP\webview2\runtimes\win-x64\native\WebView2Loader.dll" chat-app\lib\
```

WebView2 **运行时**本身 Windows 11 自带；如果是 Win10 需要另装 Evergreen Runtime。
