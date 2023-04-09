# create lambda function
data "aws_caller_identity" "aws_identity" {}
data "aws_region" "aws_region" {}

data "archive_file" "routed_lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/../routed_lambda.zip"
}

resource "null_resource" "build_lambda_deps_zip" {
  triggers = {
    dependencies = filebase64sha256("${path.module}/../requirements.txt")
  }

  provisioner "local-exec" {
    command = <<-EOD
        cd ${path.module}/../
        docker run -v "$PWD":/var/task "public.ecr.aws/sam/build-python3.9" /bin/sh -c "pip install -r requirements.txt -t python/lib/python3.9/site-packages/; exit"
        zip -rg routed_lambda_deps.zip python
    EOD
  }
}


# add layer to lambda function
resource "aws_lambda_layer_version" "routed_lambda_deps" {
  depends_on = [null_resource.build_lambda_deps_zip]

  filename            = "${path.module}/../routed_lambda_deps.zip"
  source_code_hash    = filebase64sha256("${path.module}/../routed_lambda_deps.zip")
  layer_name          = "routed_lambda_deps"
  compatible_runtimes = ["python3.9"]
}


# give the lambda a role
resource "aws_iam_role" "routed_lambda_role" {
  name = "routed_lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# attach a list of policies to role
resource "aws_iam_role_policy_attachment" "routed_lambda_policy_attachment" {
  role       = aws_iam_role.routed_lambda_role.name
  policy_arn = each.value

  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    "arn:aws:iam::aws:policy/CloudWatchFullAccess"
  ])
}


# create lambda function
resource "aws_lambda_function" "routed_lambda" {
  function_name    = "routed_lambda"
  role             = aws_iam_role.routed_lambda_role.arn
  handler          = "index.app"
  runtime          = "python3.9"
  filename         = "${data.archive_file.routed_lambda_zip.output_path}"
  source_code_hash = "${data.archive_file.routed_lambda_zip.output_base64sha256}"

  layers = [aws_lambda_layer_version.routed_lambda_deps.arn]
  environment {
    variables = {
      "TABLE_NAME" = ""
    }
  }
}


resource "aws_iam_role" "routed_lambda_api_role" {
  name = "routed_lambda_api"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : ["apigateway.amazonaws.com"]
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "routed_lambda_api_policy_attachment" {
  role       = aws_iam_role.routed_lambda_api_role.name
  policy_arn = each.value

  for_each = toset([
    "arn:aws:iam::aws:policy/CloudWatchFullAccess",
  ])
}


# create api gateway
resource "aws_api_gateway_rest_api" "routed_lambda_api" {
  name        = "routed_lambda"
  description = "routed_lambda"

   endpoint_configuration {
    types = ["REGIONAL"]
  }
 
}

resource "aws_api_gateway_rest_api_policy" "routed_lambda_api_policy" {
  rest_api_id = aws_api_gateway_rest_api.routed_lambda_api.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : "*",
        "Action" : [
          "execute-api:Invoke",
          "execute-api:ManageConnections",
        ],
        "Resource" : [
          "arn:aws:execute-api:${data.aws_region.aws_region.name}:${data.aws_caller_identity.aws_identity.account_id}:${aws_api_gateway_rest_api.routed_lambda_api.id}/${aws_api_gateway_deployment.routed_lambda_deployment.stage_name}/*"
        ]
      }
    ]
  })
}

resource "aws_api_gateway_account" "routed_lambda_api_account" {
  cloudwatch_role_arn = aws_iam_role.routed_lambda_api_role.arn
}

# create api gateway resource
resource "aws_api_gateway_resource" "routed_lambda_root_resource" {
  rest_api_id = aws_api_gateway_rest_api.routed_lambda_api.id
  parent_id   = aws_api_gateway_rest_api.routed_lambda_api.root_resource_id
  path_part   = "{proxy+}"
}

# create api gateway method
resource "aws_api_gateway_method" "routed_lambda_root_method" {
  rest_api_id   = aws_api_gateway_rest_api.routed_lambda_api.id
  resource_id   = aws_api_gateway_resource.routed_lambda_root_resource.id
  http_method   = "ANY"
  authorization = "NONE"
}

# create api gateway integration
resource "aws_api_gateway_integration" "routed_lambda_root_integration" {
  rest_api_id             = aws_api_gateway_rest_api.routed_lambda_api.id
  resource_id             = aws_api_gateway_resource.routed_lambda_root_resource.id
  http_method             = aws_api_gateway_method.routed_lambda_root_method.http_method
  integration_http_method = "ANY"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.routed_lambda.invoke_arn
}

# api deployment
resource "aws_api_gateway_deployment" "routed_lambda_deployment" {
  depends_on = [aws_api_gateway_integration.routed_lambda_root_integration]

  rest_api_id = aws_api_gateway_rest_api.routed_lambda_api.id
  stage_name  = "prod"
}

resource "aws_cloudwatch_log_group" "routed_lambda_log_group" {
    name = "/aws/lambda/routed_lambda"
}

# create api gateway stage
resource "aws_api_gateway_stage" "routed_lambda_stage" {
  rest_api_id = aws_api_gateway_rest_api.routed_lambda_api.id
  stage_name  = aws_api_gateway_deployment.routed_lambda_deployment.stage_name
  deployment_id = aws_api_gateway_deployment.routed_lambda_deployment.id
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.routed_lambda_log_group.arn
    format = "$context.identity.sourceIp - $context.identity.caller - $context.identity.user [$context.requestTime] \"$context.httpMethod $context.resourcePath $context.protocol\" $context.status $context.responseLength $context.requestId"
  }
}


# create api gateway
resource "aws_lambda_permission" "routed_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.routed_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_deployment.routed_lambda_deployment.execution_arn}/*/*"
}

