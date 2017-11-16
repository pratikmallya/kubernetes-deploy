# frozen_string_literal: true
module KubernetesDeploy
  class Deployment < KubernetesResource
    TIMEOUT = 7.minutes

    def sync
      raw_json, _err, st = kubectl.run("get", type, @name, "--output=json")
      @found = st.success?

      if @found
        @deployment_data = JSON.parse(raw_json)
        @desired_replicas = @deployment_data["spec"]["replicas"].to_i
        @latest_rs = find_latest_rs
        @rollout_data = { "replicas" => 0 }.merge(@deployment_data["status"]
          .slice("replicas", "updatedReplicas", "availableReplicas", "unavailableReplicas"))
        @status = @rollout_data.map { |state_replicas, num| "#{num} #{state_replicas.chop.pluralize(num)}" }.join(", ")
        conditions = @deployment_data.fetch("status", {}).fetch("conditions", [])
        @progress_condition = conditions.find { |condition| condition['type'] == 'Progressing' }
        @progress_deadline = deployment_data['spec']['progressDeadlineSeconds']
      else # reset
        @latest_rs = nil
        @rollout_data = { "replicas" => 0 }
        @status = nil
        @progress_condition = nil
        @progress_deadline = @definition['spec']['progressDeadlineSeconds']
        @desired_replicas = -1
      end
    end

    def fetch_events
      own_events = super
      return own_events unless @latest_rs.present?
      own_events.merge(@latest_rs.fetch_events)
    end

    def fetch_logs
      return {} unless @latest_rs.present?
      @latest_rs.fetch_logs
    end

    def deploy_succeeded?
      return false unless @latest_rs.present?

      if min_required_rollout.blank?
        @latest_rs.deploy_succeeded? &&
        @latest_rs.desired_replicas == @desired_replicas && # latest RS fully scaled up
        @rollout_data["updatedReplicas"].to_i == @desired_replicas &&
        @rollout_data["updatedReplicas"].to_i == @rollout_data["availableReplicas"].to_i
      else
        minimum_needed = minimum_updated_replicas_to_succeeded

        running_rs.size <= 2 &&
        @latest_rs.desired_replicas > minimum_needed &&
        @rollout_data["updatedReplicas"].to_i > minimum_needed &&
        @rollout_data["availableReplicas"].to_i > minimum_needed
      end
    end

    def deploy_failed?
      @latest_rs&.deploy_failed?
    end

    def failure_message
      return unless @latest_rs.present?
      "Latest ReplicaSet: #{@latest_rs.name}\n\n#{@latest_rs.failure_message}"
    end

    def timeout_message
      reason_msg = if @progress_condition.present?
        "Timeout reason: #{@progress_condition['reason']}"
      else
        "Timeout reason: hard deadline for #{type}"
      end
      return reason_msg unless @latest_rs.present?
      "#{reason_msg}\nLatest ReplicaSet: #{@latest_rs.name}\n\n#{@latest_rs.timeout_message}"
    end

    def pretty_timeout_type
      @progress_deadline.present? ? "progress deadline: #{@progress_deadline}s" : super
    end

    def deploy_timed_out?
      # Do not use the hard timeout if progress deadline is set
      @progress_condition.present? ? deploy_failing_to_progress? : super
    end

    def exists?
      @found
    end

    private

    def deploy_failing_to_progress?
      return false unless @progress_condition.present?

      if kubectl.server_version < Gem::Version.new("1.7.7")
        # Deployments were being updated prematurely with incorrect progress information
        # https://github.com/kubernetes/kubernetes/issues/49637
        return false unless Time.now.utc - @deploy_started_at >= @progress_deadline.to_i
      else
        return false unless deploy_started?
      end

      @progress_condition["status"] == 'False' &&
      Time.parse(@progress_condition["lastUpdateTime"]).to_i >= (@deploy_started_at - 5.seconds).to_i
    end

    def all_rs_data(matchLabels)
      label_string = matchLabels.map { |k, v| "#{k}=#{v}" }.join(",")
      raw_json, _err, st = kubectl.run("get", "replicasets", "--output=json", "--selector=#{label_string}")
      return {} unless st.success?

      JSON.parse(raw_json)["items"]
    end

    def running_rs
      all_rs_data(@deployment_data["spec"]["selector"]["matchLabels"]).select do |rs|
        rs["status"]["replicas"].to_i > 0
      end
    end

    def min_required_rollout
      @deployment_data['metadata']['annotations']['kubernetes-deploy.shopify.io/min-required-rollout']
    end

    def minimum_updated_replicas_to_succeeded
      desired = @desired_replicas

      if min_required_rollout =~ /%/
        desired *= (100 - min_required_rollout.to_i) / 100.0
      else
        desired -= min_required_rollout.to_i
      end

      desired.to_i
    end

    def find_latest_rs
      current_revision = @deployment_data["metadata"]["annotations"]["deployment.kubernetes.io/revision"]

      latest_rs_data = all_rs_data(@deployment_data["spec"]["selector"]["matchLabels"]).find do |rs|
        rs["metadata"]["ownerReferences"].any? { |ref| ref["uid"] == @deployment_data["metadata"]["uid"] } &&
        rs["metadata"]["annotations"]["deployment.kubernetes.io/revision"] == current_revision
      end

      return unless latest_rs_data.present?

      rs = ReplicaSet.new(
        namespace: namespace,
        context: context,
        definition: latest_rs_data,
        logger: @logger,
        parent: "#{@name.capitalize} deployment",
        deploy_started_at: @deploy_started_at
      )
      rs.sync(latest_rs_data)
      rs
    end
  end
end
