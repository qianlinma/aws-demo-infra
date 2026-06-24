# ============================================================
# CodePipeline 第一步：连接 GitHub
# ============================================================

# CodeConnections connection 是 AWS 和 GitHub 之间的授权连接。
# 这里复用你已经在 Console 里连接成功的 aws-demo connection。

# ============================================================
# CodePipeline 第二步：创建 Pipeline 自己需要的 AWS 权限
# ============================================================

# CodePipeline 运行时也需要一个 IAM Role。
# 这段 policy 的作用是允许 CodePipeline 服务“扮演”下面这个 role。
data "aws_iam_policy_document" "codepipeline_assume_role" {
  # statement 是一组权限声明。
  statement {
    # sts:AssumeRole 表示允许某个 AWS 服务使用这个 role。
    actions = ["sts:AssumeRole"]

    # principals 指明谁可以使用这个 role。
    principals {
      # type = Service 表示这是 AWS 服务，不是某个用户。
      type = "Service"

      # codepipeline.amazonaws.com 表示允许 CodePipeline 使用这个 role。
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

# 创建 CodePipeline 使用的 IAM Role。
resource "aws_iam_role" "codepipeline" {
  # 这个名字会显示在 AWS IAM Console 里。
  name = "demo-codepipeline-role-tf"

  # 这里把上面的 trust policy 放进 role，允许 CodePipeline 扮演它。
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
}

# 创建 CodePipeline 的权限 policy。
resource "aws_iam_role_policy" "codepipeline" {
  # 这个 policy 名字会挂在上面的 CodePipeline role 下面。
  name = "demo-codepipeline-policy-tf"

  # role 指明这份权限是给哪个 IAM Role 用的。
  role = aws_iam_role.codepipeline.id

  # policy 里写 CodePipeline 真正能做什么。
  policy = jsonencode({
    # IAM policy language 的版本号，固定写这个。
    Version = "2012-10-17"

    # Statement 是权限列表。
    Statement = [
      # 第一组权限：允许 CodePipeline 使用 GitHub connection 拉代码。
      {
        # Allow 表示允许这些操作。
        Effect = "Allow"

        # codestar-connections:UseConnection 表示可以使用已经授权好的 GitHub connection。
        Action = [
          "codestar-connections:UseConnection"
        ]

        # 只允许使用我们这一个 GitHub connection。
        Resource = var.github_connection_arn
      },
      # 第二组权限：允许 CodePipeline 读写自己的 artifact bucket。

      # CodePipeline 每个阶段之间要传文件，比如 Source 阶段从 GitHub 拉到代码后，会把代码打成一个 zip 包。
      # 这个 zip 包不会直接塞给 CodeBuild，而是先放进一个 S3 bucket，也就是 artifact bucket。
      # 然后 Build 阶段的 CodeBuild 再从这个 bucket 里读取这个 zip 包。
      # 所以 CodePipeline 需要 S3 读写权限：写入 Source 产物，读取并传给下一步。
      # 你可以理解成：artifact bucket 是流水线各个工人之间交接材料的临时仓库。
      {
        # Allow 表示允许这些操作。
        Effect = "Allow"

        # 这些 S3 权限用于上传和读取 pipeline 每一步之间传递的 zip 包。
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]

        # 只允许操作 artifact bucket 里的对象。
        Resource = "${aws_s3_bucket.codepipeline_artifacts.arn}/*"
      },
      # 第三组权限：允许 CodePipeline 查看 artifact bucket 本身。
      {
        # Allow 表示允许这些操作。
        Effect = "Allow"

        # s3:GetBucketVersioning 是 CodePipeline 使用 S3 artifact store 时需要的基础读取权限。
        Action = [
          "s3:GetBucketVersioning"
        ]

        # 这里授权的是 bucket 本身，不是 bucket 里的对象。
        Resource = aws_s3_bucket.codepipeline_artifacts.arn
      },
      # 第四组权限：允许 CodePipeline 启动 CodeBuild。
      {
        # Allow 表示允许这些操作。
        Effect = "Allow"

        # StartBuild 是启动构建，BatchGetBuilds 是查询构建状态。
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds"
        ]

        # 只允许操作我们已经创建的 backend CodeBuild project。
        Resource = [
          aws_codebuild_project.backend_test.arn,
          aws_codebuild_project.backend.arn,
          aws_codebuild_project.frontend.arn
        ]
      },
      # 第五组权限：允许 CodePipeline 部署到 ECS。
      {
        # Allow 表示允许这些操作。
        Effect = "Allow"

        # 这些权限让 CodePipeline 可以读取 ECS service 状态，并触发 service 更新。
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService"
        ]

        # dev 阶段先给 ECS deploy 所需资源范围。
        Resource = "*"
      },
      # 第六组权限：允许 CodePipeline 把 ECS task role 传给 ECS。
      {
        # Allow 表示允许这些操作。
        Effect = "Allow"

        # iam:PassRole 表示允许 CodePipeline 在注册新 task definition 时引用这些 IAM role。
        Action = [
          "iam:PassRole"
        ]

        # 只允许传递我们 ECS task definition 里用到的两个 role。
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.ecs_task.arn
        ]
      }
    ]
  })
}

