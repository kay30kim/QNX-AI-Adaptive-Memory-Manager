@echo off
setlocal
rem Save hello.cpp, then run this script. To quit QEMU, press Ctrl+A, then X.
set "QEMU=C:\Program Files\qemu\qemu-system-x86_64.exe"
if not exist "%QEMU%" (
    echo QEMU was not found at "%QEMU%".
    exit /b 1
)

rem Load the QNX SDP compiler and image-building tools.
call "%~dp0..\qnx800\qnxsdp-env.bat" >nul || exit /b 1
@echo off
pushd "%~dp0..\qnx-hello-vm" || exit /b 1

rem Build the C++ program for QNX x86-64 and link its libraries statically.
q++ -Vgcc_ntox86_64 -Wall -Wextra -static "%~dp0hello.cpp" -o ..\qnx800\hello || goto failed

rem Tell the image builder where to find the QNX x86-64 system files.
set "MKFS_PATH=../qnx800/target/qnx/x86_64;../qnx800/target/qnx/x86_64/boot/sys;../qnx800/target/qnx;."
set "PROCESSOR=x86_64"

rem Build the QNX boot image containing the updated hello program.
mkifs -o output output/build/ifs.build output/ifs-hello-three.bin || goto failed

rem Start QEMU and boot QNX from the image just built.
"%QEMU%" -cpu max -m 1024 -smp 2 -nographic -nic none -kernel output/ifs-hello-three.bin -drive file=output/disk-qemu.vmdk,if=ide -snapshot || goto failed
popd
exit /b 0

:failed
echo See the error above. If QEMU is already running, quit it before retrying.
popd
exit /b 1
