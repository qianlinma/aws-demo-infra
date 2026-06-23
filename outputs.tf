output "backend_ecr_repository_url" {
  # 输出 ECR repository URL。
  # 后面 docker tag / docker push 以及 ECS Task Definition 都会用到它。
  description = "Repository URL used to tag and push the backend image."
  value       = aws_ecr_repository.backend.repository_url
}

output "backend_ecr_repository_arn" {
  # 输出 ECR repository ARN。
  # 后面如果写 IAM policy，可能会用 ARN 来授权访问这个 repository。
  description = "ARN of the backend ECR repository."
  value       = aws_ecr_repository.backend.arn
}

output "frontend_ecr_repository_url" {
  # 输出前端 ECR repository URL。
  # 后面 docker tag / docker push 前端 image 时会用到它。
  description = "Repository URL used to tag and push the frontend image."
  value       = aws_ecr_repository.frontend.repository_url
}

output "frontend_ecr_repository_arn" {
  # 输出前端 ECR repository ARN。
  # 后面如果写 IAM policy，可能会用 ARN 来授权访问这个 repository。
  description = "ARN of the frontend ECR repository."
  value       = aws_ecr_repository.frontend.arn
}

output "ecs_cluster_name" {
  # 输出 ECS cluster 名字。
  # 后面创建 ECS Service 或调试 AWS Console 时会用到。
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  # 输出 ECS cluster ARN。
  # ARN 是 AWS 资源的唯一标识，后面 IAM 或跨资源引用时可能会用到。
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.main.arn
}

output "ecs_task_execution_role_arn" {
  # 输出 ECS Task Execution Role ARN。
  # 后面 ECS Task Definition 会用它作为 execution_role_arn。
  description = "ARN of the ECS task execution role."
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_arn" {
  # 输出 ECS Task Role ARN。
  # 后端 Spring Boot 运行时会用这个 role 访问 DynamoDB / S3。
  description = "ARN of the ECS task role used by application code."
  value       = aws_iam_role.ecs_task.arn
}

output "products_table_name" {
  # 输出 DynamoDB 产品表名字。
  # 后端 container 会通过 PRODUCTS_TABLE_NAME 环境变量拿到同一个名字。
  description = "Name of the DynamoDB table for demo products."
  value       = aws_dynamodb_table.products.name
}

output "products_table_arn" {
  # 输出 DynamoDB 产品表 ARN。
  # IAM policy 授权访问这张表时会引用这个 ARN。
  description = "ARN of the DynamoDB table for demo products."
  value       = aws_dynamodb_table.products.arn
}

output "product_assets_bucket_name" {
  # 输出 S3 产品图片 bucket 名字。
  # 6 张 demo 产品图片会上传到这个 bucket 的 product-images/ 目录。
  description = "Name of the S3 bucket for demo product images."
  value       = aws_s3_bucket.product_assets.bucket
}

output "product_assets_bucket_arn" {
  # 输出 S3 产品图片 bucket ARN。
  # 后面如果给应用加 S3 读写权限，会用到这个 ARN。
  description = "ARN of the S3 bucket for demo product images."
  value       = aws_s3_bucket.product_assets.arn
}

output "backend_log_group_name" {
  # 输出 backend log group 名字。
  # 后面 Task Definition 的 logConfiguration 会引用这个名字。
  description = "CloudWatch Log Group name for the backend logs."
  value       = aws_cloudwatch_log_group.backend.name
}

output "frontend_log_group_name" {
  # 输出 frontend log group 名字。
  # 前端 Nginx container 的日志会写到这里。
  description = "CloudWatch Log Group name for the frontend logs."
  value       = aws_cloudwatch_log_group.frontend.name
}

output "backend_task_definition_arn" {
  # 输出 ECS Task Definition ARN。
  # 后面 ECS Service 会用这个 task definition 启动 backend task。
  description = "ARN of the backend ECS task definition."
  value       = aws_ecs_task_definition.backend.arn
}