# ============================================================
# CodePipeline 第三步：创建 Pipeline 的 artifact bucket
# ============================================================

# CodePipeline 每个 stage 之间需要传递文件。
# 例如 Source stage 会把 GitHub 代码打包成 zip，放到这个 S3 bucket。
resource "aws_s3_bucket" "codepipeline_artifacts" {
  # bucket 名字必须全 AWS 唯一，所以加入 account id 和 region。
  bucket = "demo-codepipeline-artifacts-${data.aws_caller_identity.current.account_id}-${var.aws_region}-tf"

  # dev 环境为了方便 destroy，允许 Terraform 删除非空 bucket。
  force_destroy = true
}

# ============================================================
# CodePipeline 通知：Product pipeline 成功/失败时发 SNS
# ============================================================

# 创建一个 SNS Topic，用来接收 product/backend pipeline 的状态通知。
resource "aws_sns_topic" "product_pipeline_notifications" {
  name = "demo-product-pipeline-notifications-tf"
}

# 把 product/backend pipeline 的 SNS 通知发送到指定邮箱。
resource "aws_sns_topic_subscription" "product_pipeline_email" {
  topic_arn = aws_sns_topic.product_pipeline_notifications.arn
  protocol  = "email"
  endpoint  = "qianlin.ma.education@gmail.com"
}

