provider "aws" {
  # 告诉 AWS Provider 资源创建在哪个 region。
  region = var.aws_region
  # 告诉 AWS Provider 使用哪个本地 AWS credentials profile。
  profile = var.aws_profile
}

# 读取当前 region 可用的 Availability Zones。
# 后面创建 public/private subnets 时，会把它们分散到两个 AZ，提高可用性。
data "aws_availability_zones" "available" {
  state = "available"
}

# 读取当前 AWS account id。
# S3 bucket 名字必须全局唯一，所以这里用 account id 拼出唯一 bucket 名。
data "aws_caller_identity" "current" {}

# ============================================================
# VPC/Subnets：显式管理应用网络边界
# ============================================================

# 创建应用自己的 VPC，不依赖 AWS default VPC。
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true
  # 只是给资源起名字，方便你在 AWS Console 里识别。
  tags = {
    Name = "demo-vpc-tf"
  }
}

# Internet Gateway 让 public subnets 可以和公网互通。
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "demo-igw-tf"
  }
}

# 创建两个 public subnets，给 public ALB 和 NAT Gateway 使用。
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr_blocks[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "demo-public-subnet-${count.index + 1}-tf"
  }
}

# Public route table：public subnets 的默认路由走 Internet Gateway。
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "demo-public-rt-tf"
  }
}

# 把 public route table 绑定到 public subnets。
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# 给 private subnets 创建 NAT Gateway 使用的 Elastic IP。
# NAT Gateway 需要公网 IP，private subnet 里的 ECS task 会通过它访问 ECR、CloudWatch 等外部服务。
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "demo-backend-nat-eip-tf"
  }
}

# 在 public subnet 里创建 NAT Gateway。
# NAT Gateway 放在 public subnet，private subnet 通过它出网，但公网不能主动连进 private subnet。
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "demo-backend-nat-tf"
  }
}

# 创建两个 private subnets，专门给 ECS Fargate task 使用。
# 这些 subnet 不自动分配公网 IP，task 会更接近生产环境的部署方式。
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr_blocks[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "demo-backend-private-subnet-${count.index + 1}-tf"
  }
}

# 创建 private route table。
# private subnet 的默认出站流量会指向 NAT Gateway。
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "demo-backend-private-rt-tf"
  }
}

# 把 private route table 绑定到两个 ECS private subnets。
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# 创建一个 ECR repository，用来保存 backend 的 Docker image。
# 后面 ECS Task Definition 会引用这个 repository 里的 image URI。
# resource "<资源类型>" "<本地名字>"
resource "aws_ecr_repository" "backend" {
  name = var.backend_ecr_repository_name
  # MUTABLE 表示同一个 tag 可以被覆盖，例如 latest 可以指向新 image。
  # 学习阶段使用 latest 比较方便；生产环境常用不可变 tag 或 git sha。
  image_tag_mutability = "MUTABLE"

  # 开启 push 后自动扫描 image 漏洞。
  # 这不会影响运行，只是提供安全检查结果。
  image_scanning_configuration {
    scan_on_push = true
  }
}

# 创建一个 ECR repository，用来保存 frontend 的 Docker image。
# 这个 image 里面会包含 Nginx 和前端静态文件。
resource "aws_ecr_repository" "frontend" {
  name                 = var.frontend_ecr_repository_name
  image_tag_mutability = "MUTABLE"

  # 开启 push 后自动扫描 image 漏洞。
  image_scanning_configuration {
    scan_on_push = true
  }
}

# 创建 ECS cluster。
# Cluster 本身只是 ECS 的逻辑工作区，不会直接运行 container。
# 后面 ECS Service 会引用这个 cluster，并在里面启动 Spring Boot backend task。
resource "aws_ecs_cluster" "main" {
  name = var.ecs_cluster_name
}

resource "aws_service_discovery_private_dns_namespace" "demo" {
  name        = var.service_discovery_namespace_name
  description = "Private DNS namespace for demo microservices."
  vpc         = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }
}

