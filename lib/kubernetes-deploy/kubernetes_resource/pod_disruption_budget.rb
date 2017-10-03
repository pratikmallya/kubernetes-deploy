# frozen_string_literal: true
module KubernetesDeploy
  class PodDisruptionBudget < GenericResource
    def deploy_method
      # Required until https://github.com/kubernetes/kubernetes/issues/45398 changes
      :replace_force
    end
  end
end
