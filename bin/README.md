# bin/

llama.cpp 的二进制不随仓库分发（体积 ~800 MB）。自行下载后放到这个目录。

CUDA 版（示例，按你的显卡/驱动选）：

1. 到 <https://github.com/ggml-org/llama.cpp/releases> 下载
   `llama-<build>-bin-win-cuda-<ver>-x64.zip` 和对应的 `cudart-...-cuda-<ver>-x64.zip`
2. 解压到 `bin/cuda/`，确保存在 `bin/cuda/llama-server.exe` 和 `ggml-cuda.dll`
3. 编译保活用的无窗口启动器（只需一次）：

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" `
  /nologo /target:winexe /out:bin\windowless-runner.exe scripts\windowless-runner.cs
```

国内网络下 GitHub 可能连不上，可用镜像，例如 `https://gh-proxy.com/<原始地址>`。
