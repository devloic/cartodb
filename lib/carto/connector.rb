require_relative 'connector/errors'
require_relative 'connector/providers'
require_relative 'connector/parameters'

module Carto
  # This class provides remote database connection services
  class Connector

    attr_reader :provider_name

    def initialize(parameters:, user:, **args)
      @params = Parameters.new(parameters)

      @provider_name = @params[:provider]
      @provider_name ||= DEFAULT_PROVIDER

      @user = user
      temporary_parameters_adjustment_for_new_bigquery_connector

      raise InvalidParametersError.new(message: "Provider not defined") if @provider_name.blank?
      @provider = Connector.provider_class(@provider_name).try :new, parameters: @params, user: @user, **args
      raise InvalidParametersError.new(message: "Invalid provider", provider: @provider_name) if @provider.blank?
    end

    def copy_table(schema_name:, table_name:)
      @provider.copy_table(schema_name: schema_name, table_name: table_name, limits: limits)
    end

    def self.list_tables?(provider)
      has_feature? provider, :list_tables
    end

    def self.list_projects?(provider)
      has_feature? provider, :list_projects
    end

    def self.dry_run?(provider)
      has_feature? provider, :dry_run
    end

    def list_tables(limit = nil)
      @provider.list_tables(limits: limits.merge(max_listed_tables: limit))
    end

    def list_projects
      @provider.list_projects
    end

    def list_project_datasets(project_id)
      @provider.list_project_datasets(project_id)
    end

    def list_project_dataset_tables(project_id, dataset_id)
      @provider.list_project_dataset_tables(project_id, dataset_id)
    end

    def check_connection
      @provider.check_connection
    end

    def dry_run
      @provider.dry_run
    end

    def remote_data_updated?
      @provider.remote_data_updated?
    end

    def last_modified
      @provider.last_modified
    end

    def table_name
      @provider.table_name
    end

    # Availabillity check: checks general availability for user,
    # and specific provider availability if provider_name is not nil
    def self.check_availability!(user, provider_name=nil)
      return false if user.nil?
      return true if provider_name == 'do-v2-sample'
      return user.do_enabled? if provider_name == 'do-v2'
      # check general availability
      unless user.has_feature_flag?('carto-connectors')
        raise ConnectorsDisabledError.new(user: user)
      end
      if provider_name
        # check the provider is enabled for the user
        limits = Connector.limits provider_name: provider_name, user: user
        if !limits || !limits[:enabled]
          raise ConnectorsDisabledError.new(user: user, provider: provider_name)
        end
      end
    end

    def self.available?(user)
      user.has_feature_flag?('carto-connectors')
    end

    def self.provider_available?(provider, user)
      Carto::Connector.check_availability! user, provider
      true
    rescue ConnectorsDisabledError
      false
    end

    # Check availability for a user and provider
    def check_availability!
      Connector.check_availability!(@user, @provider_name)
    end

    # Limits for the user/provider
    def limits
      Connector.limits provider_name: @provider_name, user: @user
    end

    # Availability for the user/provider
    def enabled?
      limits[:enabled]
    end

    def self.limits(provider_name:, user:)
      if configuration = user.connector_configuration(provider_name)
        { enabled: configuration.enabled?, max_rows: configuration.max_rows }
      else
        {}
      end
    end

    # Information about a connector's features and parameters.
    #
    # Example:
    # {
    #   'mysql' => {
    #     features: {
    #                 "sql_queries":    true,
    #                 "list_databases": false,
    #                 "list_tables":    true,
    #                 "preview_table":  false
    #     },
    #     parameters: {
    #       connection: {
    #         server: { required: true, description: "..." },
    #         ...
    #       },
    #       table: { required: true, description: "..." },
    #       ...
    #     }
    #   }, ...
    # }
    def self.information(provider_name)
      provider = provider_class(provider_name)
      raise InvalidParametersError.new(message: "Invalid provider", provider: provider_name) if provider.blank?
      provider.information
    end

    # Available providers information.
    #
    # Example:
    # {
    #   'mysql' => { name: 'MySQL', description: '...', enabled: true },
    #   ...
    # }
    #
    # By default only `public` providers are returned; use `all: true` to return all of them.
    # If a `user:` argument is provided, the  `enabled` key will indicate if the provider is
    # enabled for the user; otherwise it indicates if it is enabled by default.
    #
    def self.providers(user: nil, all: false)
      providers_info = {}
      provider_ids.each do |id|
        next unless all || provider_public?(id)
        # TODO: load description template for provider id
        description = nil
        enabled = if user
                    Connector.limits(user: user, provider_name: id)[:enabled]
                  else
                    provider = ConnectorProvider.find_by_name(id)
                    ConnectorConfiguration.default(provider).enabled if provider
                  end
        providers_info[id] = {
          name:        provider_name(id),
          description: description,
          enabled:     enabled
        }
      end
      providers_info
    end

    def get_service(service)
      if @provider.respond_to?(service)
        @provider.send(service)
      else
        raise Carto::Connector::InvalidParametersError.new("Invalid connector service: #{service}")
      end
    end

    private

    # TODO: remove when new connections are in place
    def temporary_parameters_adjustment_for_new_bigquery_connector
      return unless @provider_name == 'bigquery'

      if bigquery_connection_missing_refresh_token?
        @params.reverse_merge!(connection: {})
        @params[:connection].merge!(refresh_token: @user.oauths.select('bigquery')&.token)
      end
      billing_project = @params.delete(:billing_project)
      if billing_project.present?
        @params.reverse_merge!(connection: {})
        @params[:connection].merge!(billing_project: billing_project)
      end
      @params.delete(:project) if @params[:project] == '%DATABASE%'
    end

    def bigquery_connection_missing_refresh_token?
      return true if @params[:connection].blank?

      (@params[:connection].keys & [:service_account, :access_token, :refresh_token]).empty?
    end

    def self.has_feature?(provider, feature)
      information = Connector.information(provider)
      information[:features][feature]
    end

    # Validate parameters.
    # An array of parameter names to validate can be passed via :only.
    # By default all parameters are validated
    def validate!(only: nil)
      @provider.validate!(only: only)
    end

    def log(message, truncate = true)
      @provider.log message, truncate
    end
  end
end