# 定义 IAM trust policy。
# 这段 是trust policy 表示：允许 ECS Tasks 服务来 assume 下面创建的 IAM role。
# 注意这里不是给人用的 credentials，而是给 AWS ECS/Fargate 平台启动 task 时使用。
data "aws_iam_policy_document" "ecs_task_execution_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# 创建 ECS Task Execution Role。
# 这个 role 会在 ECS Task Definition 里作为 execution_role_arn 使用。
resource "aws_iam_role" "ecs_task_execution" {
  name = var.ecs_task_execution_role_name
  # assume_role_policy 是定义这个role资源的属性，属性就是trust policy
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json
}

# 创建 ECS Task Role。
# 这个 role 是给 container 里的应用代码用的，不是给 ECS 平台拉镜像用的。
# 后端 Spring Boot 之后通过 AWS SDK 访问 DynamoDB 时，会使用这个 role 的权限。
resource "aws_iam_role" "ecs_task" {
  name = var.ecs_task_role_name
  # assume_role_policy 是定义这个role资源的属性，属性就是trust policy
  assume_role_policy = data.aws_iam_policy_document.ecs_task_execution_assume_role.json
}

# 给 ECS Task Execution Role 附加 AWS 托管策略。
# 这个策略包含 ECS 从 ECR 拉 image、写 CloudWatch Logs 所需的基础权限。
# role = aws_iam_role.ecs_task_execution.name：表示要把权限加到哪个 IAM Role 上，这里是你前面定义的 ecs_task_execution 这个 role。
# policy_arn = "...AmazonECSTaskExecutionRolePolicy"：表示要加哪一组权限，这里是 AWS 官方提供的 ECS Task Execution 基础权限策略。
# 合起来就是：把 AmazonECSTaskExecutionRolePolicy 这套权限绑定到 ecs_task_execution 这个 role 上。
# 也就是让 ECS 可以用这个 role 去拉 ECR 镜像、写 CloudWatch 日志等。

# 这里定义的是一个 policy attachment，也就是“把某个已经存在的 policy 绑定到某个 role 上”。
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role = aws_iam_role.ecs_task_execution.name
  # 这是一个permission policy， aws现成可以直接用的
  # permission policy 这里也没有手写 JSON，而是通过 policy_arn 引用了 AWS 已经写好的托管策略 AmazonECSTaskExecutionRolePolicy。
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ============================================================
# DynamoDB：产品数据表和 ECS 访问权限
# ============================================================

# 创建 DynamoDB table 保存 demo 产品数据。
# id 是 partition key，类型 N 表示 Number。
resource "aws_dynamodb_table" "products" {
  name         = var.products_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "N"
  }
}

# 给 ECS Task Role 授权读取 DynamoDB 产品表。
# 这里只给读权限：Scan/GetItem/Query，符合当前 /api/getAllProducts 的需求。
resource "aws_iam_role_policy" "ecs_task_dynamodb_read" {
  name = "demo-products-dynamodb-read-tf"
  role = aws_iam_role.ecs_task.id # 把这个 inline policy 挂到 ecs_task 这个 IAM Role 上。aws_iam_role.ecs_task 是你前面定义的 task role。
  # .id 在这里通常就是这个 role 的名字/标识，Terraform 用它知道要 attach 到哪个 role。

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Scan",
          "dynamodb:GetItem",
          "dynamodb:Query"
        ]
        Resource = aws_dynamodb_table.products.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_cloudwatch_metrics" {
  name = "demo-products-cloudwatch-metrics-tf"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "Demo/ProductService"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecs_task_xray_write" {
  name = "demo-products-xray-write-tf"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

# ============================================================
# S3：产品图片资源
# ============================================================

# 创建 S3 bucket 保存 demo 产品图片。
# 这里让 bucket 名包含 account id 和 region，避免和别人账号里的 bucket 重名。
resource "aws_s3_bucket" "product_assets" {
  bucket        = "demo-product-assets-${data.aws_caller_identity.current.account_id}-${var.aws_region}-tf"
  force_destroy = true

  tags = {
    Name = "demo-product-assets-tf"
  }
}

# 关闭这个 demo bucket 的 public access block。
# 学习阶段这样做是为了让浏览器能直接加载产品图片；生产环境通常会用 CloudFront 或签名 URL。
resource "aws_s3_bucket_public_access_block" "product_assets" {
  bucket = aws_s3_bucket.product_assets.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# 允许公网读取 product-images/ 下的图片。
resource "aws_s3_bucket_policy" "product_assets_public_read" {
  bucket = aws_s3_bucket.product_assets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.product_assets.arn}/product-images/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.product_assets]
}

