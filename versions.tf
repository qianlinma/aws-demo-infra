terraform {
  # 约束 Terraform CLI 的最低版本，避免太旧的 Terraform 不能识别当前语法。
  required_version = ">= 1.6.0"

  # 声明本项目需要使用哪些 provider。
  # 这里的 aws provider 是 Terraform 操作 AWS 资源的插件。
  required_providers {
    aws = {
      # hashicorp/aws 是官方 AWS Provider 的来源地址。
      source = "hashicorp/aws"
      # 使用 5.x 版本的 AWS Provider，允许自动升级 patch/minor 版本。
      version = "~> 5.0"
    }
  }
}
