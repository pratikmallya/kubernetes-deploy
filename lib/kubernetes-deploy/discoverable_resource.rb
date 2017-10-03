# frozen_string_literal: true
require 'kubernetes-deploy/kubernetes_resource'
require 'kubernetes-deploy/kubeclient_builder'
require "pry"
require 'jsonpath'

module KubernetesDeploy
  class DiscoverableResource < KubernetesResource
    extend KubernetesDeploy::KubeclientBuilder

    class << self
      attr_accessor :version, :group, :type
    end

    STATUS_FIELD_ANNOTATION = 'kubernetes-deploy.shopify.io/status-field'
    STATUS_SUCCESS_ANNOTATION = 'kubernetes-deploy.shopify.io/status-success'
    TIMEOUT_ANNOTATION = 'kubernetes-deploy.shopify.io/timeout'
    PREDEPLOY_ANNOTATION = 'kubernetes-deploy.shopify.io/predeploy'
    PRUNABLE_ANNOTATION = 'kubernetes-deploy.shopify.io/prunable'

    def type
      self.class.type
    end

    def self.inherited(child_class)
      child_classes.add child_class
    end

    def self.child_classes
      @child_classes ||= Set.new
    end

    def self.prunable?
      return @prunable if defined?(@prunable)
      false
    end

    def self.predeploy?
      return @predeploy if defined?(@predeploy)
      false
    end

    def self.timeout
      return @timeout if defined?(@timeout)
      super
    end

    def self.identity
      "#{group}/#{version}/#{type}"
    end

    def self.all
      child_classes.dup
    end

    def self.discover(context:, logger:)
      logger.info("Discovering custom resources:")
      @resources = nil
      @child_classes = nil
      discover_tpr(v1beta1_kubeclient(context))
      begin
        discover_crd(v1beta1_crd_kubeclient(context))
      rescue KubeException => err
        logger.warn("Unable to discover CustomResourceDefinitions: #{err}")
      end
    end

    def self.build(namespace:, context:, definition:, logger:)
      return super if KubernetesDeploy.const_defined?(definition["kind"])

      # We only discover once per kubernetes-deploy invocation
      discover(context: context, logger: logger) unless @resources

      type = definition["kind"]
      group, _, version = definition['apiVersion'].rpartition('/')

      resource_class = @resources.dig(group, type, version) if @resources
      return super unless resource_class

      opts = { namespace: namespace, context: context, definition: definition, logger: logger }
      resource_class.new(**opts)
    end

    def self.discover_tpr(client)
      return unless client.respond_to? :get_third_party_resources
      resources = client.get_third_party_resources
      resources.each do |res|
        type, _, group = res.metadata.name.partition('.')
        # TPR API supports multiple versions for a single resource :(
        res.versions.each do |version|
          discovered(group: group,
                     type: type,
                     version: version.name,
                     annotations: res.metadata.annotations)
        end
      end
    end

    def self.discover_crd(client)
      return unless client.respond_to? :get_custom_resource_definitions
      resources = client.get_custom_resource_definitions
      resources.each do |res|
        discovered(group: res.spec.group,
                   type: res.spec.names.kind,
                   version: res.spec.version,
                   annotations: res.metadata.annotations)
      end
    end

    def self.discovered(group:, type:, version:, annotations:)
      resource_class = Class.new(self) do
        type = type.capitalize # TPRs are inconsistent about capitalization
        @group = group
        @type = type
        @version = version
        @prunable = DiscoverableResource.parse_bool(annotations[PRUNABLE_ANNOTATION])
        @predeploy = DiscoverableResource.parse_bool(annotations[PREDEPLOY_ANNOTATION])
        @timeout = DiscoverableResource.parse_timeout(type, annotations[TIMEOUT_ANNOTATION])

        status_field = annotations[STATUS_FIELD_ANNOTATION]
        success_status = annotations[STATUS_SUCCESS_ANNOTATION]

        define_method 'deploy_succeeded?' do
          getter = "get_#{type.downcase}"
          @client ||= DiscoverableResource.kubeclient(context: @context, resource_class: self.class)
          raw_json = @client.send(getter, @name, @namespace, as: :raw)
          query_path = JsonPath.new(status_field)
          current_status = query_path.first(raw_json)
          current_status == success_status
        end if status_field && success_status
      end

      add_resource(resource_class)
    end

    def self.add_resource(resource_class)
      group = resource_class.group
      type = resource_class.type
      version = resource_class.version
      @resources ||= {}
      @resources[group] ||= {}
      @resources[group][type] ||= {}
      @resources[group][type][version] = resource_class
    end

    def self.parse_bool(value)
      value.to_s == "true" # value could be nil
    end

    def self.parse_timeout(type, timeout)
      ActiveSupport::Duration.parse(timeout) if timeout
    rescue ActiveSupport::Duration::ISO8601Parser::ParsingError
      raise FatalDeploymentError,
        "Resource #{type} specified invalid timeout value '#{timeout}', must use ISO8601 duration."
    end

    def self.kubeclient(context:, resource_class:)
      _build_kubeclient(
        api_version: resource_class.version,
        context: context,
        endpoint_path: "/apis/#{resource_class.group}"
      )
    end

    def self.v1beta1_kubeclient(context)
      @v1beta1_kubeclient ||= build_v1beta1_kubeclient(context)
    end

    def self.v1beta1_crd_kubeclient(context)
      @v1beta1_kubeclient_crd ||= _build_kubeclient(
        api_version: "v1beta1",
        context: context,
        endpoint_path: "/apis/apiextensions.k8s.io/"
      )
    end
  end
end
