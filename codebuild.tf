# CodeBuild 是 AWS 提供的云端构建服务。
# 以前你在本机执行 docker build / docker push；以后这些命令会逐步搬到 CodeBuild 里执行。

# CodeBuild 运行时需要一个 IAM Role。
# 这段 policy 的作用是允许 CodeBuild 服务“扮演”下面这个 role。
data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

# 创建 backend CodeBuild 使用的 IAM Role。
resource "aws_iam_role" "codebuild_backend" {
  name               = "demo-backend-codebuild-role-tf"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
}

# 先给 CodeBuild 最基础的 CloudWatch Logs 权限和 ECR 权限。
# Logs 权限让我们能在 AWS Console 看到命令输出。
# ECR 权限让 CodeBuild 下一步可以登录 ECR，并把 Docker image push 到 ECR。
resource "aws_iam_role_policy" "codebuild_backend_logs" {
  name = "demo-backend-codebuild-logs-policy-tf"
  role = aws_iam_role.codebuild_backend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 第一组权限：允许 CodeBuild 写 CloudWatch Logs。
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      # 第二组权限：允许 CodeBuild 获取 ECR 登录 token。
      # 因为 ECR 是私有镜像仓库，不是任何机器都能直接 push image。
      # CodeBuild 要把 Docker image 推到 ECR，第一步必须先“登录”ECR。
      # ecr:GetAuthorizationToken 就是让 CodeBuild 向 ECR 要一个临时登录凭证。
      # 拿到 token 后，buildspec 里才能执行类似 aws ecr get-login-password | docker login ...。
      # 没有这个权限，后面 docker push 会因为未登录而失败。

      # 这个权限必须是 Resource = "*"，AWS ECR 的登录 token 不是某一个 repository 专属资源。
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      # 第三组权限：允许 CodeBuild 把 backend image layer 和 image manifest push 到 backend ECR。

      # 第二组权限只解决“能不能登录 ECR”。
      # 登录成功以后，CodeBuild 还要真正上传 image 内容。
      # 第三组权限就是允许它上传 image 的各个部分：检查 layer、开始上传 layer、上传 layer 分片、完成上传、最后写入 image manifest。
      # 你可以理解成：第二组是“拿门禁卡进仓库”，第三组是“允许把货物放进指定货架”。
      # 所以只给第二组，docker login 会成功，但 docker push 还是会失败。
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = aws_ecr_repository.backend.arn
      },
      # 第四组权限：允许 CodeBuild 读取 CodePipeline 放在 S3 artifact bucket 里的源码包。
      # 接入 CodePipeline 后，GitHub 源码不是 CodeBuild 自己拉的。
      # CodePipeline 会先把 GitHub 代码下载下来，打包成 artifact，放进下面这个 S3 bucket。
      # CodeBuild 再从这个 bucket 读取源码 artifact，然后执行 buildspec。
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.codepipeline_artifacts.arn}/*"
      }
    ]
  })
}

# 创建 backend 的 CodeBuild Project。
# 这个 Project 就是 AWS Console 里可以手动点击 Start build 的构建任务。
resource "aws_codebuild_project" "backend" {
  name          = "demo-backend-build-tf"
  description   = "Run the backend buildspec for the demo project."
  service_role  = aws_iam_role.codebuild_backend.arn
  build_timeout = 10

  # 现在开始接 CodePipeline，所以 source 改成 CODEPIPELINE。
  # 这表示 CodeBuild 不再自己找代码，而是等 CodePipeline 把 GitHub 代码传进来。
  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspec-backend.yml")
  }

  # artifacts 也改成 CODEPIPELINE。
  # 这表示构建输出如果有产物，也交回给 CodePipeline 管理。
  # 当前 backend buildspec 主要是 push Docker image 到 ECR，所以暂时没有额外文件产物。
  artifacts {
    type = "CODEPIPELINE"
  }

  # CodeBuild 会启动一个临时 Linux container，在里面执行 buildspec 的 commands。
  environment {
    # compute_type 表示构建机器规格；SMALL 对当前 demo 足够。
    compute_type = "BUILD_GENERAL1_SMALL"

    # image 表示 CodeBuild 使用哪一个官方构建镜像。
    # 这里使用 ARM64 版 CodeBuild 镜像，因为 ECS task definition 配置的是 ARM64。
    image = "aws/codebuild/amazonlinux-aarch64-standard:3.0"

    # type = ARM_CONTAINER 表示 CodeBuild 本身运行在 ARM64 架构上。
    # 这样 docker build 过程中执行 /bin/sh、mvnw 等命令时不会出现 exec format error。
    type = "ARM_CONTAINER"

    # privileged_mode 允许 CodeBuild 在构建环境里运行 Docker daemon。
    # 后面 buildspec 要执行 docker build，所以这里必须打开。
    privileged_mode = true

    # 给 buildspec 提供 AWS_ACCOUNT_ID 变量。
    environment_variable {
      # 变量名；buildspec 里会用 $AWS_ACCOUNT_ID 读取它。
      name = "AWS_ACCOUNT_ID"

      # 当前 AWS account id，用来拼出 ECR registry 地址。
      value = data.aws_caller_identity.current.account_id
    }

    # 给 buildspec 提供 backend ECR repository 的完整地址。
    environment_variable {
      # 变量名；buildspec 里会用 $REPOSITORY_URI 读取它。
      name = "REPOSITORY_URI"

      # 当前 Terraform 创建的 backend ECR repository URL。
      value = aws_ecr_repository.backend.repository_url
    }
  }
}

# 创建 backend Test stage 专用的 CodeBuild Project。
# 它只运行 ./mvnw test，不负责 build/push Docker image。
resource "aws_codebuild_project" "backend_test" {
  # CodeBuild project 名字会显示在 AWS Console 里。
  name = "demo-backend-test-tf"

  # description 说明这个 build project 的用途。
  description = "Run backend unit tests before building the Docker image."

  # 复用 backend CodeBuild role。
  # 这个 role 已经有 CloudWatch Logs 和 CodePipeline artifact bucket 权限。
  service_role = aws_iam_role.codebuild_backend.arn

  # unit tests 应该比较快，先给 10 分钟上限。
  build_timeout = 10

  # source = CODEPIPELINE 表示源码由 CodePipeline 的 Source stage 传进来。
  source {
    # type 指明源码来源是 CodePipeline。
    type = "CODEPIPELINE"

    # buildspec 指向只运行 unit tests 的构建说明书。
    buildspec = file("${path.module}/buildspec-backend-test.yml")
  }

  # Test stage 不需要产出文件给下一步。
  # 这里仍然使用 CODEPIPELINE，让 CodePipeline 管理这个 action。
  artifacts {
    # type 指明 artifact 由 CodePipeline 管理。
    type = "CODEPIPELINE"
  }

  # environment 定义 CodeBuild 运行测试时的临时环境。
  environment {
    # compute_type 表示构建机器规格；SMALL 对当前 unit tests 足够。
    compute_type = "BUILD_GENERAL1_SMALL"

    # image 使用和 backend build 相同的 ARM64 CodeBuild 镜像。
    image = "aws/codebuild/amazonlinux-aarch64-standard:3.0"

    # type = ARM_CONTAINER 表示 CodeBuild 本身运行在 ARM64 架构上。
    type = "ARM_CONTAINER"
  }
}

# 创建 frontend CodeBuild 使用的 IAM Role。
resource "aws_iam_role" "codebuild_frontend" {
  # 这个名字会显示在 AWS IAM Console 里。
  name = "demo-frontend-codebuild-role-tf"

  # 复用 CodeBuild 的 trust policy，允许 CodeBuild 服务扮演这个 role。
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
}

# 给 frontend CodeBuild 配置 CloudWatch Logs、ECR、S3 artifact 权限。
resource "aws_iam_role_policy" "codebuild_frontend_logs" {
  # 这个 policy 名字会挂在 frontend CodeBuild role 下面。
  name = "demo-frontend-codebuild-logs-policy-tf"

  # role 指明这份权限是给哪个 IAM Role 用的。
  role = aws_iam_role.codebuild_frontend.id

  # policy 里写 frontend CodeBuild 真正能做什么。
  policy = jsonencode({
    # IAM policy language 的版本号，固定写这个。
    Version = "2012-10-17"

    # Statement 是权限列表。
    Statement = [
      # 第一组权限：允许 CodeBuild 写 CloudWatch Logs。
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      # 第二组权限：允许 CodeBuild 获取 ECR 登录 token。
      # 这个权限用于 buildspec 里的 aws ecr get-login-password。
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      # 第三组权限：允许 CodeBuild 把 frontend image push 到 frontend ECR。
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = aws_ecr_repository.frontend.arn
      },
      # 第四组权限：允许 CodeBuild 读取 CodePipeline 放在 S3 artifact bucket 里的源码包。
      # Build 完成后，也需要把 imagedefinitions.json 写回 artifact bucket。
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.codepipeline_artifacts.arn}/*"
      }
    ]
  })
}

# 创建 frontend 的 CodeBuild Project。
# 这个 Project 会构建 frontend Docker image，并 push 到 frontend ECR。
resource "aws_codebuild_project" "frontend" {
  # CodeBuild project 名字会显示在 AWS Console 里。
  name = "demo-frontend-build-tf"

  # description 说明这个 build project 的用途。
  description = "Run the frontend buildspec for the demo project."

  # service_role 指明 CodeBuild 运行时使用哪个 IAM Role。
  service_role = aws_iam_role.codebuild_frontend.arn

  # build_timeout 是构建最长运行时间，单位是分钟。
  build_timeout = 10

  # source = CODEPIPELINE 表示源码由 CodePipeline 传进来。
  source {
    # type 指明源码来源是 CodePipeline。
    type = "CODEPIPELINE"

    # buildspec 指明 frontend 构建说明书内容。
    buildspec = file("${path.module}/buildspec-frontend.yml")
  }

  # artifacts = CODEPIPELINE 表示构建输出交回给 CodePipeline。
  # 这里输出的是 imagedefinitions.json。
  artifacts {
    # type 指明 artifact 由 CodePipeline 管理。
    type = "CODEPIPELINE"
  }

  # environment 定义 CodeBuild 运行时的临时构建环境。
  environment {
    # compute_type 表示构建机器规格；SMALL 对当前 demo 足够。
    compute_type = "BUILD_GENERAL1_SMALL"

    # image 表示 CodeBuild 使用哪一个官方构建镜像。
    # 这里使用 ARM64 版 CodeBuild 镜像，因为 frontend ECS task definition 也配置的是 ARM64。
    image = "aws/codebuild/amazonlinux-aarch64-standard:3.0"

    # type = ARM_CONTAINER 表示 CodeBuild 本身运行在 ARM64 架构上。
    # 这样构建出来的 Docker image 能直接在 ARM64 ECS Fargate task 上运行。
    type = "ARM_CONTAINER"

    # privileged_mode 允许 CodeBuild 在构建环境里运行 Docker daemon。
    # frontend buildspec 也要执行 docker build，所以这里必须打开。
    privileged_mode = true

    # 给 buildspec 提供 AWS_ACCOUNT_ID 变量。
    environment_variable {
      # 变量名；buildspec 里会用 $AWS_ACCOUNT_ID 读取它。
      name = "AWS_ACCOUNT_ID"

      # 当前 AWS account id，用来拼出 ECR registry 地址。
      value = data.aws_caller_identity.current.account_id
    }

    # 给 buildspec 提供 frontend ECR repository 的完整地址。
    environment_variable {
      # 变量名；buildspec 里会用 $REPOSITORY_URI 读取它。
      name = "REPOSITORY_URI"

      # 当前 Terraform 创建的 frontend ECR repository URL。
      value = aws_ecr_repository.frontend.repository_url
    }
  }
}
