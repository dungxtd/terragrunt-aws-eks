# Terragrunt AWS Environment

## Requirements
- Terraform ≥ 1.6
- Terragrunt (tested with 0.89.3)
- Set environment variables:
  ```
  export ENVIRONMENT_NAME=development
  export AWS_PROFILE=your-profile
  aws sso login --profile $AWS_PROFILE
  ```

## Daily workflow
From `environments/${ENVIRONMENT_NAME}`:
```
terragrunt init  --all --queue-include-external
terragrunt plan  --all --non-interactive --queue-include-external
terragrunt apply --all --auto-approve --non-interactive --queue-include-external
```

For older Terragrunt builds that lack `--all`, use:
```
terragrunt --queue-include-external run-all init
terragrunt --queue-include-external --non-interactive run-all plan
terragrunt --queue-include-external --auto-approve --non-interactive run-all apply
```

## ECS Notes
- `tg-modules/ecs` reads the `ecs` block in each environment to create clusters, services, task definitions, and shared ALBs.
- Shared listeners (e.g. `/comment*`, `/stream*`) work by declaring the ALB under `load-balancers` and referencing it in each service `load-balancer-config`.
- Outputs `ecs_clusters`, `ecs_services`, and `ecs_load_balancers` complement the existing EKS exports.

## EKS Notes
- All EKS modules remain in place (`tg-modules/eks`, `eks-lb`, `eks-helm-bootstrap`, etc.) so you can run Kubernetes and ECS side by side.
- Helm chart bootstrap still reads from the `eks` section in each environment and relies on the outputs produced by the ECS/Terragrunt stack.

## Targeting a single module
```
export ENVIRONMENT_NAME=development
cd tg-modules/route53
terragrunt init -reconfigure --non-interactive
terragrunt plan  --non-interactive
```

## Destroy
```
terragrunt destroy --all --non-interactive --queue-include-external
```
Clean any debug artefacts afterwards:
```
rm -f tg-modules/*/terraform.tfvars.json tg-modules/*/terragrunt-debug.tfvars.json
```

## Kubeconfig helper
```
export AWS_REGION=ap-southeast-1
aws eks list-clusters --region "${AWS_REGION}"
export CLUSTER_NAME=dev-example-com-cluster
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${CLUSTER_NAME}" \
  --kubeconfig ~/.kube/${CLUSTER_NAME}-${AWS_REGION}.yaml
```
