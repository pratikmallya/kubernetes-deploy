# frozen_string_literal: true
module KubernetesDeploy
  class CustomResourceDefinition < GenericResource
    TIMEOUT = 10.seconds
  end
end