output "frontend_task_definition_arn" {
  # 输出 frontend ECS Task Definition ARN。
  # 后面 ECS Service 会用这个 task definition 启动 frontend Nginx task。
  description = "ARN of the frontend ECS task definition."
  value       = aws_ecs_task_definition.frontend.arn
}

output "backend_task_security_group_id" {
  # 输出 ECS task security group id。
  # 后面 ECS Service 的 network_configuration 会引用它。
  description = "Security group ID for the backend ECS task."
  value       = aws_security_group.backend_task.id
}

output "frontend_task_security_group_id" {
  # 输出 frontend ECS task security group id。
  # 前端 task 只允许 frontend ALB 访问 80 端口。
  description = "Security group ID for the frontend ECS task."
  value       = aws_security_group.frontend_task.id
}

output "vpc_id" {
  # 输出应用 VPC id。
  description = "ID of the application VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  # 输出 public subnet ids。
  # Frontend public ALB 和 NAT Gateway 会使用这些 subnets。
  description = "Public subnet IDs used by the public ALB and NAT Gateway."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  # 输出 ECS task 使用的 private subnet ids。
  # 这些 subnets 不给 task 分配公网 IP，task 通过 NAT Gateway 出网。
  description = "Private subnet IDs used by ECS tasks and internal backend ALB."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  # 输出 NAT Gateway id。
  # Private subnet 里的 ECS task 会通过它访问 ECR、CloudWatch Logs 等服务。
  description = "NAT Gateway ID used for outbound traffic from private ECS tasks."
  value       = aws_nat_gateway.nat.id
}

output "backend_alb_dns_name" {
  # 输出 backend internal ALB 的 DNS name。
  # 它只给 VPC 内部的 frontend Nginx task 代理 /api 请求使用。
  description = "Internal DNS name of the backend Application Load Balancer."
  value       = aws_lb.backend.dns_name
}

output "backend_alb_target_group_arn" {
  # 输出 ALB target group ARN。
  # 下一步把 ECS Service 绑定到 ALB 时会用到它。
  description = "ARN of the backend ALB target group."
  value       = aws_lb_target_group.backend.arn
}

output "frontend_alb_dns_name" {
  # 输出 frontend ALB 的公网 DNS name。
  # Terraform apply 后，可以用 http://这个地址 访问前端页面。
  description = "Public DNS name of the frontend Application Load Balancer."
  value       = aws_lb.frontend.dns_name
}

output "frontend_alb_target_group_arn" {
  # 输出 frontend ALB target group ARN。
  # ECS Service 会把 frontend task 注册到这个 target group。
  description = "ARN of the frontend ALB target group."
  value       = aws_lb_target_group.frontend.arn
}

output "backend_ecs_service_name" {
  # 输出 ECS Service 名字。
  # Service 会负责维持 backend task 持续运行。
  description = "Name of the backend ECS service."
  value       = aws_ecs_service.backend.name
}

output "frontend_ecs_service_name" {
  # 输出 frontend ECS Service 名字。
  # Service 会负责维持 frontend Nginx task 持续运行。
  description = "Name of the frontend ECS service."
  value       = aws_ecs_service.frontend.name
}

output "service_discovery_namespace_name" {
  description = "Cloud Map private DNS namespace used by demo microservices."
  value       = aws_service_discovery_private_dns_namespace.demo.name
}

output "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace ID."
  value       = aws_service_discovery_private_dns_namespace.demo.id
}

output "inventory_service_base_url" {
  description = "Base URL product service uses to call inventory service through Cloud Map."
  value       = "http://${var.inventory_service_discovery_name}.${aws_service_discovery_private_dns_namespace.demo.name}:${var.inventory_service_port}"
}

output "product_service_discovery_dns_name" {
  description = "Private DNS name other backend services can use to call the product service."
  value       = "${var.product_service_discovery_name}.${aws_service_discovery_private_dns_namespace.demo.name}"
}
