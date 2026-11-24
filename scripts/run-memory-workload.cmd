@echo off
setlocal
rem Use --build-only to compile and prepare the image without starting QEMU.
set "QEMU=C:\Program Files\qemu\qemu-system-x86_64.exe"
call "%~dp0..\..\qnx800\qnxsdp-env.bat" >nul || exit /b 1
@echo off
pushd "%~dp0..\..\qnx-hello-vm" || exit /b 1
q++ -Vgcc_ntox86_64 -std=c++11 -Wall -Wextra -static "%~dp0..\src\workloads\memory_workload.cpp" -o output/memory_workload || goto failed
copy /y output\build\ifs.build output\build\ifs-memory-workload.build >nul || goto failed
echo.>>output\build\ifs-memory-workload.build
echo [uid=0 gid=0 perms=0755] /proc/boot/memory_workload=output/memory_workload>>output\build\ifs-memory-workload.build
set "MKFS_PATH=../qnx800/target/qnx/x86_64;../qnx800/target/qnx/x86_64/boot/sys;../qnx800/target/qnx;."
set "PROCESSOR=x86_64"
mkifs -o output output/build/ifs-memory-workload.build output/ifs-memory-workload.bin || goto failed
if /i "%~1"=="--build-only" goto done
if not exist "%QEMU%" (
    echo QEMU was not found at "%QEMU%".
    goto failed
)
echo At the QNX shell prompt, type: /proc/boot/memory_workload
echo To quit QEMU, press Ctrl+A, then X.
"%QEMU%" -cpu max -m 1024 -smp 2 -nographic -nic none -kernel output/ifs-memory-workload.bin -drive file=output/disk-qemu.vmdk,if=ide -snapshot || goto failed
:done
popd
exit /b 0
:failed
popd
exit /b 1
