@echo off
where gradle >nul 2>nul
if %errorlevel% equ 0 (
  gradle %*
  exit /b %errorlevel%
)

echo Gradle is not installed. Run "flutter create . --platforms=android" from app/ to regenerate the standard Android wrapper.
exit /b 1
