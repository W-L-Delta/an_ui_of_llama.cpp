// windowless-runner.cs
//
// A console-free launcher for the keepalive task.
//
// Why this exists (each step below was measured on this machine, Windows 11
// build 26100/26200):
//
//   1. task action = powershell.exe ... -WindowStyle Hidden
//        -> flashed a black console every interval. Task Scheduler creates the
//           console for a console-subsystem program *before* any hidden or
//           minimised style is applied.
//   2. task action = a .cmd wrapper with `start /min /b powershell ...`
//        -> still flashed, because cmd.exe is itself a console program.
//   3. task action = this runner (GUI subsystem, PE subsystem = 2)
//        -> the OS never allocates a console for it, and it starts the child
//           with CREATE_NO_WINDOW, so the child never gets a console window
//           either. There is no window to flash, because none is ever made.
//
// Not usable on this machine, do not retry:
//   - conhost.exe --headless  (not supported by this build)
//   - VBScript / wscript / mshta (no VBScript engine is registered)
//
// Build (PowerShell 5.1 ships csc.exe):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe ^
//       /nologo /target:winexe /out:bin\windowless-runner.exe ^
//       scripts\windowless-runner.cs
//
// Usage:
//   windowless-runner.exe powershell.exe -NoProfile ... -File <script.ps1> -EnsureRunning

using System;
using System.Runtime.InteropServices;
using System.Text;

internal static class WindowlessRunner
{
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_LIMIT_MS = 300000;   // 5 min: start-llama.ps1 itself gives up after 240 s

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcess(
        string lpApplicationName, string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private static int Main(string[] args)
    {
        if (args.Length == 0) return 2;

        // Quote every argument: the child command line may contain paths with
        // spaces, and CreateProcess wants one pre-built string.
        StringBuilder cmd = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) cmd.Append(' ');
            cmd.Append('"').Append(args[i].Replace("\"", "\\\"")).Append('"');
        }

        STARTUPINFO si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;

        // bInheritHandles = false: the child must not inherit any handle of
        // ours. That is also what keeps llama-server from holding a pipe open.
        bool ok = CreateProcess(null, cmd.ToString(), IntPtr.Zero, IntPtr.Zero,
                                false, CREATE_NO_WINDOW, IntPtr.Zero, null, ref si, out pi);
        if (!ok) return 1;

        int code;
        if (WaitForSingleObject(pi.hProcess, WAIT_LIMIT_MS) == WAIT_TIMEOUT)
        {
            // Never let a stuck run block the next keepalive tick forever.
            TerminateProcess(pi.hProcess, 1);
            code = 1;
        }
        else
        {
            uint exitCode;
            code = GetExitCodeProcess(pi.hProcess, out exitCode) ? unchecked((int)exitCode) : 1;
        }

        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return code;
    }
}
