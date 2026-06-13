module "eks" {
  source = "./modules/eks"

  vpc_id                 = module.network.vpc_id
  private_app_subnet_ids = module.network.private_app_subnet_ids
}
