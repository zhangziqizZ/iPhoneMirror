@echo off
rem hvigor command-line launcher (Windows). 用 DevEco Studio 打开本工程则无需此文件。
setlocal
set "APP_HOME=%~dp0"
if defined JAVA_HOME (set "JAVACMD=%JAVA_HOME%\bin\java.exe") else (set "JAVACMD=java")
set "CLASSPATH=%APP_HOME%hvigor\hvigor-*.jar"
"%JAVACMD%" -Dorg.gradle.appname=hvigorw -classpath "%CLASSPATH%" com.huawei.hvigor.client.cli.HvigorCli %*
endlocal
