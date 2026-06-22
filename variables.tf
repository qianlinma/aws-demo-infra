variable "aws_region" {
  # Terraform 要在哪个 AWS region 创建资源，例如 us-west-2。
  description = "AWS region where resources will be created."
  type        = string
}

variable "aws_profile" {
  # 使用本机 ~/.aws 配置中的哪个 profile。
  description = "Local AWS CLI profile used by Terraform."
  type        = string
}

variable "github_connection_arn" {
  # 这个 ARN 来自 AWS Console 里已经 Available 的 aws-demo GitHub connection。
  # backend/frontend pipeline 会共用这一条 connection 去读取不同 GitHub repo。
  description = "Existing AWS CodeConnections ARN for the GitHub aws-demo connection."
  type        = string
  default     = "arn:aws:codeconnections:us-west-2:123316866274:connection/fc97dced-1e43-4b55-aac0-9565058ba8c3"
}

variable "backend_ecr_repository_name" {
  # ECR repository 用来存放 backend 的 Docker image。
  # 这里不用 demo-backend，是为了避免和你手动创建的 ECR repo 冲突。
  description = "Name of the ECR repository for the backend image."
  type        = string
}

variable "frontend_ecr_repository_name" {
  # ECR repository 用来存放前端 Nginx frontend 的 Docker image。
  # 后面前端 ECS Task Definition 会引用这个 repository 里的 image URI。
  description = "Name of the ECR repository for the frontend image."
  type        = string
}

variable "ecs_cluster_name" {
  # ECS cluster 是 ECS service/task 的逻辑工作区。
  # 后面 Task Definition 和 ECS Service 会放到这个 cluster 里运行。
  description = "Name of the ECS cluster for the demo application."
  type        = string
}

variable "ecs_task_execution_role_name" {
  # ECS Task Execution Role 给 ECS/Fargate 平台使用。
  # 它允许 ECS 拉取 ECR image，并把 container logs 写到 CloudWatch Logs。
  description = "Name of the ECS task execution IAM role."
  type        = string
}

variable "ecs_task_role_name" {
  # ECS Task Role 给 container 里的应用代码使用。
  # 后端 Spring Boot 未来会通过这个 role 读取 DynamoDB / S3。
  description = "Name of the ECS task IAM role used by application code."
  type        = string
}

variable "products_table_name" {
  # DynamoDB table 用来保存产品数据。
  # 后端 /api/getAllProducts 未来会从这张表读取数据。
  description = "Name of the DynamoDB table for demo products."
  type        = string
}

variable "backend_log_group_name" {
  # CloudWatch Log Group 用来保存 backend container 的日志。
  # 后面 ECS Task Definition 会把 container stdout/stderr 发送到这里。
  description = "CloudWatch Log Group name for the backend container logs."
  type        = string
}

variable "frontend_log_group_name" {
  # CloudWatch Log Group 用来保存 frontend container 的日志。
  # Nginx 的访问日志和错误日志会被发送到这里。
  description = "CloudWatch Log Group name for the frontend container logs."
  type        = string
}

variable "backend_container_name" {
  # ECS Task Definition 里的 container 名字。
  # 后面 ECS Service 绑定 load balancer 或 target group 时也会引用这个名字。
  description = "Name of the backend container."
  type        = string
}

variable "backend_container_port" {
  # Spring Boot 默认监听 8080，所以 container port 也配置为 8080。
  description = "Port exposed by the backend container."
  type        = number
}

variable "frontend_container_name" {
  # 前端 ECS Task Definition 里的 container 名字。
  # 后面 ECS Service 绑定 frontend target group 时会引用这个名字。
  description = "Name of the frontend container."
  type        = string
}

variable "frontend_container_port" {
  # Nginx 默认监听 80，所以 frontend container port 配置为 80。
  description = "Port exposed by the frontend container."
  type        = number
}

variable "backend_security_group_name" {
  # ECS task 的 security group 名字。
  # 现在 ECS task 只允许 ALB security group 访问 8080。
  description = "Name of the security group for the backend ECS task."
  type        = string
}

variable "vpc_cidr_block" {
  # 应用 VPC 的 CIDR 范围。
  # Public/private subnets 都会从这个范围里切出来。
  description = "CIDR block for the application VPC."
  type        = string
}

variable "public_subnet_cidr_blocks" {
  # Public subnets 给 public ALB 和 NAT Gateway 使用。
  description = "CIDR blocks for public subnets used by public ALB and NAT Gateway."
  type        = list(string)
}

variable "private_subnet_cidr_blocks" {
  # Private subnets 给 ECS task 和 backend internal ALB 使用。
  description = "CIDR blocks for private subnets used by ECS Fargate tasks and internal ALB."
  type        = list(string)
}
