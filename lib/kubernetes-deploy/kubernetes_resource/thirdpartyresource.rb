# frozen_string_literal: true
module KubernetesDeploy
  class ThirdPartyResource < GenericResource
    TIMEOUT = 30.seconds

    def exists?
      # TPRs take time to become available.
      _, _err, st = kubectl.run("get", @name)
      st.success?
    end
  end
end