# 上传 6 张 demo 产品图片到 S3。
resource "aws_s3_object" "product_1_image" {
  bucket       = aws_s3_bucket.product_assets.id
  key          = "product-images/product-1.svg"
  source       = "${path.module}/Assets/product-images/product-1.svg"
  content_type = "image/svg+xml"
  etag         = filemd5("${path.module}/Assets/product-images/product-1.svg")
}

resource "aws_s3_object" "product_2_image" {
  bucket       = aws_s3_bucket.product_assets.id
  key          = "product-images/product-2.svg"
  source       = "${path.module}/Assets/product-images/product-2.svg"
  content_type = "image/svg+xml"
  etag         = filemd5("${path.module}/Assets/product-images/product-2.svg")
}

resource "aws_s3_object" "product_3_image" {
  bucket       = aws_s3_bucket.product_assets.id
  key          = "product-images/product-3.svg"
  source       = "${path.module}/Assets/product-images/product-3.svg"
  content_type = "image/svg+xml"
  etag         = filemd5("${path.module}/Assets/product-images/product-3.svg")
}

resource "aws_s3_object" "product_4_image" {
  bucket       = aws_s3_bucket.product_assets.id
  key          = "product-images/product-4.svg"
  source       = "${path.module}/Assets/product-images/product-4.svg"
  content_type = "image/svg+xml"
  etag         = filemd5("${path.module}/Assets/product-images/product-4.svg")
}

resource "aws_s3_object" "product_5_image" {
  bucket       = aws_s3_bucket.product_assets.id
  key          = "product-images/product-5.svg"
  source       = "${path.module}/Assets/product-images/product-5.svg"
  content_type = "image/svg+xml"
  etag         = filemd5("${path.module}/Assets/product-images/product-5.svg")
}

resource "aws_s3_object" "product_6_image" {
  bucket       = aws_s3_bucket.product_assets.id
  key          = "product-images/product-6.svg"
  source       = "${path.module}/Assets/product-images/product-6.svg"
  content_type = "image/svg+xml"
  etag         = filemd5("${path.module}/Assets/product-images/product-6.svg")
}

# 插入 6 条 demo 产品数据。
# 这让 DynamoDB table 创建后马上有数据，后端改成读 DDB 后可以直接看到效果。
resource "aws_dynamodb_table_item" "product_1" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    id    = { N = "1" }
    title = { S = "First product" }
    path  = { S = "https://${aws_s3_bucket.product_assets.bucket}.s3.${var.aws_region}.amazonaws.com/${aws_s3_object.product_1_image.key}" }
  })
}

resource "aws_dynamodb_table_item" "product_2" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    id    = { N = "2" }
    title = { S = "Second product" }
    path  = { S = "https://${aws_s3_bucket.product_assets.bucket}.s3.${var.aws_region}.amazonaws.com/${aws_s3_object.product_2_image.key}" }
  })
}

resource "aws_dynamodb_table_item" "product_3" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    id    = { N = "3" }
    title = { S = "Third product" }
    path  = { S = "https://${aws_s3_bucket.product_assets.bucket}.s3.${var.aws_region}.amazonaws.com/${aws_s3_object.product_3_image.key}" }
  })
}

resource "aws_dynamodb_table_item" "product_4" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    id    = { N = "4" }
    title = { S = "Fourth product" }
    path  = { S = "https://${aws_s3_bucket.product_assets.bucket}.s3.${var.aws_region}.amazonaws.com/${aws_s3_object.product_4_image.key}" }
  })
}

resource "aws_dynamodb_table_item" "product_5" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    id    = { N = "5" }
    title = { S = "Fifth product" }
    path  = { S = "https://${aws_s3_bucket.product_assets.bucket}.s3.${var.aws_region}.amazonaws.com/${aws_s3_object.product_5_image.key}" }
  })
}

