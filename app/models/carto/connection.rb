module Carto
  class Connection < ActiveRecord::Base
    TYPE_OAUTH_SERVICE = 'oauth-service'.freeze
    TYPE_DB_CONNECTOR = 'db-connector'.freeze

    belongs_to :user, class_name: 'Carto::User', inverse_of: :connections

    scope :oauth_connections, -> { where(connection_type: TYPE_OAUTH_SERVICE) }
    scope :db_connections, -> { where(connection_type: TYPE_DB_CONNECTOR) }

    validates :name, uniqueness: { scope: :user_id }
    validates :connection_type, inclusion: { in: [TYPE_OAUTH_SERVICE, TYPE_DB_CONNECTOR] }
    validate :validate_parameters
    validates :connector, uniqueness: { scope: [:user_id, :connection_type] }, if: :singleton_connection?

    def get_service_datasource
      raise "Invalid connection type (#{connection_type}) to get service datasource" unless connection_type == TYPE_OAUTH_SERVICE

      datasource = CartoDB::Datasources::DatasourcesFactory.get_datasource(connector, user, {
        http_timeout: ::DataImport.http_timeout_for(user)
      })
      datasource.token = token unless datasource.nil?
      datasource
    end

    def service
      raise "service not available for connection of type #{connection_type}" unless connection_type == TYPE_OAUTH_SERVICE
      connector
    end

    def provider
      raise "provider not available for connection of type #{connection_type}"  unless connection_type == TYPE_DB_CONNECTOR
      connector
    end

    before_validation :set_type
    before_validation :set_name
    # before_validation :set_parameters
    after_create :manage_create
    after_update :manage_update
    after_destroy :manage_destroy

    private

    def connection_manager
      Carto::ConnectionManager.new(user)
    end

    def manage_create
      connection_manager.manage_create(self)
    end

    def manage_update
      connection_manager.manage_update(self)
    end

    def manage_destroy
      connection_manager.manage_destroy(self)
    end

    def singleton_connection?
      Carto::ConnectionManager.singleton_connector?(self)
    end

    def set_type
      return if connection_type.present?

      if token.present?
        self.connection_type = TYPE_OAUTH_SERVICE
      else
        self.connection_type = TYPE_DB_CONNECTOR
      end
    end

    def set_name
      return if name.present?

      if connection_type == TYPE_OAUTH_SERVICE
        self.name = connector
      end
    end

    def set_parameters
      return if parameters.present?

      if connection_type == TYPE_OAUTH_SERVICE
        self.parameters = { refresh_token: token }
      end
    end

    def validate_parameters
      Carto::ConnectionManager.errors(self).each do |error|
        errors.add :connector, error
      end
      case connection_type
      when TYPE_OAUTH_SERVICE
        if !get_service_datasource&.token_valid? # !Carto::ConnectionManager.new(user).oauth_connection_valid?(self)
          errors.add :token, "Invalid OAuth"
        elsif parameters.present?
          # OAuth connections that also admit db-connector parameters (BigQuery)
          # can be saved incomplete without the parameters; once the parameters are assigned,
          # the db connection is validates
          validate_db_connection
        end
      when TYPE_DB_CONNECTOR
        validate_db_connection
      end
    end

    def validate_db_connection
      connector = Carto::Connector.new(parameters: {}, connection: self, user: user, logger: nil)
      connector.check_connection
    rescue Carto::Connector::InvalidParametersError => error
      if error.to_s =~ /Invalid provider/im
        errors.add :connector, error.to_s
      else
        errors.add :parameters, error.to_s
      end
    rescue CartoDB::Datasources::AuthError, CartoDB::Datasources::TokenExpiredOrInvalidError => error
      errors.add :token, error.to_s
    rescue StandardError => error
      errors.add :base, error.to_s
    end
  end
end
