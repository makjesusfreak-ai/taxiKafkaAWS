@echo off
REM Deploy MSK Infrastructure and Lambda/AppSync Stack

SET CLUSTER_NAME=taxi-kafka-msk
SET REGION=us-east-1
SET ENVIRONMENT=dev

echo ========================================
echo Deploying MSK Infrastructure Stack
echo ========================================

aws cloudformation deploy ^
    --template-file msk-infrastructure.yaml ^
    --stack-name %CLUSTER_NAME%-infrastructure ^
    --parameter-overrides ^
        ClusterName=%CLUSTER_NAME% ^
        Environment=%ENVIRONMENT% ^
    --capabilities CAPABILITY_IAM ^
    --region %REGION%

if %ERRORLEVEL% NEQ 0 (
    echo Failed to deploy infrastructure stack
    exit /b 1
)

echo ========================================
echo Getting Stack Outputs
echo ========================================

FOR /F "tokens=*" %%i IN ('aws cloudformation describe-stacks --stack-name %CLUSTER_NAME%-infrastructure --query "Stacks[0].Outputs[?OutputKey==''MSKClusterArn''].OutputValue" --output text --region %REGION%') DO SET MSK_CLUSTER_ARN=%%i
FOR /F "tokens=*" %%i IN ('aws cloudformation describe-stacks --stack-name %CLUSTER_NAME%-infrastructure --query "Stacks[0].Outputs[?OutputKey==''VPCId''].OutputValue" --output text --region %REGION%') DO SET VPC_ID=%%i
FOR /F "tokens=*" %%i IN ('aws cloudformation describe-stacks --stack-name %CLUSTER_NAME%-infrastructure --query "Stacks[0].Outputs[?OutputKey==''SubnetIds''].OutputValue" --output text --region %REGION%') DO SET SUBNET_IDS=%%i
FOR /F "tokens=*" %%i IN ('aws cloudformation describe-stacks --stack-name %CLUSTER_NAME%-infrastructure --query "Stacks[0].Outputs[?OutputKey==''MSKSecurityGroupId''].OutputValue" --output text --region %REGION%') DO SET MSK_SG_ID=%%i
FOR /F "tokens=*" %%i IN ('aws cloudformation describe-stacks --stack-name %CLUSTER_NAME%-infrastructure --query "Stacks[0].Outputs[?OutputKey==''GlueRegistryArn''].OutputValue" --output text --region %REGION%') DO SET GLUE_REGISTRY_ARN=%%i

echo MSK_CLUSTER_ARN: %MSK_CLUSTER_ARN%
echo VPC_ID: %VPC_ID%
echo SUBNET_IDS: %SUBNET_IDS%
echo MSK_SG_ID: %MSK_SG_ID%
echo GLUE_REGISTRY_ARN: %GLUE_REGISTRY_ARN%

echo ========================================
echo Building SAM Application
echo ========================================

sam build --template-file sam-lambda-appsync.yaml

if %ERRORLEVEL% NEQ 0 (
    echo Failed to build SAM application
    exit /b 1
)

echo ========================================
echo Deploying SAM Application
echo ========================================

sam deploy ^
    --template-file .aws-sam\build\template.yaml ^
    --stack-name %CLUSTER_NAME%-lambda-appsync ^
    --parameter-overrides ^
        ClusterName=%CLUSTER_NAME% ^
        Environment=%ENVIRONMENT% ^
        MSKClusterArn=%MSK_CLUSTER_ARN% ^
        VPCId=%VPC_ID% ^
        SubnetIds=%SUBNET_IDS% ^
        MSKSecurityGroupId=%MSK_SG_ID% ^
        GlueRegistryArn=%GLUE_REGISTRY_ARN% ^
    --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND ^
    --region %REGION% ^
    --resolve-s3

if %ERRORLEVEL% NEQ 0 (
    echo Failed to deploy SAM application
    exit /b 1
)

echo ========================================
echo Deployment Complete!
echo ========================================

echo.
echo Getting AppSync Endpoints...
aws cloudformation describe-stacks --stack-name %CLUSTER_NAME%-lambda-appsync --query "Stacks[0].Outputs" --output table --region %REGION%

echo.
echo Getting MSK Bootstrap Brokers...
aws kafka get-bootstrap-brokers --cluster-arn %MSK_CLUSTER_ARN% --region %REGION%