resource "aws_dynamodb_table_item" "product_6" {
  table_name = aws_dynamodb_table.products.name
  hash_key   = aws_dynamodb_table.products.hash_key

  item = jsonencode({
    id    = { N = "6" }
    title = { S = "Sixth product" }
    path  = { S = "https://${aws_s3_bucket.product_assets.bucket}.s3.${var.aws_region}.amazonaws.com/${aws_s3_object.product_6_image.key}" }
  })
}

# 创建 CloudWatch Log Group。
# 因为 task definition 里要配置 container 的日志输出到哪个 CloudWatch Log Group：
# ECS container 的标准输出和错误日志会被发送到这里，方便排查启动和运行问题。
resource "aws_cloudwatch_log_group" "backend" {
  name              = var.backend_log_group_name
  retention_in_days = 7
}

# 创建 frontend 的 CloudWatch Log Group。
# 前端 Nginx container 的日志会写到这里。
resource "aws_cloudwatch_log_group" "frontend" {
  name              = var.frontend_log_group_name
  retention_in_days = 7
}

# 定义 ECS Task Definition。
# 它是 ECS 运行 container 的说明书：image、CPU/memory、端口、日志、IAM role 都在这里定义。
resource "aws_ecs_task_definition" "backend" {
  family                   = "demo-backend-task-tf"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  # CodeBuild 默认构建 linux/amd64 image，所以 Fargate task 也要使用 X86_64。
  # 如果以后明确用 docker buildx 构建 linux/arm64 image，再把这里改成 ARM64。
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = var.backend_container_name
      image     = "${aws_ecr_repository.backend.repository_url}:latest"
      essential = true

      environment = [
        {
          name  = "PRODUCTS_TABLE_NAME"
          value = aws_dynamodb_table.products.name
        },
        {
          name  = "INVENTORY_SERVICE_BASE_URL"
          value = "http://${var.inventory_service_discovery_name}.${aws_service_discovery_private_dns_namespace.demo.name}:${var.inventory_service_port}"
        },
        {
          name  = "USER_SERVICE_GRPC_TARGET"
          value = "${var.user_service_discovery_name}.${aws_service_discovery_private_dns_namespace.demo.name}:${var.user_grpc_port}"
        },
        {
          name  = "APP_ENV"
          value = "dev"
        },
        {
          name  = "AWS_REGION"
          value = var.aws_region
        },
        {
          name  = "CLOUDWATCH_METRICS_EXPORT_ENABLED"
          value = "true"
        },
        {
          name  = "CLOUDWATCH_METRICS_NAMESPACE"
          value = "Demo/ProductService"
        },
        {
          name  = "OTEL_SERVICE_NAME"
          value = "demo-backend"
        },
        {
          name  = "OTEL_RESOURCE_ATTRIBUTES"
          value = "service.namespace=demo,deployment.environment=dev"
        },
        {
          name  = "OTEL_EXPORTER_OTLP_ENDPOINT"
          value = "http://localhost:4317"
        },
        {
          name  = "OTEL_TRACES_EXPORTER"
          value = "otlp"
        },
        {
          name  = "OTEL_METRICS_EXPORTER"
          value = "none"
        },
        {
          name  = "OTEL_LOGS_EXPORTER"
          value = "none"
        },
        {
          name  = "OTEL_PROPAGATORS"
          value = "tracecontext,baggage,xray"
        },
        {
          name  = "OTEL_INSTRUMENTATION_LOGBACK_MDC_ENABLED"
          value = "true"
        }
      ]

      portMappings = [
        {
          containerPort = var.backend_container_port
          hostPort      = var.backend_container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    },
    {
      name      = "adot-collector"
      image     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
      essential = false
      command   = ["--config=env:AOT_CONFIG_CONTENT"]

      environment = [
        {
          name  = "AWS_REGION"
          value = var.aws_region
        },
        {
          name  = "AOT_CONFIG_CONTENT"
          value = <<-EOT
            receivers:
              otlp:
                protocols:
                  grpc:
                    endpoint: 0.0.0.0:4317
                  http:
                    endpoint: 0.0.0.0:4318
            processors:
              batch:
            exporters:
              awsxray:
            service:
              pipelines:
                traces:
                  receivers: [otlp]
                  processors: [batch]
                  exporters: [awsxray]
          EOT
        }
      ]

      portMappings = [
        {
          containerPort = 4317
          protocol      = "tcp"
        },
        {
          containerPort = 4318
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "adot"
        }
      }
    }
  ])
}

