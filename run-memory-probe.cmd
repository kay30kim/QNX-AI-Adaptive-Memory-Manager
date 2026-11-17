@echo off
setlocal
rem Use --build-only to compile and prepare the image without starting QEMU.
set "QEMU=C:\Program Files\qemu\qemu-system-x86_64.exe"
call "%~dp0..\qnx800\qnxsdp-env.bat" >nul || exit /b 1
@echo off
pushd "%~dp0..\qnx-hello-vm" || exit /b 1
q++ -Vgcc_ntox86_64 -std=c++11 -Wall -Wextra -static "%~dp0memory_probe.cpp" -o output/memory_probe || goto failed
rem Extend a COPY of the existing image recipe with the new executable.
copy /y output\build\ifs.build output\build\ifs-memory-probe.build >nul || goto failed
echo.>>output\build\ifs-memory-probe.build
echo [uid=0 gid=0 perms=0755] /proc/boot/memory_probe=output/memory_probe>>output\build\ifs-memory-probe.build
set "MKFS_PATH=../qnx800/target/qnx/x86_64;../qnx800/target/qnx/x86_64/boot/sys;../qnx800/target/qnx;."
set "PROCESSOR=x86_64"
mkifs -o output output/build/ifs-memory-probe.build output/ifs-memory-probe.bin || goto failed
if /i "%~1"=="--build-only" goto done
if not exist "%QEMU%" (
    echo QEMU was not found at "%QEMU%".
    goto failed
)
echo At the QNX shell prompt, type: /proc/boot/memory_probe
echo To quit QEMU, press Ctrl+A, then X.
"%QEMU%" -cpu max -m 1024 -smp 2 -nographic -nic none -kernel output/ifs-memory-probe.bin -drive file=output/disk-qemu.vmdk,if=ide -snapshot || goto failed
:done
popd
exit /b 0
:failed
popd
exit /b 1
