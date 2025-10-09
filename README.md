# How to deploy new environments

* Set the environment to use:
```
export ENVIRONMENT_NAME=production # must match any folder in ./environments
export AWS_PROFILE=xxx             # must match a profile in ~/.aws/config
```
* Copy the template environment (or any other) `./environments/dev-example-com` to `./environments/${ENVIRONMENT_NAME}`:
```
cp -a environments/dev-example-com environments/${ENVIRONMENT_NAME}
```
* Customize the variables in `./environments/${ENVIRONMENT_NAME}/config.yaml`. By the moment, the only available doc for it is in the form of comments within this file.
* Login to the AWS account if needed:
```
aws sso login --profile $AWS_PROFILE
```
- Ensure the required CLIs are installed and on your `$PATH`:
  * Terraform `>= 1.6` (e.g. `brew install terraform` or download from releases.hashicorp.com)
  * Terragrunt `>= 0.67` (e.g. `brew install terragrunt` or grab the latest binary from releases). If you must stay on an older Terragrunt, use the legacy `terragrunt run-all …` syntax and place Terragrunt flags *before* the command (see note below).
- Run Terragrunt from the corresponding environment folder. It will create the tfstate backend services out of the box (S3/DynamoDB):
```
cd environments/${ENVIRONMENT_NAME}

terragrunt init --all --terragrunt-include-external-dependencies

terragrunt plan --all \
  --terragrunt-include-external-dependencies \
  --terragrunt-non-interactive
```
* Eventually, apply the plan:
```
terragrunt apply --all \
  --terragrunt-include-external-dependencies
```

> **Note for legacy Terragrunt (< 0.52)**  
> Those versions don't understand the `--all` flag and will forward Terragrunt options to Terraform. In that case use the older syntax instead:
> ```
> terragrunt --terragrunt-include-external-dependencies run-all init
> terragrunt --terragrunt-include-external-dependencies --terragrunt-non-interactive run-all plan
> terragrunt --terragrunt-include-external-dependencies run-all apply
> ```
> Flags belong *before* the command when using `run-all`.

# ECS deployments

- `tg-modules/ecs` provisions ECS clusters, services, and dedicated load balancers from the new `ecs` block in each environment `config.yaml`.
- Container/task definitions are supplied through `task.containers` maps, which mirror the Oryx configuration that was previously delivered through the EKS Helm chart. You can override images, env vars, ports, and logging per service.
- `load-balancer-config` supports either network or application load balancers. Each listener maps to a specific container/port pair and reuses the same exposed port definitions that were defined for EKS.
- Shared ALBs are supported: declare them once under `ecs.regions[*].load-balancers`, then point multiple services at the same listener while adding path-based rules (e.g., `/comment*`, `/stream*`) directly in the service `load-balancer-config`.
- Terragrunt now exposes `ecs_clusters`, `ecs_services`, and `ecs_load_balancers` alongside the existing EKS outputs so downstream modules (or automation) can target either orchestrator without code changes.
- The original EKS modules remain available; you can run both orchestrators in parallel while you migrate workloads.

# Switching between environments

Everything you need to do is to run a terraform reconfigure before being able to plan/apply a different environment:
```
cd environments/${ENVIRONMENT_NAME}
terragrunt init --all \
  --terragrunt-include-external-dependencies \
  --terragrunt-non-interactive
```

# Applying only specific modules

This terragrunt projects maintains separate, smaller, tfstates for each module that makes targeting resources quicker. Imagine you'd only want to plan/apply changes of an specific module like `route53`, for that you'd just set the `$ENVIRONMENT_NAME` you want to target and you'd go into the module directory and execute the plan, ie:

```
export ENVIRONMENT_NAME=whatever
cd tg-modules/route53
terragrunt init -reconfigure --terragrunt-non-interactive # Important if you've used any other environment before
terragrunt plan --terragrunt-non-interactive
```

Optionally you can also target specific resources for the module just like you'd do with plain terraform by adding `-target=resource_type.resource_name`.

# Destroying everything

Given that our `tg-modules` generate JSON outputs that are passed as inputs to other modules, it can be tricky to destroy all the resources if there is some problem while destroying the modules altogether. For example, it might be the case that the `eks-alb` module failed to deregister some target group and when you retry to destroy it, the `eks` module itself is already destroyed so there is no input JSON to pass to `eks-alb` anymore.

Since at this point where we want to destroy everything we don't care about inconsistencies on the plan, we can workaround the problem described below by saving the JSON I/Os with `terragrunt` and providing them so the destroy command won't complain. This can be accomplished by following the next steps:

* Executing a `terragrunt run-all plan` like this:
```
terragrunt plan --all \
  --terragrunt-include-external-dependencies \
  --terragrunt-non-interactive \
  --terragrunt-debug
```
* Copying the most complete (the one including more input jsons, which is the `eks-alb` one) vars file to every `tg-module` so it's picked as an input tfvars file:
```
for tgm in tg-modules/*
do
    jq 'with_entries(.value |= tostring )' tg-modules/eks-alb/terragrunt-debug.tfvars.json > $tgm/terraform.tfvars.json
done
```
* Executing the destroy-all command from the `environment/$ENV` dir or executing them from each tg-module dir independently (recommended):
  * run-all:
```
terragrunt destroy --all \
  --terragrunt-include-external-dependencies \
  --terragrunt-non-interactive
```
  * run for each:
```
for tgm in tg-modules/*; do cd "$tgm"; terragrunt destroy --terragrunt-non-interactive -auto-approve; cd -; done
```
* And last but not least, cleaning up the folders with: 
```
rm -f tg-modules/*/terraform.tfvars.json tg-modules/*/terragrunt-debug.tfvars.json
```

# Misc ops

## Get kubeconfig for specific cluster

```
export AWS_REGION=ap-southeast-1
aws eks list-clusters --region ${AWS_REGION}
# set cluster name from list above
export CLUSTER_NAME=dev-example-com-cluster
aws eks update-kubeconfig \
  --region ${AWS_REGION} \
  --name ${CLUSTER_NAME} \
  --kubeconfig ~/.kube/${CLUSTER_NAME}-${AWS_REGION}.yaml
```
