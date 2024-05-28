terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.27.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.12.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "5.39.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.0.4"
    }
  }
}

locals {
  namespace = module.namespace.namespace

  controller_match_labels = {
    id = random_id.controller_id.hex
  }

  webhook_match_labels = {
    id = random_id.webhook_id.hex
  }
}

module "pull_through" {
  count  = var.pull_through_cache_enabled ? 1 : 0
  source = "../aws_ecr_pull_through_cache_addresses"
}

resource "random_id" "controller_id" {
  prefix      = "pvc-autoresizer-"
  byte_length = 8
}

resource "random_id" "webhook_id" {
  prefix      = "pvc-autorsizer-webhook-"
  byte_length = 8
}

module "kube_labels_controller" {
  source = "../kube_labels"

  # generate: common_vars_no_extra_tags.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  pf_module        = var.pf_module
  is_local         = var.is_local
  # end-generate

  extra_tags = merge(var.extra_tags, local.controller_match_labels)
}

module "constants_controller" {
  source = "../constants"

  matching_labels = local.controller_match_labels

  # generate: common_vars_no_extra_tags.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  pf_module        = var.pf_module
  is_local         = var.is_local
  # end-generate

  extra_tags = merge(var.extra_tags, local.controller_match_labels)
}

module "kube_labels_webhook" {
  source = "../kube_labels"

  # generate: common_vars_no_extra_tags.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  pf_module        = var.pf_module
  is_local         = var.is_local
  # end-generate

  extra_tags = merge(var.extra_tags, local.webhook_match_labels)
}

module "constants_webhook" {
  source = "../constants"

  matching_labels = local.webhook_match_labels

  # generate: common_vars_no_extra_tags.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  pf_module        = var.pf_module
  is_local         = var.is_local
  # end-generate

  extra_tags = merge(var.extra_tags, local.webhook_match_labels)
}

module "namespace" {
  source = "../kube_namespace"

  namespace = "pvc-autoresizer"

  # generate: pass_common_vars.snippet.txt
  pf_stack_version = var.pf_stack_version
  pf_stack_commit  = var.pf_stack_commit
  environment      = var.environment
  region           = var.region
  pf_root_module   = var.pf_root_module
  is_local         = var.is_local
  extra_tags       = var.extra_tags
  # end-generate
}

/***************************************
* Autoresizer
***************************************/

#module "webhook_cert" {
#  source = "../kube_internal_cert"
#
#  service_names = ["external-snapshotter-webhook"]
#  secret_name   = "external-snapshotter-webhook-certs"
#  namespace     = local.namespace
#
#  # generate: pass_common_vars.snippet.txt
#  pf_stack_version = var.pf_stack_version
#  pf_stack_commit  = var.pf_stack_commit
#  environment      = var.environment
#  region           = var.region
#  pf_root_module   = var.pf_root_module
#  is_local         = var.is_local
#  extra_tags       = var.extra_tags
#  # end-generate
#}

resource "helm_release" "pvc_autoresizer" {
  namespace       = local.namespace
  name            = "pvc-autoresizer"
  repository      = "https://topolvm.github.io/pvc-autoresizer"
  chart           = "pvc-autoresizer"
  version         = var.pvc_autoresizer_helm_version
  recreate_pods   = false
  cleanup_on_fail = true
  wait            = true
  wait_for_jobs   = true

  values = [
    yamlencode({
      image = {
        repository = "${var.pull_through_cache_enabled ? module.pull_through[0].github_registry : "ghcr.io"}/topolvm/pvc-autoresizer"
      }
      controller = {
        args = {
          prometheusURL = "http://thanos-query-frontend.monitoring.svc.cluster.local:9090"
        }
        podLabels = module.kube_labels_controller.kube_labels

        replicaCount      = 1
        priorityClassName = module.constants_controller.cluster_important_priority_class_name
        tolerations       = module.constants_controller.burstable_node_toleration_helm

        resources = {
          requests = {
            memory = "100Mi"
          }
          limits = {
            memory = "130Mi"
          }
        }
      }

      podMonitor = {
        enabled   = var.monitoring_enabled
        namespace = local.namespace
        interval  = "60s"
      }

      cert-manager = {
        enabled = false // This flag actually deploys cert-manager... which is not what we want
      }
      webhook = {
        existingCertManagerIssuer = {
          group = "cert-manager.io"
          kind  = "ClusterIssuer"
          name  = "internal"
        }
      }
    })
  ]

  // Adjusts the certificate to align with Panfactum standards
  postrender {
    binary_path = "${path.module}/kustomize/kustomize.sh"
  }
}


resource "kubernetes_manifest" "vpa_controller" {
  count = var.vpa_enabled ? 1 : 0
  manifest = {
    apiVersion = "autoscaling.k8s.io/v1"
    kind       = "VerticalPodAutoscaler"
    metadata = {
      name      = "pvc-autoresizer"
      namespace = local.namespace
      labels    = module.kube_labels_controller.kube_labels
    }
    spec = {
      targetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = "pvc-autoresizer-controller"
      }
    }
  }
  depends_on = [helm_release.pvc_autoresizer]
}

#resource "kubernetes_manifest" "vpa_webhook" {
#  count = var.vpa_enabled ? 1 : 0
#  manifest = {
#    apiVersion = "autoscaling.k8s.io/v1"
#    kind       = "VerticalPodAutoscaler"
#    metadata = {
#      name      = "external-snapshotter-webhook"
#      namespace = local.namespace
#      labels    = module.kube_labels_webhook.kube_labels
#    }
#    spec = {
#      targetRef = {
#        apiVersion = "apps/v1"
#        kind       = "Deployment"
#        name       = "external-snapshotter-webhook"
#      }
#    }
#  }
#  depends_on = [helm_release.external_snapshotter]
#}

resource "kubernetes_manifest" "pdb_controller" {
  manifest = {
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "pvc-autoresizer"
      namespace = local.namespace
      labels    = module.kube_labels_controller.kube_labels
    }
    spec = {
      selector = {
        matchLabels = local.controller_match_labels
      }
      maxUnavailable = 1
    }
  }
  depends_on = [helm_release.pvc_autoresizer]
}
#
#resource "kubernetes_manifest" "pdb_webhook" {
#  manifest = {
#    apiVersion = "policy/v1"
#    kind       = "PodDisruptionBudget"
#    metadata = {
#      name      = "external-snapshotter-webhook"
#      namespace = local.namespace
#      labels    = module.kube_labels_webhook.kube_labels
#    }
#    spec = {
#      selector = {
#        matchLabels = local.webhook_match_labels
#      }
#      maxUnavailable = 1
#    }
#  }
#  depends_on = [helm_release.external_snapshotter]
#}