# 允许 CodeStar Notifications 服务向这个 SNS Topic 发布消息。
resource "aws_sns_topic_policy" "product_pipeline_notifications" {
  arn = aws_sns_topic.product_pipeline_notifications.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codestar-notifications.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.product_pipeline_notifications.arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# ============================================================
# CodePipeline 第四步：创建真正的 Pipeline
# ============================================================

# CodePipeline 是 CI/CD 的“总管”。
# 它负责监听 GitHub、触发 CodeBuild，并把每一步串起来。
resource "aws_codepipeline" "backend" {
  # Pipeline 名字会显示在 AWS CodePipeline Console 里。
  name = "demo-backend-pipeline-tf"

  # CodePipeline 运行时使用的 IAM Role。
  role_arn = aws_iam_role.codepipeline.arn

  # artifact_store 指明 pipeline 中间文件放在哪里。
  artifact_store {
    # location 是刚才创建的 S3 artifact bucket。
    location = aws_s3_bucket.codepipeline_artifacts.bucket

    # type = S3 表示用 S3 存放 pipeline artifact。
    type = "S3"
  }

  # 第一个 stage：Source。
  # 它负责从 GitHub repo 拉最新代码。
  stage {
    # stage 名字会显示在 CodePipeline 的流程图里。
    name = "Source"

    # action 是这个 stage 里真正执行的动作。
    action {
      # action 名字会显示在 Source stage 里面。
      name = "GitHub_Source"

      # category = Source 表示这是源码输入步骤。
      category = "Source"

      # owner = AWS 表示使用 AWS 内置 action。
      owner = "AWS"

      # provider = CodeStarSourceConnection 表示通过 CodeStar Connection 读取 GitHub。
      provider = "CodeStarSourceConnection"

      # version 固定写 1。
      version = "1"

      # output_artifacts 是 Source stage 产生的源码包名字。
      output_artifacts = ["source_output"]

      # configuration 是这个 action 的具体配置。
      configuration = {
        # ConnectionArn 指向你已经授权好的 aws-demo CodeConnections connection。
        ConnectionArn = var.github_connection_arn

        # FullRepositoryId 指明 backend 的 GitHub repo：用户名/仓库名。
        FullRepositoryId = "qianlinma/aws-demo-backtend"

        # BranchName 指明监听哪个分支。
        BranchName = "main"

        # CODE_ZIP 表示把 GitHub 源码打包成 zip 传给下一步。
        OutputArtifactFormat = "CODE_ZIP"

        # DetectChanges = true 表示 GitHub main 分支有新 commit 时自动触发 pipeline。
        DetectChanges = "true"
      }
    }
  }

  # 第二个 stage：Test。
  # 它负责先运行 backend unit tests。
  stage {
    # stage 名字会显示在 CodePipeline 的流程图里。
    name = "Test"

    # action 是这个 stage 里真正执行的动作。
    action {
      # action 名字会显示在 Test stage 里面。
      name = "Backend_Test"

      # category = Test 表示这是测试步骤。
      category = "Test"

      # owner = AWS 表示使用 AWS 内置 action。
      owner = "AWS"

      # provider = CodeBuild 表示这个 action 会调用 CodeBuild。
      provider = "CodeBuild"

      # version 固定写 1。
      version = "1"

      # input_artifacts 指明 Test stage 接收 Source stage 产生的源码包。
      input_artifacts = ["source_output"]

      # configuration 是这个 action 的具体配置。
      configuration = {
        # ProjectName 指明要启动哪个 backend test CodeBuild project。
        ProjectName = aws_codebuild_project.backend_test.name
      }
    }
  }

  # 第三个 stage：Build。
  # 它负责把 Source stage 拉下来的代码交给 CodeBuild 构建 Docker image。
  stage {
    # stage 名字会显示在 CodePipeline 的流程图里。
    name = "Build"

    # action 是这个 stage 里真正执行的动作。
    action {
      # action 名字会显示在 Build stage 里面。
      name = "Backend_Build"

      # category = Build 表示这是构建步骤。
      category = "Build"

      # owner = AWS 表示使用 AWS 内置 action。
      owner = "AWS"

      # provider = CodeBuild 表示这个 action 会调用 CodeBuild。
      provider = "CodeBuild"

      # version 固定写 1。
      version = "1"

      # input_artifacts 指明 Build stage 接收 Source stage 产生的源码包。
      input_artifacts = ["source_output"]

      # output_artifacts 指明 Build stage 输出给下一步的文件包。
      # 这里会包含 buildspec 生成的 imagedefinitions.json。
      output_artifacts = ["build_output"]

      # configuration 是这个 action 的具体配置。
      configuration = {
        # ProjectName 指明要启动哪个 CodeBuild project。
        ProjectName = aws_codebuild_project.backend.name
      }
    }
  }

  # 第四个 stage：Deploy。
  # 它负责把 Build stage 输出的 imagedefinitions.json 交给 ECS。
  stage {
    # stage 名字会显示在 CodePipeline 的流程图里。
    name = "Deploy"

    # action 是这个 stage 里真正执行的动作。
    action {
      # action 名字会显示在 Deploy stage 里面。
      name = "Backend_Deploy"

      # category = Deploy 表示这是部署步骤。
      category = "Deploy"

      # owner = AWS 表示使用 AWS 内置 action。
      owner = "AWS"

      # provider = ECS 表示这个 action 会部署到 ECS service。
      provider = "ECS"

      # version 固定写 1。
      version = "1"

      # input_artifacts 指明 Deploy stage 接收 Build stage 输出的文件包。
      input_artifacts = ["build_output"]

      # configuration 是这个 action 的具体配置。
      configuration = {
        # ClusterName 指明要部署到哪个 ECS cluster。
        ClusterName = aws_ecs_cluster.main.name

        # ServiceName 指明要更新哪个 ECS service。
        ServiceName = aws_ecs_service.backend.name

        # FileName 指明在 build_output artifact 里读取哪个文件。
        # 这个文件由 buildspec-backend.yml 生成。
        FileName = "imagedefinitions.json"
      }
    }
  }
}

# 监听 product/backend pipeline 的最终成功或失败，并发送到 SNS Topic。
resource "aws_codestarnotifications_notification_rule" "product_pipeline" {
  name        = "demo-product-pipeline-notifications-tf"
  detail_type = "BASIC"
  resource    = aws_codepipeline.backend.arn

  event_type_ids = [
    "codepipeline-pipeline-pipeline-execution-succeeded",
    "codepipeline-pipeline-pipeline-execution-failed"
  ]

  target {
    address = aws_sns_topic.product_pipeline_notifications.arn
    type    = "SNS"
  }

  depends_on = [aws_sns_topic_policy.product_pipeline_notifications]
}

# 创建 frontend 的 CodePipeline。
# 它负责监听 GitHub、触发 frontend CodeBuild，并部署到 frontend ECS service。
resource "aws_codepipeline" "frontend" {
  # Pipeline 名字会显示在 AWS CodePipeline Console 里。
  name = "demo-frontend-pipeline-tf"

  # frontend pipeline 复用同一个 CodePipeline IAM Role。
  role_arn = aws_iam_role.codepipeline.arn

  # artifact_store 指明 pipeline 中间文件放在哪里。
  artifact_store {
    # location 是 CodePipeline artifact bucket。
    location = aws_s3_bucket.codepipeline_artifacts.bucket

    # type = S3 表示用 S3 存放 pipeline artifact。
    type = "S3"
  }

  # 第一个 stage：Source。
  # 它负责从 frontend GitHub repo 拉最新代码。
  stage {
    # stage 名字会显示在 CodePipeline 的流程图里。
    name = "Source"

    # action 是这个 stage 里真正执行的动作。
    action {
      # action 名字会显示在 Source stage 里面。
      name = "GitHub_Source"

      # category = Source 表示这是源码输入步骤。
      category = "Source"

      # owner = AWS 表示使用 AWS 内置 action。
      owner = "AWS"

      # provider = CodeStarSourceConnection 表示通过 CodeStar Connection 读取 GitHub。
      provider = "CodeStarSourceConnection"

      # version 固定写 1。
      version = "1"

      # output_artifacts 是 Source stage 产生的源码包名字。
      output_artifacts = ["source_output"]

      # configuration 是这个 action 的具体配置。
      configuration = {
        # ConnectionArn 指向你已经授权好的 aws-demo CodeConnections connection。
        ConnectionArn = var.github_connection_arn

        # FullRepositoryId 指明 frontend 的 GitHub repo：用户名/仓库名。
        FullRepositoryId = "qianlinma/aws-demo-frontend"

        # BranchName 指明监听哪个分支。
        BranchName = "main"

        # CODE_ZIP 表示把 GitHub 源码打包成 zip 传给下一步。
        OutputArtifactFormat = "CODE_ZIP"

        # DetectChanges = true 表示 GitHub main 分支有新 commit 时自动触发 pipeline。
        DetectChanges = "true"
      }
    }
  }

  # 第二个 stage：Build。
  # 它负责把 Source stage 拉下来的代码交给 frontend CodeBuild。
  stage {
    # stage 名字会显示在 CodePipeline 的流程图里。
    name = "Build"

    # action 是这个 stage 里真正执行的动作。
    action {
      # action 名字会显示在 Build stage 里面。
      name = "Frontend_Build"

      # category = Build 表示这是构建步骤。
      category = "Build"

      # owner = AWS 表示使用 AWS 内置 action。
      owner = "AWS"

      # provider = CodeBuild 表示这个 action 会调用 CodeBuild。
      provider = "CodeBuild"

      # version 固定写 1。
      version = "1"

      # input_artifacts 指明 Build stage 接收 Source stage 产生的源码包。
      input_artifacts = ["source_output"]

      # output_artifacts 指明 Build stage 输出给下一步的文件包。
      # 这里会包含 frontend buildspec 生成的 imagedefinitions.json。
      output_artifacts = ["build_output"]

      # configuration 是这个 action 的具体配置。
      configuration = {
        # ProjectName 指明要启动哪个 frontend CodeBuild project。
        ProjectName = aws_codebuild_project.frontend.name
      }
    }
  }

  # 第三个 stage：Deploy。
  # 它负责把 Build stage 输出的 imagedefinitions.json 交给 ECS。
  stage {
    # stage 名字会显示在 CodePipeline 的流程图里。
    name = "Deploy"

    # action 是这个 stage 里真正执行的动作。
    action {
      # action 名字会显示在 Deploy stage 里面。
      name = "Frontend_Deploy"

      # category = Deploy 表示这是部署步骤。
      category = "Deploy"

      # owner = AWS 表示使用 AWS 内置 action。
      owner = "AWS"

      # provider = ECS 表示这个 action 会部署到 ECS service。
      provider = "ECS"

      # version 固定写 1。
      version = "1"

      # input_artifacts 指明 Deploy stage 接收 Build stage 输出的文件包。
      input_artifacts = ["build_output"]

      # configuration 是这个 action 的具体配置。
      configuration = {
        # ClusterName 指明要部署到哪个 ECS cluster。
        ClusterName = aws_ecs_cluster.main.name

        # ServiceName 指明要更新哪个 frontend ECS service。
        ServiceName = aws_ecs_service.frontend.name

        # FileName 指明在 build_output artifact 里读取哪个文件。
        # 这个文件由 buildspec-frontend.yml 生成。
        FileName = "imagedefinitions.json"
      }
    }
  }
}
