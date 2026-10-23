"""Test-only support for running Python fake CLIs as direct Windows children."""
import asyncio
import ctypes
import os
from pathlib import Path
import sys
from unittest.mock import patch


_spawn = asyncio.create_subprocess_exec


async def spawn_python_cli(program, *arguments, **options):
    script = options.get("env", {}).get("RAWLAB_MCP_TEST_CLI_SCRIPT")
    if os.name == "nt" and script and Path(program) == Path(script):
        # 同一个 Python 进程执行夹具，取消仍测试生产代码对直接子进程的回收。
        return await _spawn(sys.executable, program, *arguments, **options)
    return await _spawn(program, *arguments, **options)


def python_cli_patch():
    return patch("asyncio.create_subprocess_exec", spawn_python_cli)


def process_exited(pid):
    if os.name != "nt":
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        return False

    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    handle = kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
    if not handle:
        error = ctypes.get_last_error()
        if error == 87:  # ERROR_INVALID_PARAMETER: no process with this PID
            return True
        raise ctypes.WinError(error)
    try:
        result = kernel.WaitForSingleObject(handle, 0)
        if result == 0:  # WAIT_OBJECT_0
            return True
        if result == 258:  # WAIT_TIMEOUT
            return False
        raise ctypes.WinError(ctypes.get_last_error())
    finally:
        kernel.CloseHandle(handle)
