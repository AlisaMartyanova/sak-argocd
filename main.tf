data "aws_region" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

resource "kubernetes_namespace" "this" {
  count = var.namespace == "" ? 1 : 0
  metadata {
    name = var.namespace_name
  }
}

resource "kubernetes_secret" "sync_repo_secret" {

  depends_on = [kubernetes_namespace.this]

  metadata {
    name      = local.sync_repo_credentials_secret_name
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/name" : local.sync_repo_credentials_secret_name
      "app.kubernetes.io/part-of" : "argocd"
    }
  }


  data = {
    "username"      = var.https_username
    "password"      = var.https_password
    "sshPrivateKey" = var.ssh_private_key
  }

  type = "kubernetes.io/basic-auth"
}

resource "helm_release" "this" {
  name          = local.name
  repository    = local.repository
  chart         = local.chart
  version       = var.chart_version
  namespace     = local.namespace
  recreate_pods = true
  timeout       = 1200

  lifecycle {
    ignore_changes = [set, version]
  }

  dynamic "set" {
    for_each = merge(local.enabled ? merge(local.init_conf, local.conf) : local.legacy_defaults, var.conf)
    content {
      name  = set.key
      value = set.value
    }
  }
}

module "iam_assumable_role_admin" {
  source                        = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                       = "4.6.0"
  create_role                   = true
  role_name                     = "${var.cluster_name}_argocd"
  provider_url                  = replace(data.aws_eks_cluster.this.identity.0.oidc.0.issuer, "https://", "")
  role_policy_arns              = [aws_iam_policy.this.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:${local.namespace}:argocd-repo-server"]
  tags                          = var.tags
}

resource "aws_iam_policy" "this" {
  name_prefix = "argocd"
  description = "EKS ArgoCD policy for cluster ${data.aws_eks_cluster.this.id}"
  policy      = data.aws_iam_policy_document.this.json
}

data "aws_iam_policy_document" "this" {
  statement {
    sid    = "ArgoCDOwn"
    effect = "Allow"

    actions = [
      "kms:Decrypt"
    ]

    resources = [aws_kms_key.this.arn]
  }
}

resource "kubernetes_config_map" "decryptor" {
  metadata {
    name      = "argocd-decryptor"
    namespace = local.namespace
  }

  data = {
    decryptor = <<EOT
#! /usr/bin/env python3

import glob
import os

def decrypt(string):
  import boto3
  import base64
  client = boto3.client('kms')
  meta = client.decrypt(CiphertextBlob=bytes(base64.b64decode("%s==" % string)),KeyId="${aws_kms_key.this.arn}")
  plaintext = meta[u'Plaintext']
  return plaintext.decode()

for file in glob.glob('./*.y*ml'):
  print("\n---")
  with open(file) as f:
    for line in f:
      if line.find("KMS_ENC:") > 0:
        encrypted = line.split("KMS_ENC")[1].split(":")[1]
        decrypted = decrypt(encrypted)
        line = line.replace("KMS_ENC:%s:" % encrypted, decrypted)
      print(line,end = '')
    EOT
  }
}

resource "local_file" "this" {
  count    = local.enabled ? 1 : 0
  content  = yamlencode(local.application)
  filename = "${path.root}/${var.apps_dir}/${local.name}.yaml"
}

resource "random_password" "this" {
  length           = 20
  special          = true
  override_special = "_%@$"
}

resource "aws_ssm_parameter" "this" {
  name        = "/${var.cluster_name}/argocd/password"
  type        = "SecureString"
  value       = random_password.this.result
  description = "A password for accessing ArgoCD installation in ${var.cluster_name} EKS cluster"

  lifecycle {
    ignore_changes = [value]
  }

  tags = var.tags
}

resource "aws_ssm_parameter" "encrypted" {
  name        = "/${var.cluster_name}/argocd/password/encrypted"
  type        = "SecureString"
  value       = bcrypt(random_password.this.result, 10)
  description = "An encrypted password for accessing ArgoCD installation in ${var.cluster_name} EKS cluster"

  lifecycle {
    ignore_changes = [value]
  }

  tags = var.tags
}

resource "aws_kms_key" "this" {
  description = "ArgoCD key"
  is_enabled  = true

  tags = var.tags
}

resource "aws_kms_ciphertext" "client_secret" {
  count     = lookup(var.oidc, "secret", null) == null ? 0 : 1
  key_id    = aws_kms_key.this.key_id
  plaintext = lookup(var.oidc, "secret", null)
}

locals {
  enabled   = var.branch != "" && var.owner != "" && var.repository != ""
  namespace = coalescelist(kubernetes_namespace.this, [{ "metadata" = [{ "name" = var.namespace }] }])[0].metadata[0].name
  # TODO: cleanup
  legacy_defaults = merge({
    "installCRDs"            = false
    "server.ingress.enabled" = length(var.domains) > 0 ? true : false
    "server.config.url"      = length(var.domains) > 0 ? "https://argocd.${var.domains[0]}" : ""
    },
    { for i, domain in tolist(var.domains) : "server.ingress.tls[${i}].hosts[0]" => "argo-cd.${domain}" },
    { for i, domain in tolist(var.domains) : "server.ingress.hosts[${i}]" => "argo-cd.${domain}" },
    { for i, domain in tolist(var.domains) : "server.ingress.tls[${i}].secretName" => "argo-cd-${domain}-tls" }
  )
  repo_url                          = "${var.vcs}/${var.owner}/${var.repository}"
  sync_repo_credentials_secret_name = "argocd-repo-credentials-secret"
  repository                        = "https://argoproj.github.io/argo-helm"
  name                              = "argocd"
  chart                             = "argo-cd"

  ssh_secrets_conf = <<EOT
- url: ${local.repo_url}
  sshPrivateKeySecret:
    name: ${local.sync_repo_credentials_secret_name}
    key: sshPrivateKey
  EOT

  https_secrets_conf = <<EOT
- url: ${local.repo_url}
  usernameSecret:
    name: ${local.sync_repo_credentials_secret_name}
    key: username
  passwordSecret:
    name: ${local.sync_repo_credentials_secret_name}
    key: password
${var.repo_conf}
  EOT

  secrets_conf = var.ssh_private_key == "" ? local.https_secrets_conf : local.ssh_secrets_conf

  init_conf = merge(
    {
      "kubeVersionOverride"                                            = var.kubeversion
      "server.additionalApplications[0].name"                          = "swiss-army-kube"
      "server.additionalApplications[0].namespace"                     = local.namespace
      "server.additionalApplications[0].project"                       = var.project_name
      "server.additionalApplications[0].source.repoURL"                = local.repo_url
      "server.additionalApplications[0].source.targetRevision"         = var.branch
      "server.additionalApplications[0].source.path"                   = "${var.path_prefix}${var.apps_dir}"
      "server.additionalApplications[0].source.plugin.name"            = "decryptor"
      "server.additionalApplications[0].destination.server"            = "https://kubernetes.default.svc"
      "server.additionalApplications[0].destination.namespace"         = local.namespace
      "server.additionalApplications[0].syncPolicy.automated.prune"    = "true"
      "server.additionalApplications[0].syncPolicy.automated.selfHeal" = "true"
    },
    var.project_name == "default" ? {} : {
      "server.additionalProjects[0].name"                              = var.project_name
      "server.additionalProjects[0].namespace"                         = local.namespace
      "server.additionalProjects[0].description"                       = "A project for Swiss-Army-Kube components"
      "server.additionalProjects[0].clusterResourceWhitelist[0].group" = "*"
      "server.additionalProjects[0].clusterResourceWhitelist[0].kind"  = "*"
      "server.additionalProjects[0].destinations[0].namespace"         = "*"
      "server.additionalProjects[0].destinations[0].server"            = "*"
      "server.additionalProjects[0].sourceRepos[0]"                    = "*"
    }
  )

  sensitive = yamlencode(
    {
      "configs" = {
        "secret" = {
          "argocdServerAdminPassword" = aws_ssm_parameter.encrypted.value
        }
      }
    }
  )
  conf = {
    "server.extraArgs[0]"                = "--insecure"
    "installCRDs"                        = "false"
    "dex.enabled"                        = "false"
    "server.rbacConfig.policy\\.default" = "role:readonly"

    "kubeVersionOverride"                     = var.kubeversion
    "configs.secret.createSecret"             = true
    "configs.secret.githubSecret"             = var.github_secret
    "configs.secret.gitlabSecret"             = var.gitlab_secret
    "configs.secret.bitbucketServerSecret"    = var.bitbucket_server_secret
    "configs.secret.bitbucketUUID"            = var.bitbucket_uuid
    "configs.secret.gogsSecret"               = var.gogs_secret
    "configs.knownHosts.data.ssh_known_hosts" = var.known_hosts

    "global.securityContext.fsGroup"                                       = "999"
    "repoServer.env[0].name"                                               = "AWS_DEFAULT_REGION"
    "repoServer.env[0].value"                                              = data.aws_region.current.name
    "repoServer.serviceAccount.create"                                     = "true"
    "repoServer.serviceAccount.name"                                       = "argocd-repo-server"
    "repoServer.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn" = module.iam_assumable_role_admin.iam_role_arn
    "repoServer.volumes[0].name"                                           = "decryptor"
    "repoServer.volumes[0].configMap.name"                                 = "argocd-decryptor"
    "repoServer.volumes[0].configMap.items[0].key"                         = "decryptor"
    "repoServer.volumes[0].configMap.items[0].path"                        = "decryptor"
    "repoServer.volumes[1].name"                                           = "kustomize_3_2_0"
    "repoServer.volumes[1].emptyDir" = yamlencode({})
    "repoServer.volumeMounts[0].name"                                      = "decryptor"
    "repoServer.volumeMounts[0].mountPath"                                 = "/opt/decryptor/bin"
    "repoServer.volumeMounts[1].name"                                      = "kustomize_3_2_0"
    "repoServer.volumeMounts[1].mountPath"                                 = "/usr/local/bin/kustomize"
    "repoServer.volumeMounts[1].subPath"                                   = "kustomize"
    "repoServer.initContainers" = yamlencode(
      [{
        "name" = "download-kustomize"
        "image" = "alpine:3.15"
        "command" = ["sh", "-c"]
        "args" = ["wget -O kustomize https://github.com/kubernetes-sigs/kustomize/releases/download/v3.2.0/kustomize_3.2.0_linux_amd64 && chmod +x kustomize && mv kustomize /kustomize_3_2_0/"]
        "volumeMounts" = [{
          "mountPath" = "/kustomize_3_2_0"
          "name" = "kustomize_3_2_0"
        }]
      }]
    )
    "server.config.repositories"                                           = local.secrets_conf
    "server.config.configManagementPlugins" = yamlencode(
      [{
        "name" = "decryptor"
        "init" = {
          "command" = ["/usr/bin/pip3"]
          "args"    = ["install", "boto3"]
        }
        "generate" = {
          "command" = ["/usr/bin/python3"]
          "args"    = ["/opt/decryptor/bin/decryptor"]
        }
      }]
    )

    "server.service.type"    = "NodePort"
    "server.ingress.enabled" = length(var.domains) > 0 ? "true" : "false"
  }
  values = concat(coalescelist(
    [
      {
        "name"  = "server.rbacConfig.policy\\.csv"
        "value" = <<EOF
g, administrators, role:admin
EOF
      }
    ],
    [
      length(var.domains) == 0 ? null : {
        "name"  = "server.config.url"
        "value" = "https://argocd.${var.domains[0]}"
      }
    ],
    [
      lookup(var.oidc, "id", null) == null && lookup(var.oidc, "pool", null) == null ? null : {
        "name" = "server.config.oidc\\.config"
        "value" = yamlencode(
          {
            "name"            = "Cognito"
            "issuer"          = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${lookup(var.oidc, "pool", "")}"
            "clientID"        = lookup(var.oidc, "id", "")
            "clientSecret"    = "KMS_ENC:${aws_kms_ciphertext.client_secret[0].ciphertext_blob}:"
            "requestedScopes" = ["openid", "profile", "email"]
            "requestedIDTokenClaims" = {
              "cognito:groups" = {
                "essential" = true
              }
            }
          }
        )
      }
    ]),
    values({
      for i, domain in tolist(var.domains) :
      "key" => {
        "name"  = "server.ingress.tls[${i}].hosts[0]"
        "value" = "argocd.${domain}"
      }
    }),
    values({
      for i, domain in tolist(var.domains) :
      "key" => {
        "name"  = "server.ingress.hosts[${i}]"
        "value" = "argocd.${domain}"
      }
    }),
    values({
      for i, domain in tolist(var.domains) :
      "key" => {
        "name"  = "server.ingress.tls[${i}].secretName"
        "value" = "argocd-${domain}-tls"
      }
    }),
    values({
      for key, value in var.ingress_annotations :
      key => {
        "name"  = "server.ingress.annotations.${replace(key, ".", "\\.")}"
        "value" = value
      }
    }),
    values({
      for key, value in merge(local.conf, var.conf) :
      key => {
        "name"  = key
        "value" = tostring(value)
      }
    })
  )
  application = {
    "apiVersion" = "argoproj.io/v1alpha1"
    "kind"       = "Application"
    "metadata" = {
      "name"      = local.name
      "namespace" = local.namespace
    }
    "spec" = {
      "destination" = {
        "namespace" = local.namespace
        "server"    = "https://kubernetes.default.svc"
      }
      "project" = var.project_name
      "source" = {
        "repoURL"        = local.repository
        "targetRevision" = var.chart_version
        "chart"          = local.chart
        "helm" = {
          "parameters" = local.values
          "values"     = local.sensitive
        }
      }
      "syncPolicy" = {
        "automated" = {
          "prune"    = true
          "selfHeal" = true
        }
      }
    }
  }
}
