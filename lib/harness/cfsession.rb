require "cfoundry"
require "vcap/logging"
require "harness/rake_helper"

module BVT::Harness
  class CFSession
    attr_reader :log, :namespace, :api_endpoint, :email, :passwd, :token, :current_organization, :current_space,
                :client, :test_domains

    def initialize(options = {})
      if options[:api_endpoint]
        @api_endpoint = RakeHelper.format_target(options[:api_endpoint])
      else
        @api_endpoint = RakeHelper.get_api_endpoint
      end

      @email = options.fetch(:email) { get_login_email(options[:admin]) }
      @passwd = options.fetch(:passwd) { get_login_passwd(options[:admin]) }

      # Restrict admin from performing non-admin operations
      unless options[:admin]
        if is_user_admin?(@email, @passwd)
          raise RuntimeError, "current operation can not be performed as user with admin privileges"
        end
      end

      @test_domains = []

      LoggerHelper.set_logger(@api_endpoint)

      @log = get_logger
      @namespace = get_namespace
      login
    end

    def inspect
      "#<BVT::Harness::CFSession '#{@api_endpoint}', '#{@email}'>"
    end

    def login
      @log.info("Login in, target: #{@api_endpoint}, email = #{@email}")
      @client = CFoundry::Client.get(@api_endpoint)
      @client.trace = true if ENV['VCAP_BVT_TRACE']
      @client.log = []
      begin
        @token = @client.login(:username => @email, :password => @passwd)
      rescue Exception => e
        @log.error "Fail to log in, target: #{@api_endpoint}, user: #{@email}\n#{e.to_s}"
        raise
      end
      # TBD - ABS: This is a hack around the 1 sec granularity of our token time stamp
      sleep(1)

      select_org_and_space
    end

    def logout
      @log.debug "logout, target: #{@api_endpoint}, email = #{@email}"
      @client = nil
    end

    def info
      @log.debug "get target info, target: #{@api_endpoint}"
      @client.info
    end

    def register(email, password)
      @log.debug("Register user: #{email}")
      User.new(@client.register(email, password), self)
    end

    def system_services
      @log.debug "get system services, target: #{@api_endpoint}"
      services = {}

      @client.services.each do |service|
        s = {}
        s[:description]   = service.description
        versions = []
        if services[service.label]
          versions = services[service.label][service.provider][:versions] if services[service.label][service.provider]
        end
        versions          << service.version.to_s unless versions.index(service.version.to_s)
        s[:provider]      = service.provider
        s[:plans]         = service.service_plans.collect {|p| p.name }
        services[service.label] ||= {}
        services[service.label][service.provider] = s
        services[service.label][service.provider][:versions] = versions
      end
      services
    end

    def app(name, prefix = '', domain=nil)
      app = @client.app
      app.name = "#{prefix}#{@namespace}#{name}"
      App.new(app, self, domain)
    end

    def apps
      @client.apps.collect {|app| App.new(app, self)}
    end

    def find_app(name)
      App.new(@client.app_by_name(name), self, nil)
    end

    def services
      @client.service_instances.collect {|service| Service.new(service, self)}
    end

    def service(name, require_namespace=true)
      instance = @client.service_instance
      instance.name = require_namespace ? "#{@namespace}#{name}" : name
      BVT::Harness::Service.new(instance, self)
    end

    def select_org_and_space(org_name = "", space_name = "")
      orgs = @client.organizations
      fail "no organizations." if orgs.empty?
      org = orgs.first
      unless org_name == ""
        find = @client.organization_by_name(org_name)
        org = find if find
      end
      @current_organization = org

      spaces = @current_organization.spaces
      if spaces.empty?
        space = @client.space
        space.name = "#{@namespace}space"
        space.organization = @current_organization
        space.create!
        space.add_developer @client.current_user
        @current_space = space
      else
        spaces.each { |s|
          @current_space = s if s.name == space_name
        } unless space_name == ""
        @current_space = spaces.first if @current_space.nil?
      end
      @client.current_space = @current_space
    end

    def organizations
      @client.organizations
    end

    def spaces
      @client.spaces.collect {|space| BVT::Harness::Space.new(space, self)}
    end

    def domains
      @client.domains.collect {|domain| BVT::Harness::Domain.new(domain, self)}
    end

    def space(name, require_namespace=true)
      if require_namespace
        name = "#{@namespace}#{name}"
      end
      begin
        space = @client.space
        space.name = name
        BVT::Harness::Space.new( space, self)
      rescue Exception => e
        @log.error("Fail to get space: #{name}")
        raise
      end
    end

    def domain(name, require_namespace=true)
      if require_namespace
        name = "#{@namespace}#{name}"
      end
      begin
        domain = @client.domain
        domain.wildcard = true
        domain.name = name
        BVT::Harness::Domain.new( domain, self)
      rescue Exception => e
        @log.error("Fail to create domain: #{name}")
        raise
      end
    end

    def users
      begin
        @log.debug("Get Users for target: #{@client.target}, login email: #{@email}")
        users = @client.users.collect {|user| User.new(user, self)}
      rescue Exception => e
        @log.error("Fail to list users for target: #{@client.target}, login email: #{@email}")
        raise
      end
    end

    def user(email, options={})
      options = {:require_namespace => true}.merge(options)
      email = "#{@namespace}#{email}" if options[:require_namespace]
      User.new(@client.user(email), self)
    end

    def get_target_domain
      if ENV['VCAP_BVT_APP_DOMAIN']
        ENV['VCAP_BVT_APP_DOMAIN']
      else
        @api_endpoint.split(".", 2).last
      end
    end

    # It will delete all services and apps belong to login token via client object
    # mode: current -> delete app/service_instance in current space.
    # mode: all -> delete app/service_instance in each space
    def cleanup!(mode = "current")
      target_domain = get_target_domain
      if mode == "all"
        @client.spaces.each do |s|
          s.service_instances.each { |service| service.delete! }
          s.apps.each { |app| app.delete! }
        end
        @client.routes.each { |route| route.delete! }
      elsif mode == "current"
        # CCNG cannot delete service which binded to application
        # therefore, remove application first
        @client.current_organization = @current_organization
        @client.current_space = @current_space
        apps.each {|app| app.delete}
        services.each {|service| service.delete}
        @client.routes.each { |route| route.delete! }
      end
    end

    def print_client_logs
      lines = @client.log.map do |item|
        parse_log_line(item)
      end

      @client.log = []
      lines.last(5).join("\n")
    end

    private

    def get_logger
      VCAP::Logging.logger(File.basename($0))
    end

    # generate random string as prefix for one test example
    BASE36_ENCODE  = 36
    LARGE_INTEGER  = 2**32
    def get_namespace
      "t#{rand(LARGE_INTEGER).to_s(BASE36_ENCODE)}-"
    end

    def get_login_email(expected_admin = false)
      if expected_admin
        RakeHelper.get_admin_user
      else
        ENV['YETI_PARALLEL_USER'] || RakeHelper.get_user
      end
    end

    def get_login_passwd(expected_admin = false)
      if expected_admin
        RakeHelper.get_admin_user_passwd
      else
        ENV['YETI_PARALLEL_USER_PASSWD'] || RakeHelper.get_user_passwd
      end
    end

    def check_privilege(expect_admin = false)
      expect_privilege = expect_admin ? "admin user" : "normal user"
      actual_privilege = admin? ? "admin user" : "normal user"

      if actual_privilege == expect_privilege
        @log.info "run bvt as #{expect_privilege}"
      else
        @log.error "user type does not match. Expected User Privilege: #{expect_privilege}" +
                       " Actual User Privilege: #{actual_privilege}"
        raise
      end
    end

    def admin?
      begin
        is_user_admin?(@email, @passwd)
      rescue Exception => e
        @log.error("Fail to check user's admin privilege. Target: #{@client.target},"+
                       " login email: #{@email}\n#{e.to_s}")
        raise
      end
    end

    def parse_log_line(item)
      date        = item[:response][:headers]["date"]
      time        = "%.6f" % item[:time].to_f
      rest_method = item[:request][:method].upcase
      code        = item[:response][:code]
      url         = item[:request][:url]

      if item[:response][:headers]["x-vcap-request-id"]
        request_id  = item[:response][:headers]["x-vcap-request-id"]
      else
        request_id  = ""
      end

      "[#{date}]  #{time}\t#{request_id}  #{rest_method}\t-> #{code}\t#{url}"
    end

    private

    def is_user_admin?(email, passwd)
      check_admin_client = CFoundry::Client.get(@api_endpoint)
      check_admin_client.login(:username => email, :password => passwd)
      begin
        check_admin_client.current_user.admin?
      rescue CFoundry::APIError
        false
      end
    end
  end
end
