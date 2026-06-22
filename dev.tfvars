aws_region  = "us-west-2"
aws_profile = "dev"

backend_ecr_repository_name  = "demo-backend-tf"
frontend_ecr_repository_name = "demo-frontend-tf"

ecs_cluster_name             = "demo-cluster-tf"
ecs_task_execution_role_name = "demo-ecs-task-execution-role-tf"
ecs_task_role_name           = "demo-ecs-task-role-tf"

products_table_name = "demo-products-tf"

backend_log_group_name  = "/ecs/demo-backend-tf"
frontend_log_group_name = "/ecs/demo-frontend-tf"

backend_container_name  = "demo-backend"
backend_container_port  = 8080
frontend_container_name = "demo-frontend"
frontend_container_port = 80

backend_security_group_name = "demo-backend-ecs-task-sg-tf"

vpc_cidr_block = "10.0.0.0/16"

public_subnet_cidr_blocks = [
  "10.0.0.0/24",
  "10.0.1.0/24"
]

private_subnet_cidr_blocks = [
  "10.0.10.0/24",
  "10.0.11.0/24"
]
