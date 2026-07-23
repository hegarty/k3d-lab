# Migration to EKS

This document maps local k3d-lab components to their AWS EKS equivalents, enabling a smooth path from local development to production.

## Component Mapping

| k3d-lab Component | EKS Equivalent | Notes |
|-------------------|----------------|-------|
| k3d (cluster mgmt) | `eksctl` / Terraform + `aws_eks_cluster` | EKS manages control plane |
| k3s (Kubernetes) | EKS managed Kubernetes | Same API, same manifests work |
| Cilium CNI | Cilium on EKS (managed node groups) or VPC CNI | Cilium is supported on EKS |
| Flannel | VPC CNI (default) | Replace if using Cilium on EKS |
| Gateway API | AWS Load Balancer Controller + Gateway API | Or keep Cilium |
| MetalLB | AWS Load Balancer (NLB/ALB) | Automatic with `type: LoadBalancer` |
| Istio | Istio on EKS or AWS App Mesh | Same Helm chart works |
| kube-prometheus-stack | Amazon Managed Prometheus + Grafana | Or self-hosted on EKS |
| Loki | Amazon Managed Grafana (Loki) or self-hosted | Use S3 backend |
| Tempo | AWS X-Ray or self-hosted Tempo with S3 | |
| OTel Collector | AWS Distro for OpenTelemetry (ADOT) | Compatible with OTel standard |
| cert-manager | AWS Certificate Manager (ACM) + cert-manager | cert-manager supports ACM DNS01 |
| Kyverno | Kyverno on EKS | Same policies work unchanged |
| External Secrets | External Secrets + AWS SSM/SecretsManager | Change secret store backend |
| local-path StorageClass | Amazon EBS gp3 StorageClass | EKS CSI driver |
| Container registry (local) | Amazon ECR | Change image references |

## Cilium on EKS

If you want to run the same Cilium configuration on EKS:

```bash
# Install Cilium on EKS (managed node groups with custom networking)
eksctl create cluster --config-file=eks-cluster.yaml

# Disable VPC CNI
kubectl delete daemonset aws-node -n kube-system

# Install Cilium
helm install cilium cilium/cilium \
  --version 1.15.6 \
  --namespace kube-system \
  --set eni.enabled=true \
  --set ipam.mode=eni \
  --set egressMasqueradeInterfaces=eth0 \
  --set tunnel=disabled \
  --set nodeinit.enabled=true
```

## Storage Migration

### Local → EBS

```bash
# Install EBS CSI driver
eksctl create addon --name aws-ebs-csi-driver --cluster my-cluster

# Create gp3 StorageClass
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Retain
EOF
```

Update Helm values to use `ebs-gp3` instead of `local-path`.

## Observability Migration

### Self-hosted → Amazon Managed

```bash
# Amazon Managed Prometheus (AMP)
aws amp create-workspace --alias k3d-lab-prod

# Configure OTel Collector to export to AMP
# Replace prometheusremotewrite endpoint with AMP endpoint
# Update IRSA for authentication
```

### Loki → S3 backend

```yaml
# observability/loki/values-eks.yaml
loki:
  storage:
    type: s3
    s3:
      bucketnames: my-loki-chunks
      region: us-east-1
      s3ForcePathStyle: false
      insecure: false
  # Use IRSA for authentication (no credentials needed)
```

### Tempo → S3 backend

```yaml
# observability/tempo/values-eks.yaml
tempo:
  storage:
    trace:
      backend: s3
      s3:
        bucket: my-tempo-traces
        region: us-east-1
```

## External Secrets Migration

### Fake store → AWS SSM Parameter Store

```yaml
# Replace fake-store.yaml with:
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-ssm
spec:
  provider:
    aws:
      service: ParameterStore
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
```

### IRSA Setup

```bash
# Create IRSA role for External Secrets
eksctl create iamserviceaccount \
  --name external-secrets-sa \
  --namespace external-secrets \
  --cluster my-cluster \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess \
  --approve
```

## Certificate Management Migration

### Self-signed → ACM

```yaml
# cert-manager with Route53 DNS01 (for ACM-issued certs)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: your@email.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - dns01:
          route53:
            region: us-east-1
            hostedZoneID: YOUR_ZONE_ID
```

## NetworkPolicy Migration

Cilium policies (CiliumNetworkPolicy) work the same way on EKS with Cilium. Standard Kubernetes NetworkPolicy works on any EKS CNI.

For EKS without Cilium, replace CiliumClusterWideNetworkPolicy with standard NetworkPolicy resources.

## Container Image Registry Migration

```bash
# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789012.dkr.ecr.us-east-1.amazonaws.com

# Tag and push
docker tag myapp:v1.0 123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:v1.0
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:v1.0
```

Update deployment image references:
```yaml
# Before (local)
image: market-registry.localhost:5000/myapp:v1.0

# After (EKS)
image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:v1.0
```

## Checklist: local → EKS

- [ ] Replace local-path StorageClass with EBS gp3
- [ ] Replace MetalLB with AWS Load Balancer Controller
- [ ] Configure Cilium for ENI IPAM (if using Cilium on EKS)
- [ ] Replace local registry with ECR, update all image references
- [ ] Replace fake ClusterSecretStore with AWS SSM/SecretsManager
- [ ] Configure cert-manager with Route53 DNS01 or switch to ACM
- [ ] Configure Loki/Tempo for S3 storage backends
- [ ] Configure OTel Collector to use IRSA for AMP authentication
- [ ] Review Kyverno policies for EKS-specific node labels
- [ ] Update all LoadBalancer service annotations for NLB/ALB
- [ ] Configure IRSA for all service accounts that access AWS APIs
- [ ] Review security groups alongside Cilium network policies
