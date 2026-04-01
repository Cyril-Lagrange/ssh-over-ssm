@echo off
REM Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
REM SPDX-License-Identifier: MIT-0

REM Configuration
set MAX_ITERATION=12
set SLEEP_DURATION=5

REM Arguments passed from SSH client
set HOST=%1
set PORT=%2
set AWS_REGION=%3
set AWS_PROFILE=%4


for /f %%i in ('aws ssm describe-instance-information --filters "Key=InstanceIds,Values=%HOST%" --output text --query "InstanceInformationList[0].PingStatus" --profile %AWS_PROFILE% --region %AWS_REGION%') do set STATUS=%%i


if "%STATUS%"=="Online" goto start_session

aws ec2 start-instances --instance-ids %HOST% --profile %AWS_PROFILE% --region %AWS_REGION%
timeout /t %SLEEP_DURATION% /nobreak >nul
set COUNT=0
:loop
for /f %%i in ('aws ssm describe-instance-information --filters "Key=InstanceIds,Values=%HOST%" --output text --query "InstanceInformationList[0].PingStatus" --profile %AWS_PROFILE% --region %AWS_REGION%') do set STATUS=%%i
if "%STATUS%"=="Online" goto start_session
if %COUNT% equ %MAX_ITERATION% exit /b 1
set /a COUNT+=1
timeout /t %SLEEP_DURATION% /nobreak >nul
goto loop

:start_session
aws ssm start-session --target %HOST% --document-name AWS-StartSSHSession --parameters "portNumber=%PORT%" --profile %AWS_PROFILE% --region %AWS_REGION%
