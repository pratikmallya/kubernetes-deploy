# frozen_string_literal: true
require 'test_helper'

class ResourceDiscoveryTest < KubernetesDeploy::IntegrationTest
  def kubectl
    @kubectl ||= KubernetesDeploy::Kubectl.new(namespace: @namespace,
      context: KubeclientHelper::MINIKUBE_CONTEXT,
      logger:
        KubernetesDeploy::FormattedLogger.build(
          @namespace,
          KubeclientHelper::MINIKUBE_CONTEXT,
          $stdout
        ),
      log_failure_by_default: false)
  end

  def cleanup(*resources)
    resources.each do |res|
      _, err, st = kubectl.run("delete", res, "--all")
      flunk(err) unless st.success?
    end
  end

  def has_resource?(res)
    _, _, st = kubectl.run("get", res)
    st.success?
  end

  def has_tpr_support?
    has_resource? "thirdpartyresources"
  end

  def has_crd_support?
    has_resource? "customresourcedefinitions"
  end

  def test_prunable_tpr
    skip unless has_tpr_support?
    begin
      assert_deploy_success(deploy_fixtures("resource-discovery/definitions", subset: ["tpr.yml"]))
      assert_deploy_success(deploy_fixtures("resource-discovery/instances", subset: ["tpr.yml"]))
      # Deploy any other resource to trigger pruning
      assert_deploy_success(deploy_fixtures("hello-cloud", subset: ["configmap-data.yml",]))

      assert_logs_match("The following resources were pruned: gizmo \"my-first-gizmo\"")
      refute_logs_match("Don't know how to monitor resources of type Gizmo. " \
                        "Assuming Gizmo/my-first-gizmo deployed successfully")
    ensure
      cleanup('thirdpartyresources')
    end
  end

  def test_non_prunable_crd_no_predeploy
    skip unless has_crd_support?
    begin
      assert_deploy_success(deploy_fixtures("resource-discovery/definitions",
        subset: ["crd_non_prunable_no_predeploy.yml"]))
      assert_deploy_success(deploy_fixtures("resource-discovery/instances", subset: ["crd.yml"]))
      # Deploy any other non-priority (predeployable) resource to trigger pruning
      assert_deploy_success(deploy_fixtures("hello-cloud", subset: ["daemon_set.yml",]))

      refute_logs_match("The following resources were pruned: widget \"my-first-widget\"")
      refute_logs_match("Don't know how to monitor resources of type Widget. " \
                        "Assuming Widget/my-first-widget deployed successfully")
      refute_logs_match("Predeploying priority resources")
    ensure
      cleanup('customresourcedefinitions')
    end
  end

  def test_prunable_crd
    skip unless has_crd_support?
    begin
      assert_deploy_success(deploy_fixtures("resource-discovery/definitions", subset: ["crd.yml"]))
      assert_deploy_success(deploy_fixtures("resource-discovery/instances", subset: ["crd.yml"]))
      # Deploy any other resource to trigger pruning
      assert_deploy_success(deploy_fixtures("hello-cloud", subset: ["configmap-data.yml",]))

      assert_logs_match("The following resources were pruned: widget \"my-first-widget\"")
      refute_logs_match("Don't know how to monitor resources of type Widget. " \
                        "Assuming Widget/my-first-widget deployed successfully")
    ensure
      cleanup('customresourcedefinitions')
    end
  end

  def test_invalid_timeout_format
    skip unless has_crd_support?
    begin
      assert_deploy_success(deploy_fixtures("resource-discovery/definitions", subset: ["crd_invalid_timespec.yml"]))
      assert_deploy_failure(deploy_fixtures("resource-discovery/instances", subset: ["crd.yml"]))

      assert_logs_match("Resource widget specified invalid timeout value 'foobar', must use iso8601 duration.")
    ensure
      cleanup('customresourcedefinitions')
    end
  end
end