# 定义 frontend 的 ECS Task Definition。
# 这个 task 会运行前端 Nginx container，Nginx 负责返回静态页面并代理 /api 请求。
resource "aws_ecs_task_definition" "frontend" {
  family                   = "demo-frontend-task-tf"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = var.frontend_container_name
      image     = "${aws_ecr_repository.frontend.repository_url}:latest"
      essential = true

      environment = [
        {
          name  = "BACKEND_ALB_DNS_NAME"
          value = aws_lb.backend.dns_name
        }
      ]

      portMappings = [
        {
          containerPort = var.frontend_container_port
          hostPort      = var.frontend_container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.frontend.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

# 创建 ECS task 使用的 Security Group。
# Security Group 是 VPC 里的虚拟防火墙，控制谁可以访问 ECS task。
resource "aws_security_group" "backend_task" {
  name        = var.backend_security_group_name
  description = "Allow public access to the demo API ECS task on port 8080"
  vpc_id      = aws_vpc.main.id

  # 只允许 ALB 访问 Spring Boot 的 8080 端口。
  # 这样公网用户必须先访问 ALB，再由 ALB 转发到 ECS task，不能绕过 ALB 直连 task。
  ingress {
    description     = "Allow HTTP access from ALB to Spring Boot API"
    from_port       = var.backend_container_port
    to_port         = var.backend_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.backend_alb.id]
  }

  # 允许 ECS task 对外访问。
  # 这让 task 能访问 AWS APIs、下载依赖服务、未来访问 DynamoDB/S3 等。
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 创建 frontend ECS task 使用的 Security Group。
# 只允许 frontend ALB 访问 Nginx container 的 80 端口。
resource "aws_security_group" "frontend_task" {
  name        = "demo-frontend-ecs-task-sg-tf"
  description = "Allow frontend ALB access to the demo frontend ECS task on port 80"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow HTTP access from frontend ALB to Nginx"
    from_port       = var.frontend_container_port
    to_port         = var.frontend_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_alb.id]
  }

  # 允许 frontend task 对外访问。
  # 这样 Nginx 可以把 /api 请求代理到 backend ALB，也可以访问 AWS APIs。
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============================================================
# ALB 基础设施：公网入口和转发目标
# ============================================================

# 创建 backend internal ALB 使用的 Security Group。
# 后端 ALB 不对公网开放，只允许前端 Nginx task 访问。
resource "aws_security_group" "backend_alb" {
  name        = "demo-backend-alb-sg-tf"
  description = "Allow frontend ECS task access to the internal backend ALB"
  vpc_id      = aws_vpc.main.id

  # 后端 ALB 是 internal，只允许前端 Nginx task 通过 80 端口访问。
  ingress {
    description     = "Allow HTTP access from frontend task to backend ALB" # 这条入站规则的说明。
    from_port       = 80                                                    # 允许访问的起始端口，这里是 HTTP 80。
    to_port         = 80                                                    # 允许访问的结束端口；和 from_port 一样表示只开放 80。
    protocol        = "tcp"                                                 # 允许 TCP 流量，HTTP 基于 TCP。
    security_groups = [aws_security_group.frontend_task.id]                 # 只允许绑定了 frontend_task SG 的资源访问 backend ALB。
  }

  # 允许 ALB 对外转发流量。
  # 实际转发到 ECS task 时，会走 target group 和 ECS service 的绑定。
  egress {
    description = "Allow all outbound traffic" # 这条出站规则的说明。
    from_port   = 0                            # 出站起始端口；配合 protocol = "-1" 表示所有端口。
    to_port     = 0                            # 出站结束端口；配合 protocol = "-1" 表示所有端口。
    protocol    = "-1"                         # 允许所有协议出站。
    cidr_blocks = ["0.0.0.0/0"]                # 允许发往任意 IPv4 地址。
  }
}

# 创建 backend internal Application Load Balancer。
# 它只作为 VPC 内部入口，给 frontend Nginx 代理 /api 请求使用。
resource "aws_lb" "backend" {
  name               = "demo-backend-alb-tf"
  load_balancer_type = "application"
  internal           = true
  security_groups    = [aws_security_group.backend_alb.id]
  subnets            = aws_subnet.private[*].id
}

# 创建 ALB Target Group。
# Fargate 使用 awsvpc 网络模式，所以 target_type 必须是 ip。
resource "aws_lb_target_group" "backend" {
  name        = "demo-backend-tg-tf"       # Target Group 在 AWS 里的名字。
  port        = var.backend_container_port # ALB 转发到后端目标时使用的端口，这里是 backend container 端口。
  protocol    = "HTTP"                     # ALB 用 HTTP 协议转发请求到后端目标。
  target_type = "ip"                       # 目标类型是 IP；Fargate task 使用 awsvpc 网络模式，所以注册 task private IP。
  vpc_id      = aws_vpc.main.id            # Target Group 属于这个 VPC，只能注册同 VPC 内的目标。

  # ALB 会访问 /status 判断后端 task 是否健康。
  # 你的 Spring Boot StatusController 已经提供了这个接口。
  health_check {
    enabled             = true      # 开启健康检查。
    path                = "/status" # ALB 定期访问这个路径检查后端是否健康。
    matcher             = "200"     # 只有返回 HTTP 200 才算健康。
    interval            = 30        # 每 30 秒检查一次。
    timeout             = 5         # 单次健康检查 5 秒没响应就算超时。
    healthy_threshold   = 2         # 连续 2 次成功后，把目标标记为 healthy。
    unhealthy_threshold = 2         # 连续 2 次失败后，把目标标记为 unhealthy。
  }
}

# 创建 backend ALB Listener。
# 监听 VPC 内部 80 端口，并把请求转发到上面的 target group。
resource "aws_lb_listener" "backend_http" {
  load_balancer_arn = aws_lb.backend.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

# ============================================================
# Frontend ALB 基础设施：前端公网入口
# ============================================================

# 创建 frontend ALB 使用的 Security Group。
# 用户会通过这个 ALB 访问前端页面。
resource "aws_security_group" "frontend_alb" {
  name        = "demo-frontend-alb-sg-tf"
  description = "Allow public HTTP access to the demo frontend ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow public HTTP access to frontend ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 创建 frontend Application Load Balancer。
# 它是前端页面的公网入口，会转发到 private subnet 里的 Nginx Fargate task。
resource "aws_lb" "frontend" {
  name               = "demo-frontend-alb-tf"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.frontend_alb.id]
  subnets            = aws_subnet.public[*].id
}

# 创建 frontend Target Group。
# 前端 Fargate task 使用 awsvpc 网络模式，所以 target_type 也是 ip。
resource "aws_lb_target_group" "frontend" {
  name        = "demo-frontend-tg-tf"
  port        = var.frontend_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  # Nginx 首页 / 返回 200，就说明前端 container 是健康的。
  health_check {
    enabled             = true
    path                = "/"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# 创建 frontend ALB Listener。
# 监听公网 80 端口，并把请求转发到 frontend target group。
resource "aws_lb_listener" "frontend_http" {
  load_balancer_arn = aws_lb.frontend.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# 创建 Product Service 在 Cloud Map 里的服务名字。
# ECS Service 会把正在运行的 product task IP 注册到 product.demo.internal。
resource "aws_service_discovery_service" "product" {
  name = var.product_service_discovery_name

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.demo.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 创建 ECS Service，让 Task Definition 真正运行起来。
# Service 会保持 desired_count 个 task 长期运行；如果 task 挂了，ECS 会自动拉起新的。
resource "aws_ecs_service" "backend" {
  name            = "demo-backend-service-tf"           # ECS Service 在 AWS 里的名字。
  cluster         = aws_ecs_cluster.main.id             # 这个 service 运行在哪个 ECS cluster 里。
  task_definition = aws_ecs_task_definition.backend.arn # 使用哪个 backend task definition 来启动 task。
  desired_count   = 1                                   # 希望长期保持运行的 backend task 数量。
  launch_type     = "FARGATE"                           # 使用 Fargate，不需要自己管理 EC2 worker nodes。

  # 后端 Spring Boot 加载 AWS SDK 后启动会更久。
  # 给 ECS/ALB 一段宽限时间，避免 task 刚启动还没监听完成就被 health check 判失败。
  health_check_grace_period_seconds = 90 # task 启动后的 90 秒内暂时忽略 ALB 健康检查失败。

  # 把 product ECS task 注册到 Cloud Map。
  # 注册后，同一个 VPC 内的服务可以用 product.demo.internal 找到 product task。
  service_registries {
    registry_arn = aws_service_discovery_service.product.arn
  }

  # 把 ECS Service 注册到 ALB Target Group。
  # ECS 会自动把运行中的 Fargate task IP 加入 target group。
  # 这样 ALB listener 收到请求后，就能转发到 Spring Boot container 的 8080 端口。
  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn # 把 service 管理的 task 注册到这个 target group。
    container_name   = var.backend_container_name      # 注册 task 里的哪个 container。
    container_port   = var.backend_container_port      # 注册这个 container 的哪个端口。
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id             # backend task 放进这些 private subnets。
    security_groups  = [aws_security_group.backend_task.id] # backend task 绑定这个 security group。
    assign_public_ip = false                                # 不给 task 分配公网 IP，避免公网直连。
  }

  # CodePipeline 的 Deploy stage 会更新 ECS service 使用的新 task definition revision。
  # 如果 Terraform 继续强制管理 task_definition，下一次 apply 可能把 service 回滚到旧 revision。
  # 所以这里让 Terraform 忽略 task_definition 的漂移，把部署版本交给 CodePipeline 管。
  lifecycle {
    ignore_changes = [task_definition]
  }
}

# 创建 frontend ECS Service。
# Service 会长期保持 1 个 Nginx frontend task 运行，并注册到 frontend ALB target group。
resource "aws_ecs_service" "frontend" {
  depends_on = [aws_lb_listener.frontend_http]

  name            = "demo-frontend-service-tf"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = var.frontend_container_name
    container_port   = var.frontend_container_port
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.frontend_task.id]
    assign_public_ip = false
  }

  # CodePipeline 的 frontend Deploy stage 会更新 ECS service 使用的新 task definition revision。
  # 如果 Terraform 继续强制管理 task_definition，下一次 apply 可能把 frontend service 回滚到旧 revision。
  # 所以这里让 Terraform 忽略 task_definition 的漂移，把部署版本交给 CodePipeline 管。
  lifecycle {
    ignore_changes = [task_definition]
  }
}

# ============================================================
# ECS Service Auto Scaling：自动调整 Fargate task 数量
# ============================================================

# 定义 ECS Service 的可扩缩容范围。
# 这里表示 demo-backend-service-tf 最少保持 1 个 task，最多可以扩到 3 个 task。
resource "aws_appautoscaling_target" "backend" {
  max_capacity       = 3                                                                      # 最多自动扩到 3 个 backend task。
  min_capacity       = 1                                                                      # 最少保持 1 个 backend task。
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.backend.name}" # 指定要扩缩容的 ECS service。
  scalable_dimension = "ecs:service:DesiredCount"                                             # 扩缩容调整的是 ECS service 的 desired_count。
  service_namespace  = "ecs"                                                                  # 这个 scalable target 属于 ECS 服务命名空间。
}

# 定义 CPU 自动扩缩容策略。
# AWS 会观察 ECS Service 的平均 CPU 使用率，并自动调整 desired_count。
# 当平均 CPU 高于 50% 时倾向于扩容，低于目标值一段时间后会缩容。
resource "aws_appautoscaling_policy" "backend_cpu" {
  name               = "demo-backend-cpu-autoscaling-tf"                    # Auto Scaling policy 的名字。
  policy_type        = "TargetTrackingScaling"                              # 使用目标追踪策略，让 AWS 自动维持指标接近目标值。
  resource_id        = aws_appautoscaling_target.backend.resource_id        # 复用上面 target 指定的 ECS service。
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension # 复用上面 target 的可扩缩维度 desired_count。
  service_namespace  = aws_appautoscaling_target.backend.service_namespace  # 复用上面 target 的 ECS 命名空间。

  target_tracking_scaling_policy_configuration {
    target_value = 50 # 目标 CPU 使用率是 50%。

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization" # 使用 ECS Service 平均 CPU 利用率作为扩缩容指标。
    }
  }
}
